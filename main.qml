import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Theme
import org.qfield
import org.qgis

Item {
    id: filterToolRoot

    // === PROPRIÉTÉS QFIELD ===
    property var mainWindow: iface.mainWindow()
    property var mapCanvas: iface.mapCanvas()
    property var featureFormItem: iface.findItemByObjectName("featureForm")
    property var dashBoard: iface.findItemByObjectName('dashBoard')
    property var overlayFeatureFormDrawer: iface.findItemByObjectName('overlayFeatureFormDrawer')

    // Variables de sélection
    property var selectedLayer: null
    property var targetPointLayer: null

    // Détection type source
    property bool sourceIsPoints: false

    // État du filtre
    property bool filterActive: false
    property bool isFormVisible: false

    // Persistance
    property bool showAllFeatures: false
    property bool showFeatureList: false
    property string savedLayerName: ""
    property string savedFieldName: ""
    property string savedFilterText: ""
    property string savedExpr: ""

    // Navigation
    property bool useListOffset: false
    property bool isReturnAction: false
    property bool wasLongPress: false

    // Couleurs
    property color targetFocusColor: "#D500F9"
    property color targetSelectedColor: "#23FF0A"
    property color origFocusColor: "#ff7777"
    property color origSelectedColor: Theme.mainColor
    property color origBaseColor: "yellow"
    property color origProjectColor: "yellow"
    property var highlightItem: null

    // Variables internes
    property var pendingFormLayer: null
    property string pendingFormExpr: ""
    property var internalListView: null
    property bool wasListVisible: true

    // === INITIALISATION ===
    Component.onCompleted: {
        iface.addItemToPluginsToolbar(toolbarButton)
        updateLayers()
        
        // Initialisation de la couche cible
        initFixedTargetLayer()

        if (featureFormItem) isFormVisible = featureFormItem.visible

        var container = iface.findItemByObjectName("mapCanvasContainer")
        if (container) findHighlighterRecursive(container)
        if (qgisProject) origProjectColor = qgisProject.selectionColor
        applyCustomColors()
    }

    // === BOUTON TOOLBAR ===
    QfToolButton {
        id: toolbarButton
        iconSource: "icon.svg"
        iconColor: Theme.mainColor
        bgcolor: Theme.darkGray
        round: true

        onClicked: {
            if (!filterToolRoot.wasLongPress) {
                openFilterUI()
            }
            filterToolRoot.wasLongPress = false
        }

        onPressed: holdTimer.start()
        onReleased: holdTimer.stop()

        Timer {
            id: holdTimer
            interval: 500
            repeat: false
            onTriggered: {
                filterToolRoot.wasLongPress = true
                if (filterToolRoot.targetPointLayer) {
                    filterToolRoot.clearTargetLayer(true)
                }
                removeAllFilters()
            }
        }
    }

    // === LOGIQUE TYPE GÉOMÉTRIE ===
    function checkSourceGeometryType() {
        if (!selectedLayer) {
            sourceIsPoints = false
            return
        }
        var gType = -1
        try {
            if (typeof selectedLayer.geometryType === 'number') {
                gType = selectedLayer.geometryType
            } else if (typeof selectedLayer.geometryType === 'function') {
                gType = selectedLayer.geometryType()
            }
        } catch (e) { console.log("Erreur geom: " + e) }

        sourceIsPoints = (gType === 0)
    }

    // === GESTION DE LA COUCHE CIBLE (VERSION CORRIGÉE CHEMIN PLUGIN) ===
    function initFixedTargetLayer() {
        var layerName = "Filter Points";
        
        // 1. Vérifier si elle est déjà chargée dans le projet (pour éviter les doublons)
        var layers = ProjectUtils.mapLayers(qgisProject);
        for (var id in layers) {
            var l = layers[id];
            // On vérifie le nom ou si la source contient le nom du fichier
            if (l.name === layerName || (l.source && l.source.indexOf("filter_points.gpkg") !== -1)) {
                targetPointLayer = l;
                return;
            }
        }

        // 2. CALCUL DU CHEMIN RÉEL DU PLUGIN
        // Qt.resolvedUrl(".") donne le chemin du fichier QML actuel (dans le dossier du plugin)
        var pluginUrl = Qt.resolvedUrl(".").toString();
        
        // Nettoyage de l'URL pour obtenir un chemin de fichier Android valide
        // On enlève "file://"
        var rawPath = pluginUrl.replace("file://", "");
        
        // Important : décoder les caractères spéciaux (ex: les espaces deviennent %20)
        rawPath = decodeURIComponent(rawPath);
        
        // On s'assure que le chemin finit par un slash
        if (rawPath.charAt(rawPath.length - 1) !== '/') {
            rawPath += "/";
        }
        
        // On construit le chemin complet vers le fichier
        var fullPath = rawPath + "points_layer/filter_points.gpkg";

        // console.log("Tentative de chargement depuis : " + fullPath);

        // 3. Tenter de charger le fichier GPKG
        var loadedLayer = null;
        try {
            // LayerUtils.loadVectorLayer prend le chemin absolu
            loadedLayer = LayerUtils.loadVectorLayer(fullPath, layerName);
        } catch(e) {
            console.log("Erreur chargement fichier: " + e);
        }

        // 4. SI LE FICHIER N'EST PAS ACCESSIBLE -> CRÉER UNE COUCHE MÉMOIRE (Sécurité)
        if (!loadedLayer || !loadedLayer.isValid) {
            // mainWindow.displayToast(tr("Fichier plugin introuvable, usage mémoire temporaire."));
            
            var crsAuth = "EPSG:4326"; 
            if (mapCanvas && mapCanvas.mapSettings && mapCanvas.mapSettings.destinationCrs) {
                crsAuth = mapCanvas.mapSettings.destinationCrs.authId();
            }
            var memUri = "Point?crs=" + crsAuth + "&index=yes";
            loadedLayer = LayerUtils.loadVectorLayer(memUri, layerName, "memory");
        }

        // 5. Ajouter la couche au projet
        if (loadedLayer && loadedLayer.isValid) {
            ProjectUtils.addMapLayer(qgisProject, loadedLayer);
            targetPointLayer = loadedLayer;
            if (!targetPointLayer.isEditable) targetPointLayer.startEditing();
        } else {
            mainWindow.displayToast(tr("Erreur critique : Impossible de créer la couche de points."));
        }
    }

    // === CRÉATION CENTROÏDES ===
    function createTemporaryCentroids() {
        if (sourceIsPoints) return
        if (!targetPointLayer) initFixedTargetLayer();

        if (!selectedLayer || !targetPointLayer) return
        var features = selectedLayer.selectedFeatures()

        if (!features || features.length === 0) return

        if (!targetPointLayer.isEditable) targetPointLayer.startEditing()

        var createdCount = 0
        dashBoard.activeLayer = targetPointLayer

        for (var i = 0; i < features.length; i++) {
            var sourceFeat = features[i]
            var geom = sourceFeat.geometry
            if (geom) {
                var wktString = ""
                try {
                    var bbox = GeometryUtils.boundingBox(geom)
                    if (!bbox) bbox = geom.boundingBox
                    if (bbox) {
                        var cx = (bbox.xMinimum + bbox.xMaximum) / 2.0
                        var cy = (bbox.yMinimum + bbox.yMaximum) / 2.0
                        wktString = "POINT(" + cx + " " + cy + ")"
                    }
                } catch (e) {}

                if (wktString !== "") {
                    try {
                        var cleanGeom = GeometryUtils.createGeometryFromWkt(wktString)
                        if (cleanGeom) {
                            var newFeature = FeatureUtils.createBlankFeature(targetPointLayer.fields, cleanGeom)
                            // overlayFeatureFormDrawer permet de valider la création
                            overlayFeatureFormDrawer.featureModel.feature = newFeature
                            if (overlayFeatureFormDrawer.featureModel.create()) {
                                createdCount++
                            }
                        }
                    } catch (errLoop) { console.log("Erreur geom: " + errLoop) }
                }
            }
        }

        dashBoard.activeLayer = selectedLayer

        if (createdCount > 0) {
            // Pour une couche mémoire, commitChanges n'est pas toujours requis mais conseillé pour valider
            targetPointLayer.commitChanges()
            targetPointLayer.startEditing()
            if (mapCanvas) mapCanvas.refresh()
        }
    }

    // === NETTOYAGE ===
    function clearTargetLayer(showFeedback) {
        if (sourceIsPoints) return
        if (!targetPointLayer) initFixedTargetLayer();

        var layerToClean = targetPointLayer
        if (!layerToClean) return

        try {
            if (!layerToClean.isEditable) layerToClean.startEditing()
            layerToClean.selectAll()
            if (layerToClean.deleteSelectedFeatures()) {
                layerToClean.commitChanges()
                layerToClean.startEditing()
                if (mapCanvas) mapCanvas.refresh()
            } else {
                layerToClean.rollBack()
                layerToClean.startEditing()
            }
        } catch (e) {
            if (layerToClean && layerToClean.isEditable) layerToClean.rollBack()
        }
    }

    // === FONCTIONS UTILITAIRES ===
    function findListViewRecursive(parentItem) {
        if (!parentItem) return null
        if (parentItem.hasOwnProperty("delegate") && parentItem.hasOwnProperty("model") && parentItem.hasOwnProperty("currentIndex")) return parentItem
        var kids = parentItem.data
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var found = findListViewRecursive(kids[i])
            if (found) return found
        }
        return null
    }

    function findHighlighterRecursive(parentItem) {
        if (!parentItem) return null
        var kids = parentItem.data
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var item = kids[i]
            if (item && item.hasOwnProperty("focusedColor") && item.hasOwnProperty("selectedColor")) {
                 // Ignore standard lists
                if (!item.hasOwnProperty("showSelectedOnly") || item.showSelectedOnly === false) {
                    highlightItem = item
                    origFocusColor = item.focusedColor
                    origSelectedColor = item.selectedColor
                    if (item.hasOwnProperty("color")) origBaseColor = item.color
                    return item
                }
            }
            var found = findHighlighterRecursive(item)
            if (found) return found
        }
        return null
    }

    function applyCustomColors() {
        if (!highlightItem) {
            var container = iface.findItemByObjectName("mapCanvasContainer")
            if (container) findHighlighterRecursive(container)
        }
        if (highlightItem) {
            highlightItem.focusedColor = targetFocusColor
            highlightItem.selectedColor = targetSelectedColor
            if (highlightItem.hasOwnProperty("color")) highlightItem.color = targetSelectedColor
        }
        if (qgisProject) qgisProject.selectionColor = targetSelectedColor
        if (mapCanvas) mapCanvas.refresh()
    }

    function restoreOriginalColors() {
        if (highlightItem) {
            highlightItem.focusedColor = origFocusColor
            highlightItem.selectedColor = origSelectedColor
            if (highlightItem.hasOwnProperty("color")) highlightItem.color = origBaseColor
        }
        if (qgisProject) qgisProject.selectionColor = origProjectColor
        if (mapCanvas) mapCanvas.refresh()
    }

    // === TIMERS ===
    Timer {
        id: autoCreateTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (targetPointLayer && !sourceIsPoints) {
                createTemporaryCentroids()
            }
        }
    }

    Timer {
        id: uiStateWatcher
        interval: 250; running: isFormVisible && filterActive; repeat: true
        onTriggered: {
            if (!featureFormItem) return
            if (!internalListView) internalListView = findListViewRecursive(featureFormItem)
            if (internalListView) {
                var isListNowVisible = (internalListView.visible === true && internalListView.opacity > 0)
                if (!wasListVisible && isListNowVisible && selectedLayer) {
                     if (savedExpr) {
                         try { selectedLayer.removeSelection(); selectedLayer.selectByExpression(savedExpr) } catch(e){}
                     } else selectedLayer.selectAll()
                     useListOffset = false; isReturnAction = true; zoomTimer.restart()
                }
                wasListVisible = isListNowVisible
            }
        }
    }

    Timer { id: searchDelayTimer; interval: 500; repeat: false; onTriggered: performDynamicSearch() }
    Timer { id: zoomTimer; interval: 200; repeat: false; onTriggered: performZoom() }

    Timer {
        id: openListTimer; interval: 250; repeat: false
        onTriggered: {
            if (featureFormItem && pendingFormLayer && pendingFormExpr) {
                try {
                    featureFormItem.model.setFeatures(pendingFormLayer, pendingFormExpr)
                    if (featureFormItem.extentController) featureFormItem.extentController.autoZoom = true
                    featureFormItem.show()
                    pendingFormLayer = null; pendingFormExpr = ""
                } catch(e) {}
            }
        }
    }

    // === FONCTIONS FILTRE ===
    function openFilterUI() {
        if (!filterActive) {
            showAllFeatures = false
            showFeatureList = false
            if (showListCheck) showListCheck.checked = false
            savedLayerName = ""; savedFieldName = ""; savedFilterText = ""; savedExpr = ""
            
            initFixedTargetLayer() // Assurer chargement

            useListOffset = false; isReturnAction = false
            if (valueField) { valueField.text = ""; valueField.model = [] }
            selectedLayer = null; pendingFormLayer = null; pendingFormExpr = ""
            sourceIsPoints = false
        } else {
            if (valueField) valueField.text = savedFilterText
        }
        updateLayers()
        searchDialog.open()
    }

    function removeAllFilters() {
        if (!sourceIsPoints) clearTargetLayer(true)
        restoreOriginalColors()

        var layers = ProjectUtils.mapLayers(qgisProject)
        for (var id in layers) {
            var pl = layers[id]
            if (pl && pl.type === 0) {
                try { pl.subsetString = ""; pl.removeSelection(); pl.triggerRepaint() } catch (_) {}
            }
        }

        if (featureFormItem) {
            featureFormItem.state = "Hidden"
            showFeatureList = false
            if (showListCheck) showListCheck.checked = false
        }

        filterActive = false; showAllFeatures = false
        savedLayerName = ""; savedFieldName = ""; savedFilterText = ""; savedExpr = ""
        useListOffset = false; isReturnAction = false
        selectedLayer = null
        mapCanvas.refresh()
        updateLayers()
        updateApplyState()
        mainWindow.displayToast(tr("Filter deleted"))
    }

    function performZoom() {
        if (!selectedLayer) return
        var bbox = selectedLayer.boundingBoxOfSelected()

        if (bbox === undefined || bbox === null || bbox.xMinimum > bbox.xMaximum) {
            var features = selectedLayer.selectedFeatures()
            if (features && features.length > 0) {
                if (features[0].geometry) bbox = features[0].geometry.boundingBox
            }
        }

        if (!bbox) return

        if (bbox.width === 0 && bbox.height === 0) {
            var epsilon = 0.00001
            bbox.xMinimum -= epsilon;
            bbox.xMaximum += epsilon
            bbox.yMinimum -= epsilon;
            bbox.yMaximum += epsilon
        }

        try {
            var destCrs = mapCanvas.mapSettings.destinationCrs
            var finalExtent = GeometryUtils.reprojectRectangle(bbox, selectedLayer.crs, destCrs)

            if (!finalExtent) return

            var cx = (finalExtent.xMinimum + finalExtent.xMaximum) / 2.0
            var cy = (finalExtent.yMinimum + finalExtent.yMaximum) / 2.0
            var minSize = (Math.abs(cx) > 180) ? 200.0 : 0.002

            if (finalExtent.width < minSize) {
                finalExtent.xMinimum = cx - (minSize / 2.0);
                finalExtent.xMaximum = cx + (minSize / 2.0)
            }
            if (finalExtent.height < minSize) {
                finalExtent.yMinimum = cy - (minSize / 2.0);
                finalExtent.yMaximum = cy + (minSize / 2.0)
            }

            var currentMapExtent = mapCanvas.mapSettings.extent
            var screenRatio = currentMapExtent.width / currentMapExtent.height
            var h = (finalExtent.height === 0) ? 0.001 : finalExtent.height
            var geomRatio = finalExtent.width / h
            
            // --- MODIFICATION MARGE ---
            // 1.1 = 10% de marge. 1.25 = 25% de marge (plus aéré)
            var marginScale = 1.25 
            // --------------------------

            var nw = 0;
            var nh = 0
            if (geomRatio > screenRatio) {
                nw = finalExtent.width * marginScale;
                nh = nw / screenRatio
            } else {
                nh = finalExtent.height * marginScale;
                nw = nh * screenRatio
            }

            if (isReturnAction) {
                nw = nw * 0.65;
                nh = nh * 0.65;
                isReturnAction = false
            }
            if (showFeatureList && useListOffset) {
                cy = cy - (nh * 0.25)
            }

            finalExtent.xMinimum = cx - (nw / 2.0);
            finalExtent.xMaximum = cx + (nw / 2.0)
            finalExtent.yMinimum = cy - (nh / 2.0);
            finalExtent.yMaximum = cy + (nh / 2.0)

            mapCanvas.mapSettings.setExtent(finalExtent, true)
            mapCanvas.refresh()
            applyCustomColors()

            // --- DÉSACTIVATION SÉLECTION SI TYPE POINT ---
            if (sourceIsPoints) {
                selectedLayer.removeSelection()
                selectedLayer.triggerRepaint()
                mapCanvas.refresh()
            }

        } catch (e) {
            console.error("Erreur Zoom: " + e)
        }
    }

    function applyFilter(allowFormOpen, doZoom) {
        if (!selectedLayer || !fieldSelector.currentText || !valueField.text) return
        if (allowFormOpen === undefined) allowFormOpen = true
        if (doZoom === undefined) doZoom = true

        try {
            savedLayerName = layerSelector.currentText
            savedFieldName = fieldSelector.currentText
            savedFilterText = valueField.text
            
            initFixedTargetLayer()
            if (!sourceIsPoints) clearTargetLayer(false)

            var fieldName = savedFieldName
            var values = savedFilterText.split(";").map(function(v) { return escapeValue(v.toLowerCase().trim()) }).filter(function(v) { return v.length > 0 })
            if (values.length === 0) return

            var expr = values.map(function(v) { return 'lower("' + fieldName + '") LIKE \'%' + v + '%\'' }).join(" OR ")
            savedExpr = expr

            selectedLayer.subsetString = showAllFeatures ? "" : expr
            selectedLayer.removeSelection()
            mapCanvas.mapSettings.selectionColor = targetSelectedColor
            selectedLayer.selectByExpression(expr)
            selectedLayer.triggerRepaint()
            mapCanvas.refresh()

            if (showFeatureList && featureFormItem && selectedLayer === getLayerByName(savedLayerName)) {
                pendingFormLayer = selectedLayer; pendingFormExpr = expr; openListTimer.restart()
            }

            if (doZoom) { useListOffset = true; isReturnAction = false; zoomTimer.start() }
            filterActive = true

            if (targetPointLayer && !sourceIsPoints) autoCreateTimer.restart()
        } catch(e) { mainWindow.displayToast(tr("Error: ") + e) }
    }

    // === UI UTILS ===
    function updateLayers() {
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers) if (layers[id] && layers[id].type === 0) names.push(layers[id].name)
        names.sort()
        if (!filterActive) names.unshift(tr("Select a layer"))
        if (layerSelector) {
            layerSelector.model = names
            if (filterActive && savedLayerName) {
                var idx = names.indexOf(savedLayerName)
                layerSelector.currentIndex = idx >= 0 ? idx : 0
            } else layerSelector.currentIndex = 0
        }
    }

    function getLayerByName(name) {
        var layers = ProjectUtils.mapLayers(qgisProject)
        for (var id in layers) if (layers[id].name === name) return layers[id]
        return null
    }

    function getFields(layer) {
        if (!layer || !layer.fields) return []
        var fields = layer.fields
        return fields.names ? fields.names.slice().sort() : []
    }

    function updateFields() {
        if (!selectedLayer) {
            fieldSelector.model = [tr("Select a field")]
            fieldSelector.currentIndex = 0; return
        }
        var fields = getFields(selectedLayer)
        if (!filterActive) fields.unshift(tr("Select a field"))
        fieldSelector.model = fields
        if (filterActive && savedFieldName) {
            var idx = fields.indexOf(savedFieldName)
            fieldSelector.currentIndex = idx >= 0 ? idx : 0
        } else {
            fieldSelector.currentIndex = 0; valueField.model = []
        }
        updateApplyState()
    }

    function performDynamicSearch() {
        var rawText = valueField.text
        var parts = rawText.split(";")
        var searchText = parts[parts.length - 1].trim()
        var uiName = fieldSelector.currentText

        if (!selectedLayer || uiName === tr("Select a field") || searchText === "") {
            valueField.model = []; suggestionPopup.close(); return
        }

        valueField.isLoading = true
        var names = selectedLayer.fields.names
        var logicalIndex = -1
        for (var i = 0; i < names.length; i++) { if (names[i] === uiName) { logicalIndex = i; break } }
        
        if (logicalIndex === -1) { valueField.isLoading = false; return }

        var realIndex = -1
        var attributes = selectedLayer.attributeList()
        if (attributes && logicalIndex < attributes.length) realIndex = attributes[logicalIndex]
        else realIndex = logicalIndex + 1

        var uniqueValues = {}; var valuesArray = []

        try {
            var expression = "\"" + uiName + "\" ILIKE '%" + searchText.replace(/'/g, "''") + "%'"
            var feature_iterator = LayerUtils.createFeatureIteratorFromExpression(selectedLayer, expression)
            var count = 0; var max_scan = 5000

            while (feature_iterator.hasNext() && count < 50 && max_scan > 0) {
                var feature = feature_iterator.next()
                var val = feature.attribute(realIndex)
                if (val === undefined) val = feature.attribute(uiName)
                if (val !== null && val !== undefined) {
                    var strVal = String(val).trim()
                    if (strVal !== "" && strVal !== "NULL") {
                         var exists = false
                         for(var p=0;p<parts.length-1;p++) if(parts[p].trim()===strVal) exists=true
                         if(!uniqueValues[strVal] && !exists) { uniqueValues[strVal]=true; valuesArray.push(strVal); count++ }
                    }
                }
                max_scan--
            }
            valuesArray.sort()
            valueField.model = valuesArray
            if (valuesArray.length > 0) suggestionPopup.open()
            else suggestionPopup.close()
        } catch (e) {}
        valueField.isLoading = false
    }

    function updateApplyState() {
        if (applyButton && selectedLayer && fieldSelector && valueField) {
            applyButton.enabled = selectedLayer !== null && fieldSelector.currentText && fieldSelector.currentText !== tr("Select a field") && valueField.text.length > 0
        }
    }

    function escapeValue(value) { return value.trim().replace(/'/g, "''") }

        function tr(text) {
        var isFr = Qt.locale().name.substring(0, 2) === "fr"
        var dic = {
            "FILTER": "FILTRE",
            "Filter deleted": "Filtre supprimé",
            "Select a layer": "Sélectionnez une couche",
            "Select a field": "Sélectionnez un champ",
            "Filter value(s) (separate by ;) :": "Valeur(s) du filtre (séparer par ;) :",
            "Type to search (ex: Paris; Lyon)...": "Tapez pour rechercher (ex: Paris; Lyon)...",
            "Show all geometries (+filtered)": "Afficher toutes géométries (+filtrées)",
            "Show feature list": "Afficher liste des entités",
            "Apply filter": "Appliquer le filtre",
            "Delete filter": "Supprimer le filtre",
            // Message d'erreur spécifique ajouté
            "Erreur: filter_points.gpkg introuvable ou corrompu.": "Erreur: filter_points.gpkg introuvable dans le dossier du plugin."
        }
        return isFr && dic[text] ? dic[text] : text
    }

    // === CONNEXIONS UI ===
    Connections {
        target: featureFormItem; ignoreUnknownSignals: true
        function onVisibleChanged() {
            filterToolRoot.isFormVisible = featureFormItem.visible
            if (!featureFormItem.visible) {
                internalListView = null; wasListVisible = true; showFeatureList = false
                if (showListCheck) showListCheck.checked = false
                if (filterActive) {
                   if (selectedLayer) { mapCanvas.mapSettings.selectionColor = targetSelectedColor; selectedLayer.triggerRepaint(); mapCanvas.refresh() }
                }
            }
        }
        function onFeatureSelected(feature) {
            if (feature && selectedLayer) {
                selectedLayer.removeSelection(); selectedLayer.select(feature.id)
                applyCustomColors()
                useListOffset = true; isReturnAction = false; zoomTimer.start()
            }
        }
    }

    Rectangle {
        id: infoBanner
        parent: mapCanvas; z: 9999
        height: 38                              // Hauteur confortable
        anchors.bottom: parent.bottom; anchors.bottomMargin: 60
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(bannerLayout.implicitWidth + 30, parent.width - 120)
        radius: 19                              // 19 = la moitié de 38 pour un arrondi parfait
        color: "#B3333333"; border.width: 0
        visible: filterToolRoot.filterActive && !filterToolRoot.isFormVisible

        RowLayout {
            id: bannerLayout
            anchors.fill: parent
            // --- CORRECTION MAJEURE ICI ---
            // On remplace anchors.margins: 15 par seulement gauche/droite
            anchors.leftMargin: 15
            anchors.rightMargin: 15
            // ------------------------------
            spacing: 10

            Rectangle { 
                width: 8; height: 8; radius: 4; 
                color: targetSelectedColor; 
                Layout.alignment: Qt.AlignVCenter 
            }

            Item {
                id: clipContainer
                Layout.preferredWidth: bannerText.contentWidth
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                
                Text {
                    id: bannerText
                    // --- CORRECTION TEXTE ---
                    height: parent.height                  // Prend toute la hauteur disponible
                    verticalAlignment: Text.AlignVCenter   // Centre le texte
                    renderType: Text.NativeRendering       // Meilleur rendu sur Android
                    // ------------------------

                    text: {
                        var val = filterToolRoot.savedFilterText.trim()
                        if (val.endsWith(";")) val = val.substring(0, val.length - 1).trim()
                        return filterToolRoot.savedLayerName + " | " + filterToolRoot.savedFieldName + " : " + val
                    }
                    color: "white"; font.bold: true; font.pixelSize: 14 // Légèrement agrandi à 14

                    wrapMode: Text.NoWrap
                    horizontalAlignment: Text.AlignLeft
                    
                    x: 0
                    SequentialAnimation on x {
                        running: clipContainer && bannerText.contentWidth > clipContainer.width && infoBanner.visible
                        loops: Animation.Infinite
                        PauseAnimation { duration: 2000 }
                        NumberAnimation { to: (clipContainer ? clipContainer.width : 0) - bannerText.contentWidth; duration: 4000; easing.type: Easing.InOutQuad }
                        PauseAnimation { duration: 1000 }
                        NumberAnimation { to: 0; duration: 4000; easing.type: Easing.InOutQuad }
                    }
                }
            }
        }
    }

    Dialog {
        id: searchDialog
        parent: mainWindow.contentItem
        modal: true; width: Math.min(450, mainWindow.width * 0.90)
        height: mainCol.implicitHeight + 30
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2 - (parent.height > parent.width ? parent.height*0.1 : 0)
        background: Rectangle { color: "white"; border.color: "#80cc28"; border.width: 3; radius: 8 }
        MouseArea { anchors.fill: parent; z: -1; onClicked: { if(valueField.focus) {valueField.focus=false; suggestionPopup.close()}; mouse.accepted=false } }

        ColumnLayout {
            id: mainCol; anchors.fill: parent; anchors.margins: 8; spacing: 10
            Label { text: tr("FILTER"); font.bold: true; font.pointSize: 18; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true }
            
            QfComboBox {
                id: layerSelector; Layout.fillWidth: true; Layout.preferredHeight: 35; model: []
                onCurrentTextChanged: {
                    savedExpr = ""; if (currentText === tr("Select a layer")) { selectedLayer=null; fieldSelector.model=[tr("Select a field")]; return }
                    selectedLayer = getLayerByName(currentText); updateFields(); checkSourceGeometryType()
                }
            }
            QfComboBox {
                id: fieldSelector; Layout.fillWidth: true; Layout.preferredHeight: 35; model: []
                onActivated: { valueField.text=""; valueField.model=[]; updateApplyState() }
                onCurrentTextChanged: updateApplyState()
            }
            Label { text: tr("Filter value(s) (separate by ;) :") }
            TextField {
                id: valueField; Layout.fillWidth: true; Layout.preferredHeight: 35; placeholderText: tr("Type to search (ex: Paris; Lyon)...")
                property var model: []; property bool isLoading: false
                onActiveFocusChanged: { if (activeFocus && text.trim().length > 0) { if (model.length>0) suggestionPopup.open(); else performDynamicSearch() } }
                onTextEdited: { if(text.trim().length>0) searchDelayTimer.restart(); else {searchDelayTimer.stop(); suggestionPopup.close()} updateApplyState() }
                Popup {
                    id: suggestionPopup; y: valueField.height; width: valueField.width; height: Math.min(listView.contentHeight+10, 200); padding: 1
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                    background: Rectangle { color: "white"; border.color: "#bdbdbd" }
                    ListView {
                        id: listView; anchors.fill: parent; clip: true; model: valueField.model
                        delegate: ItemDelegate {
                            text: modelData; width: listView.width
                            onClicked: {
                                var txt=valueField.text; var last=txt.lastIndexOf(";");
                                valueField.text = (last===-1 ? modelData : txt.substring(0, last+1)+" "+modelData) + " ; "
                                suggestionPopup.close(); valueField.forceActiveFocus(); valueField.model=[]
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true; spacing: -10
                CheckBox {
                    id: showAllCheck; text: tr("Show all geometries (+filtered)"); checked: showAllFeatures
                    onToggled: { showAllFeatures = checked; if (filterActive) applyFilter(true, false) }
                }
                CheckBox {
                    id: showListCheck; text: tr("Show feature list"); checked: showFeatureList
                    onToggled: { showFeatureList = checked; if (filterActive && checked) applyFilter(true, false) }
                }
            }

            RowLayout {
                Layout.fillWidth: true; spacing: 5
                Button {
                    text: tr("Delete filter"); Layout.fillWidth: true
                    background: Rectangle { color: "#333333"; radius: 10 }
                    contentItem: Text { text: parent.text; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: { removeAllFilters(); searchDialog.close() }
                }
                Button {
                    id: applyButton; text: tr("Apply filter"); enabled: false; Layout.fillWidth: true
                    background: Rectangle { radius: 10; color: enabled ? "#80cc28" : "#e0e0e0" }
                    contentItem: Text { text: parent.text; color: enabled ? "white" : "#666666"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: { applyFilter(true, true); searchDialog.close() }
                }
            }
        }
    }
}