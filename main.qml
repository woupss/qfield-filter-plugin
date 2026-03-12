import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Theme
import org.qfield
import org.qgis
import "qrc:/qml" as QFieldItems
import "."

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

    // Palette — une couleur par valeur de filtre
    property var colorPalette: [
        "#FF4444",   // valeur 1 — rouge
        "#4488FF",   // valeur 2 — bleu
        "#00FF39",   // valeur 3 — vert fluo
        "#AA00FF",   // valeur 4 — violet
        "#40767F",   // valeur 5 — cyan fonce
        "#FF44AA"    // valeur 6 — rose
    ]
    property int maxFilterValues: 6

    // [{x, y, colorIdx}] — centroïdes WGS84 avec leur index couleur
    property var centroidPoints: []

    // [{x, y, colorIdx, count}] — centroïdes regroupés en clusters
    property var clusteredPoints: []
    property real clusterRadius: 47   // distance en pixels pour regrouper

    // Variables internes
    property var pendingFormLayer: null
    property string pendingFormExpr: ""
    property var internalListView: null
    property bool wasListVisible: true

    // 1. INSTANCIATION DES PLUGINS ENFANTS
    // -----------------------------------------------------------
    
    DriveMe {
        id: drivemeTool
    }


    // === INITIALISATION ===
    Component.onCompleted: {
        iface.addItemToPluginsToolbar(toolbarButton)
        updateLayers()
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
        if (!selectedLayer) { sourceIsPoints = false; return }
        var gType = -1
        try {
            if (typeof selectedLayer.geometryType === 'number') gType = selectedLayer.geometryType
            else if (typeof selectedLayer.geometryType === 'function') gType = selectedLayer.geometryType()
        } catch (e) { console.log("Erreur geom: " + e) }
        sourceIsPoints = (gType === 0)
    }

    // === CALCUL CENTROÏDES + CONTOURS PAR VALEUR DE FILTRE ===
    function computeCentroids() {
        if (sourceIsPoints) { clearCentroids(); return }
        if (!selectedLayer || !savedFieldName || !savedFilterText) return

        var fieldName = savedFieldName
        var values = savedFilterText
            .split(";")
            .map(function(v) { return escapeValue(v.toLowerCase().trim()) })
            .filter(function(v) { return v.length > 0 })

        var empty = GeometryUtils.createGeometryFromWkt("LINESTRING(0 0, 0.000001 0.000001)")
        var newCentroidPoints = []

        for (var vi = 0; vi < maxFilterValues; vi++) {
            var oRend = outlineRenderers.itemAt(vi)

            // Index hors plage → vider le renderer contour
            if (vi >= values.length) {
                if (oRend && empty) oRend.geometryWrapper.qgsGeometry = empty
                continue
            }

            var singleExpr = 'lower("' + fieldName + '") LIKE \'%' + values[vi] + '%\''
            var verticesDict = ({})
            var featIdx = 0

            try {
                var it = LayerUtils.createFeatureIteratorFromExpression(selectedLayer, singleExpr)
                while (it.hasNext()) {
                    var feat = it.next()
                    var geom = feat.geometry
                    if (!geom) continue

                    // Point garanti dans la géométrie (ray casting JS)
                    var centPt = pointInsideGeom(geom)
                    if (centPt) {
                        var wgs = GeometryUtils.reprojectPointToWgs84(centPt, selectedLayer.crs)
                        if (wgs) newCentroidPoints.push({ x: wgs.x, y: wgs.y, colorIdx: vi })
                    }

                    // Contour → sommets WGS84
                    var verts = extractWgs84Vertices(geom, selectedLayer.crs)
                    if (verts && verts.length >= 3) verticesDict[featIdx] = verts
                    featIdx++
                }
            } catch(e) {
                console.log("computeCentroids[" + vi + "]: " + e)
            }

            // Assigner contours au renderer de cet index
            if (oRend) buildAndAssignOutline(verticesDict, oRend)
        }

        centroidPoints = newCentroidPoints
        buildClusters()
        if (mapCanvas) mapCanvas.refresh()
    }

    function clearCentroids() {
        centroidPoints = []
        clusteredPoints = []
        var empty = GeometryUtils.createGeometryFromWkt("LINESTRING(0 0, 0.000001 0.000001)")
        if (!empty) return
        for (var i = 0; i < maxFilterValues; i++) {
            var or = outlineRenderers.itemAt(i)
            if (or) or.geometryWrapper.qgsGeometry = empty
        }
    }

    function buildClusters() {
        if (!centroidPoints || centroidPoints.length === 0) { clusteredPoints = []; return }

        // Convertit le rayon pixels en degrés WGS84 via l'étendue courante
        var ext = mapCanvas.mapSettings.extent
        var destCrs = mapCanvas.mapSettings.destinationCrs
        var wgs84Ext = null
        try {
            wgs84Ext = GeometryUtils.reprojectRectangle(
                ext, destCrs, CoordinateReferenceSystemUtils.wgs84Crs())
        } catch(e) {}

        if (!wgs84Ext || mapCanvas.width === 0 || mapCanvas.height === 0) {
            clusteredPoints = centroidPoints.slice(); return
        }

        var threshX = clusterRadius * (wgs84Ext.xMaximum - wgs84Ext.xMinimum) / mapCanvas.width
        var threshY = clusterRadius * (wgs84Ext.yMaximum - wgs84Ext.yMinimum) / mapCanvas.height

        // Algorithme glouton : chaque point non assigné devient centre d'un cluster
        var assigned = []
        for (var k = 0; k < centroidPoints.length; k++) assigned.push(false)

        var result = []
        for (var i = 0; i < centroidPoints.length; i++) {
            if (assigned[i]) continue
            var p = centroidPoints[i]
            var sumX = p.x; var sumY = p.y; var clusterCount = 1
            assigned[i] = true

            for (var j = i + 1; j < centroidPoints.length; j++) {
                if (assigned[j]) continue
                var q = centroidPoints[j]
                if (Math.abs(p.x - q.x) < threshX && Math.abs(p.y - q.y) < threshY) {
                    sumX += q.x; sumY += q.y; clusterCount++
                    assigned[j] = true
                }
            }

            result.push({
                x: sumX / clusterCount,
                y: sumY / clusterCount,
                colorIdx: p.colorIdx,
                clusterCount: clusterCount
            })
        }
        clusteredPoints = result
    }

    // === POINT GARANTI DANS LA GÉOMÉTRIE ===
    // Ray casting : renvoie true si (px, py) est dans le polygone défini par coords[]
    function _pointInPolygon(px, py, coords) {
        var inside = false
        var n = coords.length
        for (var i = 0, j = n - 1; i < n; j = i++) {
            var xi = coords[i][0], yi = coords[i][1]
            var xj = coords[j][0], yj = coords[j][1]
            if (((yi > py) !== (yj > py)) &&
                (px < (xj - xi) * (py - yi) / (yj - yi) + xi))
                inside = !inside
        }
        return inside
    }

    // Extrait les coordonnées brutes (dans le CRS natif) du premier anneau
    function _extractRawCoords(geom) {
        var coords = []
        try {
            var wkt = geom.asWkt()
            if (!wkt) return coords
            var start = wkt.indexOf("((")
            if (start === -1) start = wkt.indexOf("(")
            if (start === -1) return coords
            start = wkt.indexOf("(", start) + 1
            var end = wkt.indexOf(")", start)
            if (end === -1) return coords
            var pairs = wkt.substring(start, end).split(",")
            for (var i = 0; i < pairs.length; i++) {
                var xy = pairs[i].trim().split(" ")
                if (xy.length < 2) continue
                var x = parseFloat(xy[0]), y = parseFloat(xy[1])
                if (!isNaN(x) && !isNaN(y)) coords.push([x, y])
            }
        } catch(e) {}
        return coords
    }

    // Renvoie un QgsPoint garanti à l'intérieur de la géométrie :
    // 1. Centroïde des sommets (rapide)
    // 2. Si hors polygone → teste les milieux de chaque arête
    // 3. Fallback → GeometryUtils.centroid (peut être hors géométrie mais ne plante pas)
    function pointInsideGeom(geom) {
        try {
            var coords = _extractRawCoords(geom)
            if (coords.length < 3) return GeometryUtils.centroid(geom)

            // Étape 1 : centroïde des sommets
            var sumX = 0, sumY = 0
            for (var k = 0; k < coords.length; k++) { sumX += coords[k][0]; sumY += coords[k][1] }
            var cx = sumX / coords.length
            var cy = sumY / coords.length

            if (_pointInPolygon(cx, cy, coords)) {
                // Construire un QgsPoint depuis le WKT
                var ptGeom = GeometryUtils.createGeometryFromWkt(
                    "POINT(" + cx + " " + cy + ")")
                if (ptGeom) return GeometryUtils.centroid(ptGeom)
            }

            // Étape 2 : milieux des arêtes — poussés vers l'intérieur (10% vers le centroïde)
            var n = coords.length
            for (var i = 0; i < n - 1; i++) {
                var mx = (coords[i][0] + coords[i+1][0]) / 2
                var my = (coords[i][1] + coords[i+1][1]) / 2
                if (_pointInPolygon(mx, my, coords)) {
                    // Décalage de 10% vers le centroïde pour sortir du contour
                    var px2 = mx + (cx - mx) * 0.40
                    var py2 = my + (cy - my) * 0.40
                    var mGeom = GeometryUtils.createGeometryFromWkt(
                        "POINT(" + px2 + " " + py2 + ")")
                    if (mGeom) return GeometryUtils.centroid(mGeom)
                }
            }
        } catch(e) {}

        // Étape 3 : fallback QGIS
        return GeometryUtils.centroid(geom)
    }

    // === FONCTIONS CONTOURS ===
    function extractWgs84Vertices(geom, layerCrs) {
        var verts = []
        try {
            var wkt = geom.asWkt()
            if (!wkt) return verts
            var start = wkt.indexOf("((")
            if (start === -1) start = wkt.indexOf("(")
            if (start === -1) return verts
            start = wkt.indexOf("(", start) + 1
            var end = wkt.indexOf(")", start)
            if (end === -1) return verts
            var pairs = wkt.substring(start, end).split(",")
            for (var i = 0; i < pairs.length; i++) {
                var xy = pairs[i].trim().split(" ")
                if (xy.length < 2) continue
                var x = parseFloat(xy[0]), y = parseFloat(xy[1])
                if (isNaN(x) || isNaN(y)) continue
                var vWkt = "POINT(" + x + " " + y + ")"
                var vGeom = GeometryUtils.createGeometryFromWkt(vWkt)
                if (!vGeom) continue
                var vPt = GeometryUtils.centroid(vGeom)
                if (!vPt) continue
                var wgs = GeometryUtils.reprojectPointToWgs84(vPt, layerCrs)
                if (wgs) verts.push({ x: wgs.x, y: wgs.y })
            }
        } catch(e) { console.log("extractWgs84Vertices: " + e) }
        return verts
    }

    function buildAndAssignOutline(verticesDict, renderer) {
        var empty = GeometryUtils.createGeometryFromWkt("LINESTRING(0 0, 0.000001 0.000001)")
        var polygons = []
        for (var fid in verticesDict) {
            var verts = verticesDict[fid]
            if (!verts || verts.length < 3) continue
            var ring = verts.map(function(v) { return v.x.toFixed(6) + " " + v.y.toFixed(6) })
            var first = verts[0], last = verts[verts.length - 1]
            if (first.x !== last.x || first.y !== last.y)
                ring.push(first.x.toFixed(6) + " " + first.y.toFixed(6))
            polygons.push("((" + ring.join(",") + "))")
        }
        if (polygons.length === 0) {
            if (empty) renderer.geometryWrapper.qgsGeometry = empty
            return
        }
        var wkt = polygons.length === 1
            ? "POLYGON" + polygons[0]
            : "MULTIPOLYGON(" + polygons.join(",") + ")"
        var geom = GeometryUtils.createGeometryFromWkt(wkt)
        if (geom) renderer.geometryWrapper.qgsGeometry = geom
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
        id: computeCentroidsTimer
        interval: 400
        repeat: false
        onTriggered: {
            if (!sourceIsPoints) computeCentroids()
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
        if (!sourceIsPoints) clearCentroids()
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
        if (drivemeTool.isNavigating) drivemeTool.stopNavigation()
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
            bbox.xMinimum -= epsilon; bbox.xMaximum += epsilon
            bbox.yMinimum -= epsilon; bbox.yMaximum += epsilon
        }

        try {
            var destCrs = mapCanvas.mapSettings.destinationCrs
            var finalExtent = GeometryUtils.reprojectRectangle(bbox, selectedLayer.crs, destCrs)
            if (!finalExtent) return

            var cx = (finalExtent.xMinimum + finalExtent.xMaximum) / 2.0
            var cy = (finalExtent.yMinimum + finalExtent.yMaximum) / 2.0
            var minSize = (Math.abs(cx) > 180) ? 200.0 : 0.002

            if (finalExtent.width < minSize) {
                finalExtent.xMinimum = cx - (minSize / 2.0)
                finalExtent.xMaximum = cx + (minSize / 2.0)
            }
            if (finalExtent.height < minSize) {
                finalExtent.yMinimum = cy - (minSize / 2.0)
                finalExtent.yMaximum = cy + (minSize / 2.0)
            }

            var currentMapExtent = mapCanvas.mapSettings.extent
            var screenRatio = currentMapExtent.width / currentMapExtent.height
            var h = (finalExtent.height === 0) ? 0.001 : finalExtent.height
            var geomRatio = finalExtent.width / h
            var marginScale = 1.05
            var nw = 0, nh = 0

            if (geomRatio > screenRatio) {
                nw = finalExtent.width * marginScale
                nh = nw / screenRatio
            } else {
                nh = finalExtent.height * marginScale
                nw = nh * screenRatio
            }

            if (isReturnAction) { nw = nw * 0.65; nh = nh * 0.65; isReturnAction = false }
            if (showFeatureList && useListOffset) cy = cy - (nh * 0.25)

            finalExtent.xMinimum = cx - (nw / 2.0); finalExtent.xMaximum = cx + (nw / 2.0)
            finalExtent.yMinimum = cy - (nh / 2.0); finalExtent.yMaximum = cy + (nh / 2.0)

            mapCanvas.mapSettings.setExtent(finalExtent, true)
            mapCanvas.refresh()
            applyCustomColors()

            if (sourceIsPoints) {
                selectedLayer.removeSelection()
                selectedLayer.triggerRepaint()
                mapCanvas.refresh()
            }
        } catch (e) { console.error("Erreur Zoom: " + e) }
    }

    function applyFilter(allowFormOpen, doZoom) {
        if (!selectedLayer || !fieldSelector.currentText || !valueField.text) return
        if (allowFormOpen === undefined) allowFormOpen = true
        if (doZoom === undefined) doZoom = true

        try {
            savedLayerName = layerSelector.currentText
            savedFieldName = fieldSelector.currentText
            savedFilterText = valueField.text

            if (!sourceIsPoints) clearCentroids()

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

            if (!sourceIsPoints) computeCentroidsTimer.restart()
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
        var isReady = selectedLayer !== null && fieldSelector.currentText && fieldSelector.currentText !== tr("Select a field") && valueField.text.length > 0
        applyButton.enabled = isReady
        if (filterAndDriveButton) filterAndDriveButton.enabled = isReady
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
            "Filter & Drive me": "Appliquer le filtre & Guide moi",
            "Delete filter": "Supprimer le filtre"

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

    // === RENDERERS CONTOURS — un par valeur de filtre ===
    Repeater {
        id: outlineRenderers
        model: filterToolRoot.maxFilterValues
        QFieldItems.GeometryRenderer {
            parent: mapCanvas
            mapSettings: mapCanvas.mapSettings
            geometryWrapper.crs: CoordinateReferenceSystemUtils.wgs84Crs()
            lineWidth: 2
            color: filterToolRoot.colorPalette[index]
            opacity: filterToolRoot.filterActive && !filterToolRoot.sourceIsPoints ? 0.75 : 0.0
        }
    }

    // Recalcule les clusters à chaque zoom / pan
    Connections {
        target: mapCanvas ? mapCanvas.mapSettings : null
        ignoreUnknownSignals: true
        function onExtentChanged() {
            if (filterToolRoot.filterActive && !filterToolRoot.sourceIsPoints
                    && filterToolRoot.centroidPoints.length > 0)
                filterToolRoot.buildClusters()
        }
    }

    // === CENTROÏDES — un Rectangle par cluster via CoordinateTransformer + MapToScreen ===
    Repeater {
        id: centroidItems
        model: filterToolRoot.clusteredPoints

        Item {
            parent: mapCanvas

            CoordinateTransformer {
                id: ct
                sourceCrs: CoordinateReferenceSystemUtils.wgs84Crs()
                destinationCrs: mapCanvas.mapSettings.destinationCrs
                transformContext: qgisProject
                    ? qgisProject.transformContext
                    : CoordinateReferenceSystemUtils.emptyTransformContext()
                // centroid() retourne un QgsPoint — type attendu par sourcePosition
                sourcePosition: {
                    var g = GeometryUtils.createGeometryFromWkt(
                                "POINT(" + modelData.x + " " + modelData.y + ")")
                    return g ? GeometryUtils.centroid(g) : null
                }
            }

            MapToScreen {
                id: mts
                mapSettings: mapCanvas.mapSettings
                mapPoint: ct.projectedPosition
            }

            // Point seul : cercle coloré 12×12 comme avant
            // Cluster   : cercle plus grand, fond foncé, contour coloré, chiffre au centre
            Rectangle {
                x: mts.screenPoint.x - width / 2
                y: mts.screenPoint.y - height / 2
                width:  modelData.clusterCount > 1 ? 22 : 12
                height: modelData.clusterCount > 1 ? 22 : 12
                radius: modelData.clusterCount > 1 ? 11 : 6
                color:        modelData.clusterCount > 1 ? filterToolRoot.colorPalette[modelData.colorIdx]
                                                  : filterToolRoot.colorPalette[modelData.colorIdx]
                border.color: modelData.clusterCount > 1 ? "yellow"
                                                  : "white"
                border.width: modelData.clusterCount > 1 ? 2 : 1.5
                visible: filterToolRoot.filterActive && !filterToolRoot.sourceIsPoints

                Text {
                    anchors.centerIn: parent
                    text: modelData.clusterCount > 1 ? modelData.clusterCount : ""
                    color: "white"
                    font.bold: true
                    font.pixelSize: 10
                    visible: modelData.clusterCount > 1
                }
            }
        }
    }

    Rectangle {
        id: infoBanner
        parent: mapCanvas; z: 9999
        height: 38
        anchors.bottom: parent.bottom
        anchors.bottomMargin: parent.width > parent.height ? 60 : 110
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(bannerLayout.implicitWidth + 30, parent.width - 120)
        radius: 19
        color: "#B3333333"; border.width: 0
        visible: filterToolRoot.filterActive && !filterToolRoot.isFormVisible

        RowLayout {
            id: bannerLayout
            anchors.fill: parent
            anchors.leftMargin: 15
            anchors.rightMargin: 15
            spacing: 10

            Rectangle {
                width: 8; height: 8; radius: 4
                color: targetSelectedColor
                Layout.alignment: Qt.AlignVCenter
            }

            Item {
                id: clipContainer
                Layout.preferredWidth: bannerText.contentWidth
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true

                Text {
                    id: bannerText
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    renderType: Text.NativeRendering
                    text: {
                        var val = filterToolRoot.savedFilterText.trim()
                        if (val.endsWith(";")) val = val.substring(0, val.length - 1).trim()
                        return filterToolRoot.savedLayerName + " | " + filterToolRoot.savedFieldName + " : " + val
                    }
                    color: "white"; font.bold: true; font.pixelSize: 14
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
                                var txt=valueField.text; var last=txt.lastIndexOf(";")
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

            ColumnLayout {
    Layout.fillWidth: true
    spacing: 5

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

    Button {
        id: filterAndDriveButton; text: tr("Filter & Drive me"); enabled: false; Layout.fillWidth: true
        background: Rectangle { radius: 10; color: enabled ? "#80cc28" : "#e0e0e0" }
        contentItem: Text { text: parent.text; color: enabled ? "white" : "#666666"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        onClicked: { applyFilter(true, true); drivemeTool.startWithLayer(selectedLayer); searchDialog.close() }
    }

            }
        }
    }
}
