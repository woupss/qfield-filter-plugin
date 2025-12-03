import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Theme
import org.qfield
import org.qgis

Item {
    id: plugin
    property var mainWindow: iface.mainWindow()
    property var mapCanvas: iface.mapCanvas()
    property var selectedLayer: null
    
    // Récupération de l'objet FeatureForm
    property var featureFormItem: iface.findItemByObjectName("featureForm")

    property bool wasLongPress: false
    property bool filterActive: false
    
    // Nouvelle propriété pour suivre l'état du formulaire
    property bool isFormVisible: false
    
    // === PERSISTENCE PROPERTIES ===
    property bool showAllFeatures: false
    property bool showFeatureList: false 
    
    property string savedLayerName: ""
    property string savedFieldName: ""
    property string savedFilterText: ""

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(toolbarButton)
        updateLayers()
        if (featureFormItem) {
            isFormVisible = featureFormItem.visible
        }
    }

    // === GESTION DES EVENEMENTS DU FORMULAIRE ===
    Connections {
        target: featureFormItem
        
        function onVisibleChanged() {
            plugin.isFormVisible = featureFormItem.visible
            
            if (!featureFormItem.visible) {
                showFeatureList = false 
                if (filterActive) {
                    refreshVisualsOnly()
                }
            }
        }
    }

    /* ========= TRANSLATION LOGIC ========= */
    function tr(text) {
        var isFrench = Qt.locale().name.substring(0, 2) === "fr"
        
        var dictionary = {
            "Filter deleted": "Filtre supprimé",
            "FILTER": "FILTRE",
            "Select a layer": "Sélectionner une couche",
            "Select a field": "Sélectionner un champ",
            "Filter value(s) (separate by ;) :": "Valeur(s) du filtre (séparer par ;) :",
            "Show all geometries (+filtered)": "Afficher toutes géométries (+filtrées)",
            "Show feature list": "Afficher liste des entités",
            "Apply filter": "Appliquer le filtre",
            "Delete filter": "Supprimer le filtre",
            "Error fetching values: ": "Erreur récupération valeurs : ",
            "Error Zoom: ": "Erreur Zoom : ",
            "Error: ": "Erreur : ",
            "Searching...": "Recherche...",
            "Type to search (ex: Paris; Lyon)...": "Tapez pour rechercher (ex: Paris; Lyon)...",
            "Active Filter:": "Filtre Actif :" 
        }
        
        if (isFrench && dictionary[text] !== undefined) return dictionary[text]
        return text 
    }

    /* ========= TIMERS ========= */
    Timer {
        id: zoomTimer
        interval: 200
        repeat: false
        onTriggered: performZoom()
    }
    
    Timer {
        id: searchDelayTimer
        interval: 500
        repeat: false
        onTriggered: performDynamicSearch()
    }

    /* ========= BANDEAU D'INFORMATION (STYLE TOAST) ========= */
    Rectangle {
        id: infoBanner
        parent: mainWindow.contentItem 
        z: 9999 
        
        height: 32 
        
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 60 
        
        // Centrage horizontal
        anchors.horizontalCenter: parent.horizontalCenter
        
        // Largeur adaptative
        // On retire 120px (60px de chaque côté) pour garantir que le centrage 
        // ne pousse pas le rectangle dans la marge gauche.
        width: Math.min(bannerLayout.implicitWidth + 30, parent.width - 120)
        
        radius: 16 
        
        color: "#B3333333" 
        
        border.width: 0

        visible: plugin.filterActive && !plugin.isFormVisible

        RowLayout {
            id: bannerLayout
            anchors.fill: parent
            anchors.leftMargin: 15
            anchors.rightMargin: 15
            spacing: 10

            Rectangle {
                width: 8
                height: 8
                radius: 4
                color: "#80cc28"
                Layout.alignment: Qt.AlignVCenter
            }

            Item {
                id: clipContainer
                // Le container essaie de prendre la largeur du texte...
                Layout.preferredWidth: bannerText.contentWidth
                // ...mais accepte de rétrécir si l'écran est trop petit
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true 

                Text {
                    id: bannerText
                    
                    text: {
                        var val = plugin.savedFilterText.trim()
                        if (val.endsWith(";")) {
                            val = val.substring(0, val.length - 1).trim()
                        }
                        return plugin.savedLayerName + " | " + plugin.savedFieldName + " : " + val
                    }
                    
                    color: "white" 
                    font.bold: true
                    font.pixelSize: 13 
                    
                    // CORRECTION ICI : Alignement et Wrapping
                    // On force le texte à rester sur une seule ligne pour que le calcul de largeur soit juste.
                    wrapMode: Text.NoWrap 
                    
                    // On force l'alignement à gauche pour voir le début du texte immédiatement.
                    horizontalAlignment: Text.AlignLeft
                    verticalAlignment: Text.AlignVCenter
                    
                    // On centre verticalement dans le container
                    anchors.verticalCenter: parent.verticalCenter
                    
                    // On s'assure que le texte commence bien à gauche (x=0) par défaut
                    x: 0
                    
                    SequentialAnimation on x {
                        // L'animation ne se lance que si le texte est PLUS GRAND que le container visible
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

    /* ========= TOOLBAR BUTTON ========= */
    QfToolButton {
        id: toolbarButton
        iconSource: "icon.svg"
        iconColor: Theme.mainColor
        bgcolor: Theme.darkGray
        round: true

        onClicked: {
            if (!plugin.wasLongPress) {
                if (!filterActive) {
                    showAllFeatures = false
                    savedLayerName = ""
                    savedFieldName = ""
                    savedFilterText = ""
                    valueField.text = "" 
                    selectedLayer = null
                } else {
                    valueField.text = savedFilterText
                }
                updateLayers()
                searchDialog.open()
            }
            plugin.wasLongPress = false
        }

        onPressed: holdTimer.start()
        onReleased: holdTimer.stop()

        Timer {
            id: holdTimer
            interval: 500
            repeat: false
            onTriggered: {
                plugin.wasLongPress = true
                removeAllFilters()
                mainWindow.displayToast(tr("Filter deleted"))
            }
        }
    }

    /* ========= DIALOG ========= */
    Dialog {
        id: searchDialog
        parent: mainWindow.contentItem
        modal: true
        width: Math.min(450, mainWindow.width * 0.90)
        height: mainCol.implicitHeight + 30
        
        x: (parent.width - width) / 2
        
        y: {
            var centerPos = (parent.height - height) / 2
            var isPortrait = parent.height > parent.width
            var offset = isPortrait ? (parent.height * 0.10) : 0
            return centerPos - offset
        }

        background: Rectangle {
            color: "white"
            border.color: "#80cc28"
            border.width: 3
            radius: 8
        }

        MouseArea {
            anchors.fill: parent
            z: -1
            propagateComposedEvents: true
            onClicked: {
                if (valueField.focus) {
                    valueField.focus = false;
                    suggestionPopup.close()
                }
                mouse.accepted = false;
            }
        }

        ColumnLayout {
            id: mainCol
            anchors.fill: parent
            anchors.margins: 8
            spacing: 12

            Label {
                text: tr("FILTER")
                font.bold: true
                font.pointSize: 18
                color: "black"
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
                Layout.topMargin: -10
                Layout.bottomMargin: 2
            }

            QfComboBox {
                id: layerSelector
                Layout.fillWidth: true
                Layout.preferredHeight: 35
                Layout.topMargin: -10
                topPadding: 2; bottomPadding: 2
                model: []
                onCurrentTextChanged: {
                    if (currentText === tr("Select a layer")) {
                        selectedLayer = null
                        fieldSelector.model = [tr("Select a field")]
                        fieldSelector.currentIndex = 0
                        valueField.model = []
                        updateApplyState()
                        return
                    }
                    selectedLayer = getLayerByName(currentText)
                    updateFields()
                    updateApplyState()
                }
            }

            QfComboBox {
                id: fieldSelector
                Layout.fillWidth: true
                Layout.preferredHeight: 35
                topPadding: 2; bottomPadding: 2
                model: []
                onActivated: {
                    valueField.text = ""
                    valueField.model = []
                    updateApplyState()
                }
                onCurrentTextChanged: {
                    updateApplyState()
                }
            }

            Label {
                text: tr("Filter value(s) (separate by ;) :")
                Layout.topMargin: -8
                Layout.bottomMargin: -10
            }

            TextField {
                id: valueField
                Layout.fillWidth: true
                Layout.preferredHeight: 35
                topPadding: 6
                bottomPadding: 6
                placeholderText: tr("Type to search (ex: Paris; Lyon)...")
                Layout.bottomMargin: 2

                property var model: []
                property bool isLoading: false

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

                    if (lastPart.length > 0) {
                        searchDelayTimer.restart()
                    } else {
                        searchDelayTimer.stop()
                        suggestionPopup.close()
                        model = []
                    }
                    updateApplyState()
                }
                
                onTextChanged: updateApplyState()

                onAccepted: {
                    suggestionPopup.close()
                    updateApplyState()
                }
                
                BusyIndicator {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 5
                    height: parent.height * 0.6
                    width: height
                    running: valueField.isLoading
                    visible: valueField.isLoading
                }
                
                Popup {
                    id: suggestionPopup
                    y: valueField.height
                    width: valueField.width
                    height: Math.min(listView.contentHeight + 10, 200)
                    padding: 1
                    
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                    
                    background: Rectangle {
                        color: "white"
                        border.color: "#bdbdbd"
                        radius: 2
                    }

                    ListView {
                        id: listView
                        anchors.fill: parent
                        clip: true
                        model: valueField.model
                        
                        delegate: ItemDelegate {
                            text: modelData
                            width: listView.width
                            background: Rectangle {
                                color: parent.highlighted ? "#e0e0e0" : "transparent"
                            }
                            onClicked: {
                                var currentText = valueField.text
                                var lastSep = currentText.lastIndexOf(";")
                                
                                var newText = ""
                                if (lastSep === -1) {
                                    newText = modelData + " ; "
                                } else {
                                    var prefix = currentText.substring(0, lastSep + 1)
                                    newText = prefix + " " + modelData + " ; "
                                }
                                
                                valueField.text = newText
                                suggestionPopup.close()
                                valueField.forceActiveFocus()
                                valueField.model = []
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
                    // Modification : applyFilter(true, false) -> false pour ne pas ZOOMER
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
                            // Modification : applyFilter(true, false) -> false pour ne pas ZOOMER
                            applyFilter(true, false)
                        } else {
                            if (featureFormItem) {
                                featureFormItem.visible = false
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 5
                Layout.bottomMargin: 2
                Button {
                    id: applyButton
                    text: tr("Apply filter")
                    enabled: false
                    Layout.fillWidth: true
                    background: Rectangle { color: "#80cc28"; radius: 10 }
                    onClicked: {
                        // Modification : applyFilter(true, true) -> true pour OUI ZOOMER
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

    /* ========= LOGIC ========= */

    function updateLayers() {
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers)
            if (layers[id] && layers[id].type === 0)
                names.push(layers[id].name)
        names.sort()
        if (!filterActive) names.unshift(tr("Select a layer"))
        layerSelector.model = names
        if (filterActive && savedLayerName !== "") {
            var idx = names.indexOf(savedLayerName)
            if (idx >= 0) layerSelector.currentIndex = idx
            else layerSelector.currentIndex = 0
        } else {
            layerSelector.currentIndex = 0
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
        if (fields.names) return fields.names.slice().sort()
        return []
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
            if (idx >= 0) {
                fieldSelector.currentIndex = idx
            } else {
                fieldSelector.currentIndex = 0
            }
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
                                alreadyInText = true; 
                                break;
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
        applyButton.enabled = selectedLayer !== null && fieldSelector.currentText && fieldSelector.currentText !== tr("Select a field") && valueField.text.length > 0
    }

    function escapeValue(value) {
        return value.trim().replace(/'/g, "''");
    }

    function performZoom() {
        if (!selectedLayer) return;
        var bbox = selectedLayer.boundingBoxOfSelected();
        if (bbox === undefined || bbox === null) return;
        try { if (bbox.width < 0) return; } catch(e) { return; }

        try {
            var reprojectedExtent = GeometryUtils.reprojectRectangle(
                bbox,
                selectedLayer.crs,
                mapCanvas.mapSettings.destinationCrs
            )
            var cx = reprojectedExtent.xMinimum + (reprojectedExtent.width / 2.1);
            var cy = reprojectedExtent.yMinimum + (reprojectedExtent.height / 2.1);
            var isPoint = (reprojectedExtent.width < 0.00001 && reprojectedExtent.height < 0.00001);

            if (isPoint) {
                var buffer = (Math.abs(cx) > 180) ? 50.0 : 0.001;
                reprojectedExtent.xMinimum = cx - buffer;
                reprojectedExtent.xMaximum = cx + buffer;
                reprojectedExtent.yMinimum = cy - buffer;
                reprojectedExtent.yMaximum = cy + buffer;
            } else {
                var w = reprojectedExtent.width;
                var h = reprojectedExtent.height;
                var newW = w * 1.3; 
                var newH = h * 1.3;
                reprojectedExtent.xMinimum = cx - (newW / 2.1);
                reprojectedExtent.xMaximum = cx + (newW / 2.1);
                reprojectedExtent.yMinimum = cy - (newH / 2.1);
                reprojectedExtent.yMaximum = cy + (newH / 2.1);
            }
            mapCanvas.mapSettings.setExtent(reprojectedExtent, true);
            mapCanvas.refresh();
        } catch(e) {
            mainWindow.displayToast(tr("Error Zoom: ") + e)
        }
    }

    function refreshVisualsOnly() {
        if (selectedLayer) {
             mapCanvas.mapSettings.selectionColor = "#ff0000"
             selectedLayer.triggerRepaint()
             mapCanvas.refresh()
             zoomTimer.start()
        }
    }

    // Modification : ajout du paramètre doZoom
    function applyFilter(allowFormOpen, doZoom) {
        if (!selectedLayer || !fieldSelector.currentText || !valueField.text) return
        if (allowFormOpen === undefined) allowFormOpen = true
        // Par défaut, si non précisé, on zoome (pour compatibilité)
        if (doZoom === undefined) doZoom = true

        try {
            savedLayerName = layerSelector.currentText
            savedFieldName = fieldSelector.currentText
            savedFilterText = valueField.text

            var fieldName = savedFieldName
            var values = savedFilterText
                .split(";")
                .map(v => escapeValue(v.toLowerCase()))
                .filter(v => v.length > 0)

            if (values.length === 0) return

            var expr = values.map(v => 'lower("' + fieldName + '") LIKE \'%' + v + '%\'').join(" OR ")
            
            if (showAllFeatures) selectedLayer.subsetString = "" 
            else selectedLayer.subsetString = expr
            
            selectedLayer.removeSelection()
            mapCanvas.mapSettings.selectionColor = "#ff0000"
            selectedLayer.selectByExpression(expr)

            selectedLayer.triggerRepaint()
            mapCanvas.refresh()

            if (showListCheck.checked && allowFormOpen) {
                if (featureFormItem) {
                    featureFormItem.model.setFeatures(selectedLayer, expr);
                    featureFormItem.show();
                }
            } 
            
            // On ne zoome que si doZoom est vrai
            if (doZoom) {
                zoomTimer.start()
            }
            filterActive = true

        } catch(e) {
            mainWindow.displayToast(tr("Error: ") + e)
        }
    }

    function removeAllFilters() {
        if (selectedLayer) {
            selectedLayer.subsetString = ""
            selectedLayer.removeSelection()
            selectedLayer.triggerRepaint()
        }
        valueField.text = ""
        valueField.model = []
        filterActive = false
        showAllFeatures = false
        savedLayerName = ""
        savedFieldName = ""
        savedFilterText = ""
        selectedLayer = null
        
        mapCanvas.refresh()
        updateLayers()
        updateApplyState()
    }
}
