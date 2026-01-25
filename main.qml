import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Theme
import org.qfield
import org.qgis

Item {
    id: filterToolRoot

    // === PROPRIÉTÉS GLOBALES (Code 2) ===
    property var mainWindow: iface.mainWindow()
    property var mapCanvas: iface.mapCanvas()
    property var selectedLayer: null
    property var featureFormItem: iface.findItemByObjectName("featureForm")

    // État du filtre
    property bool filterActive: false
    property bool isFormVisible: false

    // Persistance
    property bool showAllFeatures: false
    property bool showFeatureList: false
    property string savedLayerName: ""
    property string savedFieldName: ""
    property string savedFilterText: ""
    
    // Stockage de la requête exacte pour la restauration
    property string savedExpr: "" 
    
    // Contrôle le décalage du zoom (vrai = décalé vers le bas pour la liste)
    property bool useListOffset: false

    // Variable pour détecter le retour arrière et zoomer plus fort
    property bool isReturnAction: false

    // === PROPRIÉTÉS GESTION BOUTON (Ajout Code 1) ===
    property bool wasLongPress: false

    // === GESTION DES COULEURS PERSONNALISÉES ===
    property color targetFocusColor: "#D500F9"
    property color targetSelectedColor: "#23FF0A"
    property color origFocusColor: "#ff7777"
    property color origSelectedColor: Theme.mainColor
    property color origBaseColor: "yellow"
    property color origProjectColor: "yellow"
    property var highlightItem: null

    // Variables pour la liste des entités
    property var pendingFormLayer: null
    property string pendingFormExpr: ""

    // --- VARIABLES DE DÉTECTION DU RETOUR LISTE ---
    property var internalListView: null
    property bool wasListVisible: true

    // === INITIALISATION ===
    Component.onCompleted: {
        // Ajout du bouton à la barre d'outils (Venant du Code 1)
        iface.addItemToPluginsToolbar(toolbarButton)

        updateLayers()
        if (featureFormItem) isFormVisible = featureFormItem.visible
        
        // Initialisation des couleurs
        var container = iface.findItemByObjectName("mapCanvasContainer")
        if (container) findHighlighterRecursive(container)
        if (qgisProject) origProjectColor = qgisProject.selectionColor
        applyCustomColors()
    }

    // === BOUTON TOOLBAR (Venant du Code 1 - Adapté pour utiliser les fonctions du Code 2) ===
    QfToolButton {
        id: toolbarButton
        iconSource: "icon.svg"
        iconColor: Theme.mainColor
        bgcolor: Theme.darkGray
        round: true

        onClicked: {
            if (!filterToolRoot.wasLongPress) {
                // Appel de la fonction d'ouverture du Code 2
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
                // Appel de la fonction de nettoyage du Code 2
                removeAllFilters()
                // Le toast est géré dans removeAllFilters
            }
        }
    }

    // === FONCTIONS LOGIQUES (Code 2) ===

    function findListViewRecursive(parentItem) {
        if (!parentItem) return null
        if (parentItem.hasOwnProperty("delegate") && 
            parentItem.hasOwnProperty("model") && 
            parentItem.hasOwnProperty("currentIndex")) {
            return parentItem
        }
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
            if (item && item.hasOwnProperty("focusedColor") &&
                item.hasOwnProperty("selectedColor") &&
                item.hasOwnProperty("selectionModel")) {
                if (!item.hasOwnProperty("showSelectedOnly") || item.showSelectedOnly === false) {
                    highlightItem = item
                    origFocusColor = item.focusedColor
                    origSelectedColor = item.selectedColor
                    if (item.hasOwnProperty("color")) origBaseColor = item.color
                    return item
                }
            }
            if (item.data) {
                var found = findHighlighterRecursive(item)
                if (found) return found
            }
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
        if (qgisProject) {
            qgisProject.selectionColor = targetSelectedColor
        }
        if (mapCanvas) mapCanvas.refresh()
    }

    function restoreOriginalColors() {
        if (highlightItem) {
            highlightItem.focusedColor = origFocusColor
            highlightItem.selectedColor = origSelectedColor
            if (highlightItem.hasOwnProperty("color")) highlightItem.color = origBaseColor
        }
        if (qgisProject) {
            qgisProject.selectionColor = origProjectColor
        }
        if (mapCanvas) mapCanvas.refresh()
    }

    // === TIMERS (Code 2) ===

    // Timer de surveillance du bouton "Retour"
    Timer {
        id: uiStateWatcher
        interval: 250
        running: isFormVisible && filterActive
        repeat: true
        onTriggered: {
            if (!featureFormItem) return

            if (!internalListView) {
                internalListView = findListViewRecursive(featureFormItem)
            }

            if (internalListView) {
                var isListNowVisible = (internalListView.visible === true && internalListView.opacity > 0)

                // DÉTECTION DU RETOUR (Détail -> Liste)
                if (!wasListVisible && isListNowVisible) {
                    if (selectedLayer) {
                        // Restauration de la sélection complète
                        if (savedExpr && savedExpr !== "") {
                            try {
                                selectedLayer.removeSelection()
                                selectedLayer.selectByExpression(savedExpr)
                            } catch(e) {}
                        } else {
                            selectedLayer.selectAll()
                        }
                        
                        // CONFIGURATION DU ZOOM DE RETOUR
                        useListOffset = false // Pas de décalage vertical (centré)
                        isReturnAction = true // Active le mode "Zoom plus proche"
                        zoomTimer.restart()
                    }
                }
                wasListVisible = isListNowVisible
            }
        }
    }

    Timer {
        id: searchDelayTimer
        interval: 500
        repeat: false
        onTriggered: performDynamicSearch()
    }

    Timer {
        id: openListTimer
        interval: 250
        repeat: false
        onTriggered: {
            if (featureFormItem && pendingFormLayer && pendingFormExpr && pendingFormExpr !== "") {
                try {
                    featureFormItem.model.setFeatures(pendingFormLayer, pendingFormExpr)
                    if (featureFormItem.extentController) {
                        featureFormItem.extentController.autoZoom = true
                    }
                    featureFormItem.show()
                    
                    pendingFormLayer = null
                    pendingFormExpr = ""
                } catch(e) {
                    console.warn("Erreur ouverture liste: ", e)
                }
            }
        }
    }

    Timer {
        id: zoomTimer
        interval: 200
        repeat: false
        onTriggered: performZoom()
    }

    // === FONCTIONS PRINCIPALES (Code 2) ===

    function openFilterUI() {
        if (!filterActive) {
            showAllFeatures = false
            showFeatureList = false
            if(showListCheck) showListCheck.checked = false
            savedLayerName = ""
            savedFieldName = ""
            savedFilterText = ""
            savedExpr = ""
            useListOffset = false
            isReturnAction = false
            if(valueField) {
                valueField.text = ""
                valueField.model = []
            }
            selectedLayer = null
            pendingFormLayer = null
            pendingFormExpr = ""
        } else {
            if(valueField) valueField.text = savedFilterText
        }
        updateLayers()
        searchDialog.open()
    }

    function removeAllFilters() {
        restoreOriginalColors()

        var layers = ProjectUtils.mapLayers(qgisProject)
        for (var id in layers) {
            var pl = layers[id]
            if (pl && pl.type === 0) {
                try {
                    pl.subsetString = ""
                    pl.removeSelection()
                    pl.triggerRepaint()
                } catch (_) {}
            }
        }

        if (featureFormItem) {
            featureFormItem.state = "Hidden"
            showFeatureList = false
            if(showListCheck) showListCheck.checked = false
        }

        filterActive = false
        showAllFeatures = false
        savedLayerName = ""
        savedFieldName = ""
        savedFilterText = ""
        savedExpr = ""
        useListOffset = false
        isReturnAction = false
        pendingFormLayer = null
        pendingFormExpr = ""

        if(valueField) {
            valueField.text = ""
            valueField.model = []
        }

        selectedLayer = null
        mapCanvas.refresh()
        updateLayers()
        updateApplyState()
        mainWindow.displayToast(tr("Filter deleted"))
    }

    // === ZOOM LOGIC (Code 2 Optimisé) ===

    function performZoom() {
        if (!selectedLayer) return

        // 1. Récupération de l'étendue (BoundingBox)
        var bbox = selectedLayer.boundingBoxOfSelected()
        
        // Gestion des cas limites (points uniques ou bbox invalide)
        if (bbox === undefined || bbox === null || bbox.xMinimum > bbox.xMaximum) {
             var selectedFeatures = selectedLayer.selectedFeatures()
             if (selectedFeatures.length > 0 && selectedFeatures[0].geometry()) {
                 bbox = selectedFeatures[0].geometry().boundingBox()
             } else {
                 return 
             }
        }

        // Si hauteur/largeur est 0 (ex: un point parfait), on ajoute un epsilon
        if (bbox.width === 0 && bbox.height === 0) {
            var epsilon = 0.00001
            bbox.xMinimum -= epsilon
            bbox.xMaximum += epsilon
            bbox.yMinimum -= epsilon
            bbox.yMaximum += epsilon
        }

        try {
            // 2. Reprojection vers le CRS de la carte
            var destCrs = mapCanvas.mapSettings.destinationCrs
            var finalExtent = GeometryUtils.reprojectRectangle(bbox, selectedLayer.crs, destCrs)

            if (!finalExtent) return

            // 3. Calcul du centre
            var cx = (finalExtent.xMinimum + finalExtent.xMaximum) / 2.0
            var cy = (finalExtent.yMinimum + finalExtent.yMaximum) / 2.0

            // 4. Définition de la taille minimum
            var minSize = (Math.abs(cx) > 180) ? 200.0 : 0.002

            if (finalExtent.width < minSize) {
                finalExtent.xMinimum = cx - (minSize / 2.0)
                finalExtent.xMaximum = cx + (minSize / 2.0)
            }
            if (finalExtent.height < minSize) {
                finalExtent.yMinimum = cy - (minSize / 2.0)
                finalExtent.yMaximum = cy + (minSize / 2.0)
            }

            // 5. Calcul du Ratio Écran
            var currentMapExtent = mapCanvas.mapSettings.extent
            var screenRatio = currentMapExtent.width / currentMapExtent.height
            var h = (finalExtent.height === 0) ? 0.001 : finalExtent.height
            var geomRatio = finalExtent.width / h
            var marginScale = 1.1

            var nw = 0
            var nh = 0

            // Adaptation au ratio de l'écran
            if (geomRatio > screenRatio) {
                nw = finalExtent.width * marginScale
                nh = nw / screenRatio
            } else {
                nh = finalExtent.height * marginScale
                nw = nh * screenRatio
            }

            // --- ZOOM "PLUS PROCHE" AU RETOUR ---
            if (isReturnAction) {
                // On réduit la taille de la vue de 35% -> Effet Zoom In
                nw = nw * 0.65
                nh = nh * 0.65
                isReturnAction = false
            }

            // 6. Application du décalage conditionnel (LISTE)
            // On décale le centre visé vers le BAS (Sud) uniquement si useListOffset est vrai
            if (showFeatureList && useListOffset) {
                cy = cy - (nh * 0.25)
            }

            // 7. Application finale
            finalExtent.xMinimum = cx - (nw / 2.0)
            finalExtent.xMaximum = cx + (nw / 2.0)
            finalExtent.yMinimum = cy - (nh / 2.0)
            finalExtent.yMaximum = cy + (nh / 2.0)

            mapCanvas.mapSettings.setExtent(finalExtent, true)
            mapCanvas.refresh()
            applyCustomColors()

        } catch(e) {
            console.error("Erreur Zoom: " + e)
        }
    }

    function refreshVisualsOnly() {
        if (selectedLayer) {
            mapCanvas.mapSettings.selectionColor = targetSelectedColor
            selectedLayer.triggerRepaint()
            mapCanvas.refresh()
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

            var fieldName = savedFieldName
            var values = savedFilterText.split(";").map(function(v) {
                return escapeValue(v.toLowerCase().trim())
            }).filter(function(v) {
                return v.length > 0
            })

            if (values.length === 0) return

            var expr = values.map(function(v) {
                return 'lower("' + fieldName + '") LIKE \'%' + v + '%\''
            }).join(" OR ")
            
            savedExpr = expr

            if (showAllFeatures) selectedLayer.subsetString = ""
            else selectedLayer.subsetString = expr

            selectedLayer.removeSelection()
            mapCanvas.mapSettings.selectionColor = targetSelectedColor
            selectedLayer.selectByExpression(expr)

            selectedLayer.triggerRepaint()
            mapCanvas.refresh()

            if (showFeatureList && featureFormItem && selectedLayer === getLayerByName(savedLayerName)) {
                pendingFormLayer = selectedLayer
                pendingFormExpr = expr
                openListTimer.restart()
            }

            if (doZoom) {
                // ICI : On active le décalage car la liste va s'ouvrir
                useListOffset = true
                isReturnAction = false
                zoomTimer.start()
            }
            filterActive = true

        } catch(e) {
            mainWindow.displayToast(tr("Error: ") + e)
        }
    }

    // === UTILS ===

    function updateLayers() {
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers)
            if (layers[id] && layers[id].type === 0)
                names.push(layers[id].name)
        names.sort()
        if (!filterActive) names.unshift(tr("Select a layer"))
        if (layerSelector) {
            layerSelector.model = names
            if (filterActive && savedLayerName !== "") {
                var idx = names.indexOf(savedLayerName)
                layerSelector.currentIndex = idx >= 0 ? idx : 0
            } else {
                layerSelector.currentIndex = 0
            }
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
            fieldSelector.currentIndex = 0
            return
        }
        var fields = getFields(selectedLayer)
        if (!filterActive) fields.unshift(tr("Select a field"))
        fieldSelector.model = fields
        if (filterActive && savedFieldName !== "") {
            var idx = fields.indexOf(savedFieldName)
            fieldSelector.currentIndex = idx >= 0 ? idx : 0
        } else {
            fieldSelector.currentIndex = 0
            valueField.model = []
        }
        updateApplyState()
    }

    function performDynamicSearch() {
        var rawText = valueField.text
        var parts = rawText.split(";")
        var lastPart = parts[parts.length - 1]
        var searchText = lastPart.trim()
        var uiName = fieldSelector.currentText

        if (!selectedLayer || uiName === tr("Select a field") || searchText === "") {
            valueField.model = []
            suggestionPopup.close()
            return
        }

        valueField.isLoading = true

        var names = selectedLayer.fields.names
        var logicalIndex = -1
        for (var i = 0; i < names.length; i++) {
            if (names[i] === uiName) {
                logicalIndex = i
                break
            }
        }
        if (logicalIndex === -1) {
            valueField.isLoading = false
            return
        }

        var realIndex = -1
        var attributes = selectedLayer.attributeList()
        if (attributes && logicalIndex < attributes.length) realIndex = attributes[logicalIndex]
        else realIndex = logicalIndex + 1

        var uniqueValues = {}
        var valuesArray = []

        try {
            var escapedText = searchText.replace(/'/g, "''")
            var expression = "\"" + uiName + "\" ILIKE '%" + escapedText + "%'"

            var feature_iterator = LayerUtils.createFeatureIteratorFromExpression(selectedLayer, expression)

            var count = 0
            var max_display_items = 50
            var safety_counter = 0
            var max_scan = 5000

            while (feature_iterator.hasNext() && count < max_display_items && safety_counter < max_scan) {
                var feature = feature_iterator.next()
                var val = feature.attribute(realIndex)
                if (val === undefined) val = feature.attribute(uiName)

                if (val !== null && val !== undefined) {
                    var strVal = String(val).trim()
                    if (strVal !== "" && strVal !== "NULL") {
                        var alreadyInText = false
                        for(var p=0; p<parts.length-1; p++) {
                            if (parts[p].trim() === strVal) {
                                alreadyInText = true
                                break
                            }
                        }

                        if (!uniqueValues[strVal] && !alreadyInText) {
                            uniqueValues[strVal] = true
                            valuesArray.push(strVal)
                            count++
                        }
                    }
                }
                safety_counter++
            }

            valuesArray.sort()
            valueField.model = valuesArray

            if (valuesArray.length > 0) {
                suggestionPopup.open()
            } else {
                suggestionPopup.close()
            }

        } catch (e) {
            console.log("Error searching: " + e)
        }

        valueField.isLoading = false
    }

    function updateApplyState() {
        if(applyButton && selectedLayer && fieldSelector && valueField) {
            applyButton.enabled = selectedLayer !== null &&
                                fieldSelector.currentText &&
                                fieldSelector.currentText !== tr("Select a field") &&
                                valueField.text.length > 0
        }
    }

    function escapeValue(value) {
        return value.trim().replace(/'/g, "''")
    }

    // === CONNEXIONS ===

    Connections {
        target: featureFormItem
        ignoreUnknownSignals: true 

        function onVisibleChanged() {
            filterToolRoot.isFormVisible = featureFormItem.visible
            
            if (!featureFormItem.visible) {
                internalListView = null
                wasListVisible = true
                showFeatureList = false
                if(showListCheck) showListCheck.checked = false

                if (filterActive) {
                    refreshVisualsOnly()
                }
            }
        }
    }

    Connections {
        target: featureFormItem
        ignoreUnknownSignals: true
        function onFeatureSelected(feature) {
            if (feature && selectedLayer) {
                selectedLayer.removeSelection()
                selectedLayer.select(feature.id())
                applyCustomColors()
                // Si on sélectionne un point dans la liste, on veut qu'il soit visible au-dessus de la liste
                // Mais on ne veut pas l'effet "zoom serré" du retour
                useListOffset = true 
                isReturnAction = false
                zoomTimer.start()
            }
        }
    }

    // === INTERFACE UTILISATEUR (DIALOGUE ET BANNER) ===

    function tr(text) {
        var isFrench = Qt.locale().name.substring(0, 2) === "fr"
        var dictionary = {
            "Filter deleted": "Filtre supprimé", "FILTER": "FILTRE",
            "Select a layer": "Sélectionnez une couche", "Select a field": "Sélectionnez un champ",
            "Filter value(s) (separate by ;) :": "Valeur(s) du filtre (séparer par ;) :",
            "Show all geometries (+filtered)": "Afficher toutes géométries (+filtrées)",
            "Show feature list": "Afficher liste des entités", "Apply filter": "Appliquer le filtre",
            "Delete filter": "Supprimer le filtre", "Error fetching values: ": "Erreur récupération valeurs : ",
            "Error Zoom: ": "Erreur Zoom : ", "Error: ": "Erreur : ",
            "Searching...": "Recherche...", "Type to search (ex: Paris; Lyon)...": "Tapez pour rechercher (ex: Paris; Lyon)...",
            "Active Filter:": "Filtre Actif :"
        }
        return isFrench && dictionary[text] !== undefined ? dictionary[text] : text
    }

    Rectangle {
        id: infoBanner
        parent: mapCanvas
        z: 9999; height: 32
        anchors.bottom: parent.bottom; anchors.bottomMargin: 60
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(bannerLayout.implicitWidth + 30, parent.width - 120)
        radius: 16; color: "#B3333333"; border.width: 0
        visible: filterToolRoot.filterActive && !filterToolRoot.isFormVisible

        RowLayout {
            id: bannerLayout
            anchors.fill: parent; anchors.leftMargin: 15; anchors.rightMargin: 15
            spacing: 10
            Rectangle {
                width: 8; height: 8; radius: 4
                color: targetSelectedColor
                Layout.alignment: Qt.AlignVCenter
            }
            Item {
                id: clipContainer
                Layout.preferredWidth: bannerText.contentWidth
                Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                Text {
                    id: bannerText
                    text: {
                        var val = filterToolRoot.savedFilterText.trim()
                        if (val.endsWith(";")) val = val.substring(0, val.length - 1).trim()
                        return filterToolRoot.savedLayerName + " | " + filterToolRoot.savedFieldName + " : " + val
                    }
                    color: "white"; font.bold: true; font.pixelSize: 13
                    wrapMode: Text.NoWrap; horizontalAlignment: Text.AlignLeft
                    verticalAlignment: Text.AlignVCenter; anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    SequentialAnimation on x {
                        running: clipContainer && bannerText.contentWidth > clipContainer.width && infoBanner.visible
                        loops: Animation.Infinite
                        PauseAnimation { duration: 2000 }
                        NumberAnimation {
                            to: (clipContainer ? clipContainer.width : 0) - bannerText.contentWidth
                            duration: Math.max(0, (bannerText.contentWidth - (clipContainer ? clipContainer.width : 0)) * 20 + 2000)
                            easing.type: Easing.InOutQuad
                        }
                        PauseAnimation { duration: 1000 }
                        NumberAnimation {
                            to: 0
                            duration: Math.max(0, (bannerText.contentWidth - (clipContainer ? clipContainer.width : 0)) * 20 + 2000)
                            easing.type: Easing.InOutQuad
                        }
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
        y: {
            var centerPos = (parent.height - height) / 2
            var isPortrait = parent.height > parent.width
            var offset = isPortrait ? (parent.height * 0.10) : 0
            return centerPos - offset
        }
        background: Rectangle { color: "white"; border.color: "#80cc28"; border.width: 3; radius: 8 }
        MouseArea {
            anchors.fill: parent; z: -1; propagateComposedEvents: true
            onClicked: {
                if (valueField.focus) { valueField.focus = false; suggestionPopup.close() }
                mouse.accepted = false
            }
        }
        ColumnLayout {
            id: mainCol
            anchors.fill: parent; anchors.margins: 8; spacing: 12
            Label {
                text: tr("FILTER"); font.bold: true; font.pointSize: 18; color: "black"
                horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                Layout.topMargin: -10; Layout.bottomMargin: 2
            }
            QfComboBox {
                id: layerSelector; Layout.fillWidth: true; Layout.preferredHeight: 35
                Layout.topMargin: -10; topPadding: 2; bottomPadding: 2; model: []
                onCurrentTextChanged: {
                    savedExpr = "" 
                    if (currentText === tr("Select a layer")) {
                        selectedLayer = null; fieldSelector.model = [tr("Select a field")]
                        fieldSelector.currentIndex = 0; valueField.model = []
                        updateApplyState(); return
                    }
                    selectedLayer = getLayerByName(currentText)
                    updateFields(); updateApplyState()
                }
            }
            QfComboBox {
                id: fieldSelector; Layout.fillWidth: true; Layout.preferredHeight: 35
                topPadding: 2; bottomPadding: 2; model: []
                onActivated: { valueField.text = ""; valueField.model = []; updateApplyState() }
                onCurrentTextChanged: updateApplyState()
            }
            Label {
                text: tr("Filter value(s) (separate by ;) :")
                Layout.topMargin: -8; Layout.bottomMargin: -10
            }
            TextField {
                id: valueField; Layout.fillWidth: true; Layout.preferredHeight: 35
                topPadding: 6; bottomPadding: 6
                placeholderText: tr("Type to search (ex: Paris; Lyon)...")
                Layout.bottomMargin: 2
                property var model: []; property bool isLoading: false
                onActiveFocusChanged: {
                    if (activeFocus) {
                        var parts = text.split(";")
                        var lastPart = parts[parts.length - 1].trim()
                        if (lastPart.length > 0) {
                            if (model.length > 0) suggestionPopup.open()
                            else performDynamicSearch()
                        }
                    }
                }
                onTextEdited: {
                    var parts = text.split(";")
                    var lastPart = parts[parts.length - 1].trim()
                    if (lastPart.length > 0) searchDelayTimer.restart()
                    else { searchDelayTimer.stop(); suggestionPopup.close(); model = [] }
                    updateApplyState()
                }
                onTextChanged: updateApplyState()
                onAccepted: { suggestionPopup.close(); updateApplyState() }
                BusyIndicator {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 5; height: parent.height * 0.6; width: height
                    running: valueField.isLoading; visible: valueField.isLoading
                }
                Popup {
                    id: suggestionPopup; y: valueField.height; width: valueField.width
                    height: Math.min(listView.contentHeight + 10, 200); padding: 1
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                    background: Rectangle { color: "white"; border.color: "#bdbdbd"; radius: 2 }
                    ListView {
                        id: listView; anchors.fill: parent; clip: true; model: valueField.model
                        delegate: ItemDelegate {
                            text: modelData; width: listView.width
                            background: Rectangle { color: parent.highlighted ? "#e0e0e0" : "transparent" }
                            onClicked: {
                                var currentText = valueField.text; var lastSep = currentText.lastIndexOf(";")
                                var newText = lastSep === -1 ? modelData + " ; " :
                                              currentText.substring(0, lastSep + 1) + " " + modelData + " ; "
                                valueField.text = newText; suggestionPopup.close()
                                valueField.forceActiveFocus(); valueField.model = []
                            }
                        }
                    }
                }
            }
            CheckBox {
                id: showAllCheck
                text: tr("Show all geometries (+filtered)")
                checked: showAllFeatures
                Layout.fillWidth: true
                Layout.topMargin: -12
                Layout.bottomMargin: -12
                onToggled: {
                    showAllFeatures = checked
                    if (filterActive) applyFilter(true, false)
                }
            }
            CheckBox {
                id: showListCheck
                text: tr("Show feature list")
                checked: showFeatureList
                Layout.fillWidth: true
                Layout.topMargin: -12
                Layout.bottomMargin: -16
                onToggled: {
                    showFeatureList = checked
                    if (filterActive) {
                        if (checked) {
                            applyFilter(true, false)
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 5; Layout.bottomMargin: 2
                Button {
                    id: applyButton
                    text: tr("Apply filter")
                    enabled: false
                    Layout.fillWidth: true
                    background: Rectangle { color: "#80cc28"; radius: 10 }
                    onClicked: {
                        applyFilter(true, true)
                        searchDialog.close()
                    }
                }
                Button {
                    text: tr("Delete filter")
                    Layout.fillWidth: true
                    background: Rectangle { color: "#333333"; radius: 10 }
                    contentItem: Text {
                        text: tr("Delete filter")
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: {
                        removeAllFilters()
                        searchDialog.close()
                    }
                }
            }
        }
    }
}