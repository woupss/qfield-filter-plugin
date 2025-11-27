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
    property bool wasLongPress: false
    property bool filterActive: false
    
    // === PERSISTENCE PROPERTIES ===
    property bool showAllFeatures: false
    property string savedLayerName: ""
    property string savedFieldName: ""
    property string savedFilterText: ""

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(toolbarButton)
        updateLayers()
    }

    /* ========= TRANSLATION LOGIC (INTERNAL) ========= */
    function tr(text) {
        // Detect if the locale is French (starts with "fr")
        var isFrench = Qt.locale().name.substring(0, 2) === "fr"
        
        var dictionary = {
            "Filter deleted": "Filtre supprimé",
            "FILTER": "FILTRE",
            "Select a layer": "Sélectionner une couche",
            "Select a field": "Sélectionner un champ",
            "Filter value(s) (separate by ;) :": "Valeur(s) du filtre (séparer par ;) :",
            "Show all geometries (+filtered)": "Afficher toutes géométries (+filtrées)",
            "Apply filter": "Appliquer le filtre",
            "Delete filter": "Supprimer le filtre",
            "Error fetching values: ": "Erreur récupération valeurs : ",
            "Error Zoom: ": "Erreur Zoom : ",
            "Error: ": "Erreur : "
        }

        if (isFrench && dictionary[text] !== undefined) {
            return dictionary[text]
        }
        return text // Return original English text if not French
    }

    /* ========= ZOOM TIMER ========= */
    Timer {
        id: zoomTimer
        interval: 200
        repeat: false
        onTriggered: {
            performZoom()
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
                    valueField.editText = "" 
                    selectedLayer = null
                } else {
                    valueField.editText = savedFilterText
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
        width: 350
        height: mainCol.implicitHeight + 30
        x: (mainWindow.width - width)/2
        y: (mainWindow.height - height)/2 - 40
        background: Rectangle { color: "white"; border.color: "#80cc28"; border.width: 3; radius: 8 }

        ColumnLayout {
            id: mainCol
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            Label {
                text: tr("FILTER")
                font.bold: true
                font.pointSize: 18
                color: "black"
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
                Layout.topMargin: -10
                Layout.bottomMargin: 5
            }

            // --- LAYER SELECTOR ---
            QfComboBox {
                id: layerSelector
                Layout.fillWidth: true
                model: []

                onCurrentTextChanged: {
                    // We compare against the translated version
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

            // --- FIELD SELECTOR ---
            QfComboBox {
                id: fieldSelector
                Layout.fillWidth: true
                model: []
                
                onActivated: {
                    var selectedName = model[index]
                    updateValues(selectedName)
                    updateApplyState()
                }
                
                onCurrentTextChanged: {
                    if (currentText !== tr("Select a field") && currentText !== "") {
                         updateValues(currentText)
                    }
                    updateApplyState()
                }
            }

            Label { text: tr("Filter value(s) (separate by ;) :") }
            
            // --- VALUE SELECTOR ---
            ComboBox {
                id: valueField
                Layout.fillWidth: true
                editable: true 
                model: []      
                
                onEditTextChanged: updateApplyState()
                onAccepted: updateApplyState()
                
                delegate: ItemDelegate {
                    text: modelData
                    width: valueField.width
                    highlighted: valueField.highlightedIndex === index
                }
            }

            CheckBox {
                id: showAllCheck
                text: tr("Show all geometries (+filtered)")
                checked: showAllFeatures
                Layout.fillWidth: true
                
                onToggled: {
                    showAllFeatures = checked
                    if (filterActive) {
                        applyFilter()
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Button {
                    id: applyButton
                    text: tr("Apply filter")
                    enabled: false
                    Layout.fillWidth: true
                    background: Rectangle { color: "#80cc28"; radius: 10 }
                    onClicked: {
                        applyFilter()
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

        if (!filterActive)
            names.unshift(tr("Select a layer"))

        layerSelector.model = names

        if (filterActive && savedLayerName !== "") {
            var idx = names.indexOf(savedLayerName)
            if (idx >= 0) {
                layerSelector.currentIndex = idx
            } else {
                layerSelector.currentIndex = 0
            }
        } else {
            layerSelector.currentIndex = 0
        }
    }

    function getLayerByName(name) {
        var layers = ProjectUtils.mapLayers(qgisProject)
        for (var id in layers)
            if (layers[id].name === name)
                return layers[id]
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

        if (!filterActive)
            fields.unshift(tr("Select a field"))

        fieldSelector.model = fields

        if (filterActive && savedFieldName !== "") {
            var idx = fields.indexOf(savedFieldName)
            if (idx >= 0) {
                fieldSelector.currentIndex = idx
                updateValues(savedFieldName)
            } else {
                fieldSelector.currentIndex = 0
            }
        } else {
            fieldSelector.currentIndex = 0
            valueField.model = []
        }
        
        updateApplyState()
    }

    function updateValues(forceName) {
        valueField.model = []
        
        var uiName = (forceName !== undefined) ? forceName : fieldSelector.currentText
        
        // Check against translated string
        if (!selectedLayer || uiName === tr("Select a field") || uiName === "") return

        var names = selectedLayer.fields.names
        var logicalIndex = -1
        for (var i = 0; i < names.length; i++) {
            if (names[i] === uiName) {
                logicalIndex = i
                break
            }
        }

        if (logicalIndex === -1) return

        var realIndex = -1
        var attributes = selectedLayer.attributeList()
        
        if (attributes && logicalIndex < attributes.length) {
            realIndex = attributes[logicalIndex]
        } else {
            realIndex = logicalIndex + 1 
        }

        var uniqueValues = {} 
        var valuesArray = []

        try {
            var expression = "\"" + uiName + "\" IS NOT NULL"
            var feature_iterator = LayerUtils.createFeatureIteratorFromExpression(selectedLayer, expression)
            
            var count = 0
            var max_items = 10000 

            while (feature_iterator.hasNext() && count < max_items) {
                var feature = feature_iterator.next()
                
                var val = feature.attribute(realIndex)
                
                if (val === undefined) {
                    val = feature.attribute(uiName)
                }

                if (val !== null && val !== undefined) {
                    var strVal = String(val).trim()
                    if (strVal !== "" && strVal !== "NULL") {
                        if (!uniqueValues[strVal]) {
                            uniqueValues[strVal] = true
                            valuesArray.push(strVal)
                        }
                    }
                }
                count++
            }
            feature_iterator.close()
            
            valuesArray.sort()
            valueField.model = valuesArray

        } catch (e) {
            mainWindow.displayToast(tr("Error fetching values: ") + e)
        }
    }

    function updateApplyState() {
        applyButton.enabled =
            selectedLayer !== null &&
            fieldSelector.currentText &&
            fieldSelector.currentText !== tr("Select a field") &&
            valueField.editText.length > 0
    }

    function escapeValue(value) {
        return value.trim().replace(/'/g, "''");
    }

    // === ZOOM FUNCTION (MANUAL CALCULATION) ===
    function performZoom() {
        if (!selectedLayer) return;

        // 1. Get Bounding Box
        var bbox = selectedLayer.boundingBoxOfSelected();
        
        if (bbox === undefined || bbox === null) return;
        try { if (bbox.width < 0) return; } catch(e) { return; }

        try {
            // 2. Reproject
            var reprojectedExtent = GeometryUtils.reprojectRectangle(
                bbox,
                selectedLayer.crs,
                mapCanvas.mapSettings.destinationCrs
            )

            // 3. Manual Center Calculation (No .center() function available)
            var cx = reprojectedExtent.xMinimum + (reprojectedExtent.width / 2.1);
            var cy = reprojectedExtent.yMinimum + (reprojectedExtent.height / 2.1);

            // 4. Point vs Extent Logic
            var isPoint = (reprojectedExtent.width < 0.00001 && reprojectedExtent.height < 0.00001);

            // Use direct property assignment (=) instead of set methods
            if (isPoint) {
                // Point: Create buffer (50m if meters, 0.001 if degrees)
                var buffer = (Math.abs(cx) > 180) ? 50.0 : 0.001;

                reprojectedExtent.xMinimum = cx - buffer;
                reprojectedExtent.xMaximum = cx + buffer;
                reprojectedExtent.yMinimum = cy - buffer;
                reprojectedExtent.yMaximum = cy + buffer;

            } else {
                // Extent: Add 50% padding
                var w = reprojectedExtent.width;
                var h = reprojectedExtent.height;
                var newW = w * 1.3; 
                var newH = h * 1.3;
                
                reprojectedExtent.xMinimum = cx - (newW / 2.1);
                reprojectedExtent.xMaximum = cx + (newW / 2.1);
                reprojectedExtent.yMinimum = cy - (newH / 2.1);
                reprojectedExtent.yMaximum = cy + (newH / 2.1);
            }
            
            // 5. Apply
            mapCanvas.mapSettings.setExtent(reprojectedExtent, true);
            mapCanvas.refresh();

        } catch(e) {
            mainWindow.displayToast(tr("Error Zoom: ") + e)
        }
    }

    function applyFilter() {
        if (!selectedLayer || !fieldSelector.currentText || !valueField.editText) return

        try {
            savedLayerName = layerSelector.currentText
            savedFieldName = fieldSelector.currentText
            savedFilterText = valueField.editText

            var fieldName = savedFieldName
            var values = savedFilterText
                .split(";")
                .map(v => escapeValue(v.toLowerCase()))
                .filter(v => v.length > 0)

            if (values.length === 0) return

            var expr = values.map(v => 'lower("' + fieldName + '") LIKE \'%' + v + '%\'').join(" OR ")

            // 1. Visibility
            if (showAllFeatures) {
                selectedLayer.subsetString = "" 
            } else {
                selectedLayer.subsetString = expr
            }
            
            // 2. Highlight
            selectedLayer.removeSelection()
            selectedLayer.selectByExpression(expr)
            
            // 3. Refresh
            selectedLayer.triggerRepaint()
            
            // 4. Start Zoom Timer
            zoomTimer.start()

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

        valueField.editText = ""
        valueField.model = []
        filterActive = false
        showAllFeatures = false
        savedLayerName = ""
        savedFieldName = ""
        savedFilterText = ""
        selectedLayer = null
        
        mapCanvas.refresh() // Added refresh here too for safety

        updateLayers()
        updateApplyState()
    }
}
