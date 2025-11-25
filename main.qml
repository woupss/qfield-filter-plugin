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
