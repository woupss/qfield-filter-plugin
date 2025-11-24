import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Theme
import org.qfield
import org.qgis

Item {
    id: plugin
    property var mainWindow: iface.mainWindow()
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
                    valueField.editText = "" // Changed from text to editText
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
                mainWindow.displayToast("Filter deleted")
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
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            Label {
                text: "FILTER"
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
                    if (currentText === "Select a layer") {
                        selectedLayer = null
                        fieldSelector.model = ["Select a field"]
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
                
                // Trigger value fetch when user selects a field
                onActivated: {
                    var selectedName = model[index]
                    updateValues(selectedName)
                    updateApplyState()
                }
                
                // Handle initialization cases
                onCurrentTextChanged: {
                    if (currentText !== "Select a field" && currentText !== "") {
                         updateValues(currentText)
                    }
                    updateApplyState()
                }
            }

            Label { text: "Filter value(s) (separate by ;) :" }
            
            // --- VALUE SELECTOR (ADAPTED) ---
            ComboBox {
                id: valueField
                Layout.fillWidth: true
                editable: true 
                model: []      
                
                // Custom background to match the style if needed, or keep default
                // placeholderText equivalent is tricky in ComboBox, handled via logic mostly
                
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
                text: "Show all geometries (+filtered)"
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
                    text: "Apply filter"
                    enabled: false
                    Layout.fillWidth: true
                    background: Rectangle { color: "#80cc28"; radius: 10 }
                    onClicked: {
                        applyFilter()
                        searchDialog.close()
                    }
                }

                Button {
                    text: "Delete filter"
                    Layout.fillWidth: true
                    background: Rectangle { color: "#333333"; radius: 10 }
                    contentItem: Text {
                        text: "Delete filter"
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
            names.unshift("Select a layer")

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
            fieldSelector.model = ["Select a field"]
            fieldSelector.currentIndex = 0
            return
        }

        var fields = getFields(selectedLayer)

        if (!filterActive)
            fields.unshift("Select a field")

        fieldSelector.model = fields

        if (filterActive && savedFieldName !== "") {
            var idx = fields.indexOf(savedFieldName)
            if (idx >= 0) {
                fieldSelector.currentIndex = idx
                // Pre-load values if we are reloading a saved state
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

    // === THE VALUE FETCHING LOGIC (ADAPTED FROM SOURCE 2) ===
    function updateValues(forceName) {
        // Don't clear model immediately if it's the same field to avoid flicker, 
        // but here we clear to ensure freshness.
        valueField.model = []
        
        var uiName = (forceName !== undefined) ? forceName : fieldSelector.currentText
        
        if (!selectedLayer || uiName === "Select a field" || uiName === "") return

        // 1. Find Logical Index
        var names = selectedLayer.fields.names
        var logicalIndex = -1
        for (var i = 0; i < names.length; i++) {
            if (names[i] === uiName) {
                logicalIndex = i
                break
            }
        }

        if (logicalIndex === -1) {
            // Can happen during switching
            return
        }

        // 2. Physical Index Mapping (Corrects FID/Geometry shifts)
        var realIndex = -1
        var attributes = selectedLayer.attributeList()
        
        if (attributes && logicalIndex < attributes.length) {
            realIndex = attributes[logicalIndex]
        } else {
            realIndex = logicalIndex + 1 // Fallback
        }

        var uniqueValues = {} 
        var valuesArray = []

        try {
            // 3. Iterator with Filter (IS NOT NULL)
            var expression = "\"" + uiName + "\" IS NOT NULL"
            var feature_iterator = LayerUtils.createFeatureIteratorFromExpression(selectedLayer, expression)
            
            var count = 0
            var max_items = 400000 // Limit to prevent freezing on huge layers

            while (feature_iterator.hasNext() && count < max_items) {
                var feature = feature_iterator.next()
                
                // 4. Retrieve by Index (Fastest & safest vs geometry shifts)
                var val = feature.attribute(realIndex)
                
                // Fallback: Retrieve by Name
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
            mainWindow.displayToast("Error fetching values: " + e)
        }
    }

    function updateApplyState() {
        // Check editText because it's an editable ComboBox now
        applyButton.enabled =
            selectedLayer !== null &&
            fieldSelector.currentText &&
            fieldSelector.currentText !== "Select a field" &&
            valueField.editText.length > 0
    }

    function escapeValue(value) {
        return value.trim().replace(/'/g, "''");
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

            // 1. Visibility (Controlled by Checkbox)
            if (showAllFeatures) {
                selectedLayer.subsetString = "" 
            } else {
                selectedLayer.subsetString = expr
            }
            
            // 2. Highlight (Always selects the filtered items)
            selectedLayer.removeSelection()
            selectedLayer.selectByExpression(expr)
            
            // 3. Refresh
            selectedLayer.triggerRepaint()

            filterActive = true

        } catch(e) {
            mainWindow.displayToast("Error: " + e)
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

        updateLayers()
        updateApplyState()
    }
}                    showAllFeatures = false
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
                mainWindow.displayToast("Filter deleted")
            }
        }
    }

    /* ========= DIALOG ========= */
    Dialog {
        id: searchDialog
        parent: mainWindow.contentItem
        modal: true
        width: 350
        height: 340
        x: (mainWindow.width - width)/2
        y: (mainWindow.height - height)/2 - 40
        background: Rectangle { color: "white"; border.color: "#80cc28"; border.width: 3; radius: 8 }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            Label {
                text: "FILTER"
                font.bold: true
                font.pointSize: 18
                color: "black"
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
				Layout.topMargin: -10
				Layout.bottomMargin: 5
            }

            QfComboBox {
                id: layerSelector
                Layout.fillWidth: true
                model: []

                onCurrentTextChanged: {
                    if (currentText === "Select a layer") {
                        selectedLayer = null
                        fieldSelector.model = ["Select a field"]
                        fieldSelector.currentIndex = 0
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
                model: []
                
                // FIX: Listen to TextChanged as well to catch the update immediately
                onCurrentIndexChanged: updateApplyState()
                onCurrentTextChanged: updateApplyState()
            }

            Label { text: "Filter value(s) (separate by ;) :" }
            TextField {
                id: valueField
                Layout.fillWidth: true
                placeholderText: "Ex: 00123;aBc;ABC;AbCd"
                onTextChanged: updateApplyState()
            }

            CheckBox {
                id: showAllCheck
                text: "Show all geometries (+filtered)"
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
                    text: "Apply filter"
                    enabled: false
                    Layout.fillWidth: true
                    background: Rectangle { color: "#80cc28"; radius: 10 }
                    onClicked: {
                        applyFilter()
                        searchDialog.close()
                    }
                }

                Button {
                    text: "Delete filter"
                    Layout.fillWidth: true
                    background: Rectangle { color: "#333333"; radius: 10 }
                    contentItem: Text {
                        text: "Delete filter"
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
            names.unshift("Select a layer")

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

        var fieldNames = []
        for (var i = 0; i < fields.length; i++) {
            var f = fields[i]
            if (f && typeof f.name === "function")
                fieldNames.push(f.name())
        }
        if (fieldNames.length > 0) return fieldNames.sort()

        var ids = layer.attributeList()
        return ids.map(i => "field_" + i)
    }

    function updateFields() {
        if (!selectedLayer) {
            fieldSelector.model = ["Select a field"]
            fieldSelector.currentIndex = 0
            return
        }

        var fields = getFields(selectedLayer)

        if (!filterActive)
            fields.unshift("Select a field")

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
        }
        
        // Ensure state is updated after fields are populated
        updateApplyState()
    }

    function updateApplyState() {
        applyButton.enabled =
            selectedLayer !== null &&
            fieldSelector.currentText &&
            fieldSelector.currentText !== "Select a field" &&
            valueField.text.length > 0
    }

    function escapeValue(value) {
        return value.trim().replace(/'/g, "''");
    }

    function applyFilter() {
        if (!selectedLayer || !fieldSelector.currentText || !valueField.text) return

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

            filterActive = true

        } catch(e) {
            mainWindow.displayToast("Error: " + e)
        }
    }

    function removeAllFilters() {
        if (selectedLayer) {
            selectedLayer.subsetString = ""
            selectedLayer.removeSelection()
            selectedLayer.triggerRepaint()
        }

        valueField.text = ""
        filterActive = false
        showAllFeatures = false
        savedLayerName = ""
        savedFieldName = ""
        savedFilterText = ""
        selectedLayer = null

        updateLayers()
        updateApplyState()
    }
}
