import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Theme
import org.qfield
import org.qgis
import "qrc:/qml" as QFieldItems

Item {
    id: drivemeTool
    objectName: "driveMe"
    property var mainWindow: iface.mainWindow()
    property var mapCanvas: iface.mapCanvas()
    
    // --- VARIABLES ---
    property var unvisitedPoints: []   
    property var currentTarget: null   
    property int totalPointsCount: 0
    property bool isNavigating: false
    
    // HUD (Distance affichée)
    property string distanceText: "-- m"
    property string hudMessage: ""
    
    // ÉTATS
    property string navState: "DRIVING" 
    property var parkedLocation: null 

    // CONFIG
    property int chainWalkThreshold: 50 
    property var lastProcessPos: null
    property var lastRouteCoords: null
    property bool routeHasFootSegment: false
    property var lastFootPos: null
    property var polygonVertices: ({})  // sommets WGS84 par id de polygone, pour affinage post-route
    property var polygonCenters: ({})   // point intérieur (point_on_surface ou centroïde) par id de polygone
    property var traveledCoords: []     // historique du trajet parcouru — anti-demi-tour

    // --- TRADUCTION FR / EN ---
    property string currentLang: "fr"

    function detectLanguage() {
        var loc = Qt.locale().name.substring(0, 2)
        currentLang = (loc === "fr") ? "fr" : "en"
    }

    property var translations: {
        "RESTANT":                          { "fr": "RESTANT",                          "en": "REMAINING" },
        "DISTANCE":                         { "fr": "DISTANCE",                         "en": "DISTANCE" },
        "NAVIGATION":                       { "fr": "NAVIGATION",                       "en": "NAVIGATION" },
        "Couche:":                          { "fr": "Couche :",                         "en": "Layer:" },
        "ARRÊTER":                          { "fr": "ARRÊTER",                          "en": "STOP" },
        "DÉMARRER":                         { "fr": "DÉMARRER",                         "en": "START" },
        "Aucun élément trouvé":             { "fr": "Aucun élément trouvé",             "en": "No features found" },
        "Aucun point trouvé":               { "fr": "Aucun point trouvé",               "en": "No points found" },
        "✅ Cible atteinte !":              { "fr": "✅ Cible atteinte !",              "en": "✅ Target reached!" },
        "✅ Point validé\nau passage !":   { "fr": "✅ Point validé\nau passage !",   "en": "✅ Point validated\non the way!" },
        "Retour au véhicule.":              { "fr": "Retour au véhicule.",              "en": "Return to vehicle." },
        "🏁 Terminé !":                    { "fr": "🏁 Terminé !",                    "en": "🏁 Done!" },
        "Accès à pied\n(point isolé)":     { "fr": "Accès à pied\n(point isolé)",     "en": "On foot\n(isolated point)" },
        "👟 À pied plus rapide":           { "fr": "👟 À pied plus rapide",           "en": "👟 Faster on foot" },
        "🚗 Retour voiture":               { "fr": "🚗 Retour voiture",               "en": "🚗 Back to car" },
        "min gagnées":                      { "fr": "min gagnées",                      "en": "min saved" },
        "En route.":                        { "fr": "En route.",                        "en": "Drive on." },
        "Fin de route.\nFinir à pied.":    { "fr": "Fin de route.\nFinir à pied.",    "en": "End of road.\nFinish on foot." },
        "Voiture stationnée.\nFinir à pied.": { "fr": "Voiture stationnée.\nFinir à pied.", "en": "Vehicle parked.\nFinish on foot." }
    }

    function tr(key) {
        var t = translations[key]
        if (t) return t[currentLang] !== undefined ? t[currentLang] : key
        return key
    }


    Component.onCompleted: {
        detectLanguage()
    }

    // --- 1. RENDU ---
    QFieldItems.GeometryRenderer {
        id: carRenderer
        parent: mapCanvas
        mapSettings: mapCanvas.mapSettings
        geometryWrapper.crs: CoordinateReferenceSystemUtils.wgs84Crs()
        lineWidth: 6
        color: "cyan" // cyan
        opacity: 0.8
    }

    QFieldItems.GeometryRenderer {
        id: footRenderer
        parent: mapCanvas
        mapSettings: mapCanvas.mapSettings
        geometryWrapper.crs: CoordinateReferenceSystemUtils.wgs84Crs()
        lineWidth: 5
        color: "#FF9500" // Orange
        opacity: 0.9
    }

    QFieldItems.GeometryRenderer {
        id: onRouteRenderer
        parent: mapCanvas
        mapSettings: mapCanvas.mapSettings
        geometryWrapper.crs: CoordinateReferenceSystemUtils.wgs84Crs()
        lineWidth: 14
        color: "#FF0000" // Rouge — points rouges clignotants sur les points on-route
        opacity: 0.9
        SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: isNavigating
            NumberAnimation { from: 0.9; to: 0.1; duration: 500; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.1; to: 0.9; duration: 500; easing.type: Easing.InOutQuad }
        }
    }

    QFieldItems.GeometryRenderer {
        id: polygonCenterRenderer
        parent: mapCanvas
        mapSettings: mapCanvas.mapSettings
        geometryWrapper.crs: CoordinateReferenceSystemUtils.wgs84Crs()
        lineWidth: 4
        color: "#FF00FF" // Fuschia — centre du polygone lié à la cible rouge courante
        opacity: 0.9
        SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: isNavigating
            NumberAnimation { from: 0.9; to: 0.15; duration: 500; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.15; to: 0.9; duration: 500; easing.type: Easing.InOutQuad }
        }
    }

    QFieldItems.GeometryRenderer {
        id: arrowRenderer
        parent: mapCanvas
        mapSettings: mapCanvas.mapSettings
        geometryWrapper.crs: CoordinateReferenceSystemUtils.wgs84Crs()
        lineWidth: 2
        color: "#FF00FF" // Fuschia fin — flèches sommet rouge → centroïde fuschia
        opacity: 0.75
    }

    // --- 2. MARQUEURS ---
    CoordinateTransformer {
        id: targetTransformer
        sourceCrs: CoordinateReferenceSystemUtils.wgs84Crs()
        destinationCrs: mapCanvas.mapSettings.destinationCrs
        transformContext: qgisProject ? qgisProject.transformContext : CoordinateReferenceSystemUtils.emptyTransformContext()
    }
    MapToScreen {
        id: targetScreenPos
        mapSettings: mapCanvas.mapSettings
        mapPoint: targetTransformer.projectedPosition
    }
    Item {
        id: blinkingTarget
        parent: mapCanvas
        visible: isNavigating && currentTarget !== null && navState !== "RETURNING_TO_CAR"
        x: targetScreenPos.screenPoint.x - width / 2
        y: targetScreenPos.screenPoint.y - height / 2
        width: 50; height: 50
        Rectangle { anchors.centerIn: parent; width: 16; height: 16; radius: 8; color: "#FF0000"; border.color: "white"; border.width: 2 }
        Rectangle {
            anchors.centerIn: parent; width: parent.width; height: parent.height; radius: width / 2; color: "transparent"; border.color: "#FF0000"; border.width: 3
            SequentialAnimation on scale { loops: Animation.Infinite; running: blinkingTarget.visible; NumberAnimation { from: 0.2; to: 1.0; duration: 1200; easing.type: Easing.OutQuad } }
            SequentialAnimation on opacity { loops: Animation.Infinite; running: blinkingTarget.visible; NumberAnimation { from: 1.0; to: 0.0; duration: 1200; easing.type: Easing.OutQuad } }
        }
    }

    CoordinateTransformer {
        id: carTransformer
        sourceCrs: CoordinateReferenceSystemUtils.wgs84Crs()
        destinationCrs: mapCanvas.mapSettings.destinationCrs
        transformContext: qgisProject ? qgisProject.transformContext : CoordinateReferenceSystemUtils.emptyTransformContext()
    }
    MapToScreen {
        id: carScreenPos
        mapSettings: mapCanvas.mapSettings
        mapPoint: carTransformer.projectedPosition
    }
    Item {
        id: blinkingCar
        parent: mapCanvas
        visible: isNavigating && parkedLocation !== null
        x: carScreenPos.screenPoint.x - width / 2
        y: carScreenPos.screenPoint.y - height / 2
        width: 60; height: 60
        Rectangle { anchors.centerIn: parent; width: 20; height: 20; radius: 10; color: "#00FF00"; border.color: "black"; border.width: 3 }
        Rectangle {
            anchors.centerIn: parent; width: parent.width; height: parent.height; radius: width / 2; color: "transparent"; border.color: "#00FF00"; border.width: 4
            SequentialAnimation on scale { loops: Animation.Infinite; running: blinkingCar.visible; NumberAnimation { from: 0.3; to: 1.0; duration: 1500; easing.type: Easing.OutQuad } }
            SequentialAnimation on opacity { loops: Animation.Infinite; running: blinkingCar.visible; NumberAnimation { from: 1.0; to: 0.0; duration: 1500; easing.type: Easing.OutQuad } }
        }
    }

    // --- 3. HUD ---
    Rectangle {
        id: hudBar
        parent: mainWindow.contentItem 
        z: 9999
        visible: isNavigating
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: parent.width > parent.height ? 8 : 60
        width: Math.min(parent.width * 0.70, 360) 
        height: 48
        color: "#DD000000" 
        radius: 10
        border.color: "white"
        border.width: 1

        RowLayout {
    anchors.fill: parent
    anchors.margins: 5
    spacing: 6

    // 1. Compteur de points
    Column {
        Layout.fillWidth: true
        Layout.preferredWidth: 3   // poids = 3 parts
        Layout.alignment: Qt.AlignVCenter
        Text { text: tr("RESTANT"); color: "#FFFFFF"; font.pixelSize: 10; font.bold: true }
        Text { text: unvisitedPoints.length + " / " + totalPointsCount; color: "#00FF00"; font.pixelSize: 18; font.bold: true }
    }

    Rectangle { width: 1; height: 40; color: "gray"; Layout.alignment: Qt.AlignVCenter }

    // 2. Mode actuel (avec défilement)
Item {
    Layout.fillWidth: true
    Layout.preferredWidth: 3
    Layout.alignment: Qt.AlignVCenter
    height: 40
    clip: true  // masque le texte qui dépasse

    Text {
        id: hudText
        text: getHudText()
        color: "white"
        font.pixelSize: 14
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter

        // Lance le défilement si le texte est trop large
        onTextChanged: {
            if (hudText.width > hudText.parent.width) {
                marqueeAnim.from = hudText.parent.width
                marqueeAnim.to = -hudText.width
                marqueeAnim.duration = (hudText.width + hudText.parent.width) * 16
                marqueeAnim.restart()
            } else {
                marqueeAnim.stop()
                hudText.x = 0
            }
        }

        NumberAnimation {
            id: marqueeAnim
            target: hudText
            property: "x"
            loops: Animation.Infinite
            easing.type: Easing.Linear
        }
    }
}

    // 3. Distance
    Column {
        Layout.fillWidth: true
        Layout.preferredWidth: 3   // poids = 3 parts
        Layout.alignment: Qt.AlignVCenter
        Text { text: tr("DISTANCE"); color: "#FFFFFF"; font.pixelSize: 10; font.bold: true }
        Text { text: distanceText; color: "cyan"; font.pixelSize: 18; font.bold: true }
    }

    // Bouton d'arrêt
    Item {
        Layout.fillWidth: true
        Layout.preferredWidth: 2   // poids = 2 parts (plus petit)
        Layout.alignment: Qt.AlignVCenter
        implicitHeight: parent.height
        QfToolButton {
            anchors.centerIn: parent
            iconSource: "DriveMeicon.svg"; iconColor: "red"; flat: true
            onClicked: stopNavigation()
        }
    }
  }
}

Timer {
    id: hudMessageTimer
    interval: 3000  // Message visible 3 secondes
    repeat: false
    onTriggered: hudMessage = ""
}

function showHudMessage(text) {
    hudMessage = text
    hudMessageTimer.restart()
}

function getHudText() {
    if (hudMessage !== "") return hudMessage
   // if (navState === "RETURNING_TO_CAR") return "Retour\nvéhicule"
  //  if (navState === "DRIVING") return "Étape\nsuivante"
   // return "À pied"
    return ""
}

    // --- 4. TIMER ---
    Timer {
        id: navTimer
        interval: 800 // 2 secondes pour laisser le temps au réseau
        repeat: true
        running: isNavigating
        onTriggered: updateNavigationLoop()
    }

    // --- 5. POINT D'ENTRÉE EXTERNE ---
    // Appelé par FilterTool via iface.findItemByObjectName("driveMe")
    // Lance directement la navigation sur la couche filtrée, sans dialogue ni bouton
    function startWithLayer(layer) {
        if (layer) {
            startNavigationProcess(layer)
        }
    }

    // --- 6. NAVIGATION ---
    function stopNavigation() {
        isNavigating = false
        // Nettoyage lignes
        let empty = GeometryUtils.createGeometryFromWkt("LINESTRING(0 0, 0.000001 0.000001)")
        if(empty) {
            carRenderer.geometryWrapper.qgsGeometry = empty
            footRenderer.geometryWrapper.qgsGeometry = empty
            onRouteRenderer.geometryWrapper.qgsGeometry = empty
            polygonCenterRenderer.geometryWrapper.qgsGeometry = empty
            arrowRenderer.geometryWrapper.qgsGeometry = empty
        }
        // Nettoyage marqueur voiture
        // CORRECTION DE L'ERREUR ICI : On n'utilise pas createPoint, mais WKT
        let emptyPoint = GeometryUtils.createGeometryFromWkt("POINT(0 0)")
        if (emptyPoint) {
            carTransformer.sourcePosition = GeometryUtils.centroid(emptyPoint)
        }
        lastRouteCoords = null
        routeHasFootSegment = false
        lastFootPos = null
        polygonVertices = {}
        polygonCenters = {}
        traveledCoords = []

        iface.logMessage("Arrêt.", Qgis.Info)
        mapCanvas.refresh()
    }

    function startNavigationProcess(layer) {
        try {
            chainWalkThreshold = 50

            // Vérification sélection préexistante via selectedFeatures() (API QField confirmée)
            let preSelected = layer.selectedFeatures()
            let hasPreSelection = preSelected && preSelected.length > 0
            let feats = []

            if (hasPreSelection) {
                // Des entités sont déjà sélectionnées : on les utilise telles quelles
                // On NE touche PAS à la sélection → le jaune reste affiché sur la carte
                feats = preSelected
            } else {
                // Aucune sélection préalable (couche points/lignes) : sélectionne tout puis nettoie
                layer.selectAll()
                feats = layer.selectedFeatures()
                layer.removeSelection()
            }

            if (!feats || feats.length === 0) { showHudMessage(tr("Aucun élément trouvé")); return }

            if (hasPreSelection) {
                // POLYGONES : point du bord le plus proche de la position de départ (Option B)
                let startPos = getCurrentGpsPosition()
                if (!startPos) startPos = getMapCenter()
                let rawPoints = resolvePolygonBoundaryPoints(feats, layer, startPos)
                if (rawPoints.length < 1) { showHudMessage(tr("Aucun point trouvé")); return }
                proceedWithNavigation(rawPoints)
            } else {
                // POINTS / LIGNES : centroïde de chaque entité, démarrage direct
                let rawPoints = []
                for (let i = 0; i < feats.length; i++) {
                    let g = feats[i].geometry
                    if (g) {
                        let pt = GeometryUtils.centroid(g)
                        if (pt) {
                            let wgs = GeometryUtils.reprojectPointToWgs84(pt, layer.crs)
                            if (wgs) rawPoints.push({ id: i, x: wgs.x, y: wgs.y })
                        }
                    }
                }
                if (rawPoints.length < 1) { showHudMessage(tr("Aucun point trouvé")); return }
                proceedWithNavigation(rawPoints)
            }

        } catch(e) {
            iface.logMessage("Erreur startNav: " + e.toString(), Qgis.Critical)
        }
    }

    // --- OPTION B : sommet du polygone le plus proche de la route/parking, sinon de la position ---
    // Aucun appel réseau — purement géométrique
    // Priorité 1 : parkedLocation (distance à pied depuis parking)
    // Priorité 2 : route OSRM (distance réelle au segment, couvre 2 côtés de route)
    // Priorité 3 : position GPS (aucune route connue)
    function resolvePolygonBoundaryPoints(feats, layer, refPos) {
        let rawPoints = []
        let hasRoute = lastRouteCoords && lastRouteCoords.length >= 2
        let hasParking = parkedLocation && parkedLocation.x

        for (let i = 0; i < feats.length; i++) {
            let g = feats[i].geometry
            if (!g) continue

            // Fallback : centroïde en WGS84
            let centPt = GeometryUtils.centroid(g)
            if (!centPt) continue
            let wgsFallback = GeometryUtils.reprojectPointToWgs84(centPt, layer.crs)
            if (!wgsFallback) continue
            let fallback = { id: i, x: wgsFallback.x, y: wgsFallback.y, onRoute: false }

                // Stocker le point intérieur du polygone : point_on_surface si dispo, sinon centroïde
                try {
                    let innerPt = GeometryUtils.pointOnSurface ? GeometryUtils.pointOnSurface(g) : null
                    let innerWgs = innerPt ? GeometryUtils.reprojectPointToWgs84(innerPt, layer.crs) : null
                    polygonCenters[i] = innerWgs ? { x: innerWgs.x, y: innerWgs.y } : { x: wgsFallback.x, y: wgsFallback.y }
                } catch(e) {
                    polygonCenters[i] = { x: wgsFallback.x, y: wgsFallback.y }
                }

            try {
                // Extraire les sommets du contour extérieur via WKT
                let wkt = g.asWkt()
                let coords = parseOuterRingCoords(wkt)
                if (!coords || coords.length < 2) { rawPoints.push(fallback); continue }

                // Reprojeter tous les sommets en WGS84
                let vertices = []
                for (let j = 0; j < coords.length; j++) {
                    let vWkt = "POINT(" + coords[j][0] + " " + coords[j][1] + ")"
                    let vGeom = GeometryUtils.createGeometryFromWkt(vWkt)
                    if (!vGeom) continue
                    let vPt = GeometryUtils.centroid(vGeom)
                    if (!vPt) continue
                    let vWgs = GeometryUtils.reprojectPointToWgs84(vPt, layer.crs)
                    if (!vWgs) continue
                    vertices.push({ x: vWgs.x, y: vWgs.y })
                }
                if (vertices.length === 0) { rawPoints.push(fallback); continue }

                // Stockage des sommets pour affinage ultérieur quand la route OSRM sera connue
                polygonVertices[i] = vertices

                let bestPt = null
                let bestDist = 1e9

                if (hasParking) {
    // PRIORITÉ 1 : on est garé → sommet minimisant (distance parking + distance route)
    for (let k = 0; k < vertices.length; k++) {
        let dParking = getDistMeters(parkedLocation, vertices[k])
        let dRoute = hasRoute ? minDistToRouteLine(vertices[k], lastRouteCoords) : 0
        let d = dParking + dRoute
        if (d < bestDist) { bestDist = d; bestPt = vertices[k] }
    }
                } else if (hasRoute) {
                    // PRIORITÉ 2 : sommet le plus proche de la route (projection réelle sur segments)
                    // → trouve automatiquement le côté optimal si la route longe 2 bords du polygone
                    for (let k = 0; k < vertices.length; k++) {
                        let d = minDistToRouteLine(vertices[k], lastRouteCoords)
                        if (d < bestDist) { bestDist = d; bestPt = vertices[k] }
                    }
                    // Si trop loin de la route (>200m) → pas de route carrossable proche
                    if (bestDist > 200) {
                        bestDist = 1e9; bestPt = null
                        for (let k = 0; k < vertices.length; k++) {
                            let d = getDistMeters(refPos || fallback, vertices[k])
                            if (d < bestDist) { bestDist = d; bestPt = vertices[k] }
                        }
                    }
                } else {
                    // PRIORITÉ 3 : aucune route connue → sommet le plus proche de la position GPS
                    for (let k = 0; k < vertices.length; k++) {
                        let d = getDistMeters(refPos || fallback, vertices[k])
                        if (d < bestDist) { bestDist = d; bestPt = vertices[k] }
                    }
                }

                if (!bestPt) { rawPoints.push(fallback); continue }

                // onRoute : sommet ≤ 20m de la route → accessible en voiture → flyby
                let isOnRoute = hasRoute ? (minDistToRouteLine(bestPt, lastRouteCoords) < 20) : false
                // isolated : tous les sommets à > 200m de toute route → sera chaîné au voisin accessible
                let isIsolated = hasRoute && bestDist > 200
                rawPoints.push({ id: i, x: bestPt.x, y: bestPt.y, onRoute: isOnRoute, isolated: isIsolated })

            } catch(e) {
                rawPoints.push(fallback)  // fallback silencieux : centroïde
            }
        }
        // Chaîner les points isolés vers leur voisin accessible par route
        chainIsolatedPoints(rawPoints)
        return rawPoints
    }

    // --- Distance minimale d'un point au segment de route le plus proche (projection réelle) ---
    // Plus précis que nœud-par-nœud : trouve la vraie distance à pied minimale depuis n'importe
    // quel endroit de la route — couvre le cas "polygone accessible depuis 2 routes différentes"
    function minDistToRouteLine(pt, routeCoords) {
        let coords = routeCoords || lastRouteCoords
        if (!coords || coords.length < 2) return 1e9
        let minD = 1e9
        for (let i = 0; i < coords.length - 1; i++) {
            let a = { x: coords[i][0],   y: coords[i][1] }
            let b = { x: coords[i+1][0], y: coords[i+1][1] }
            let d = distPointToSegmentMeters(pt, a, b)
            if (d < minD) minD = d
        }
        // Vérifier aussi le dernier nœud isolé
        let last = { x: coords[coords.length-1][0], y: coords[coords.length-1][1] }
        let dLast = getDistMeters(pt, last)
        if (dLast < minD) minD = dLast
        return minD
    }

    // --- Distance d'un point à un segment AB (projection clampée sur [0,1]) ---
    function distPointToSegmentMeters(pt, a, b) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if (lenSq < 1e-12) return getDistMeters(pt, a)
        // Paramètre de projection t, clampé entre 0 et 1
        let t = ((pt.x - a.x) * dx + (pt.y - a.y) * dy) / lenSq
        t = Math.max(0, Math.min(1, t))
        let proj = { x: a.x + t * dx, y: a.y + t * dy }
        return getDistMeters(pt, proj)
    }

    // Raccourci : distance minimale à la route courante (lastRouteCoords)
    function minDistToRoute(pt) {
        return minDistToRouteLine(pt, lastRouteCoords)
    }

    // --- Rendu des points rouges clignotants sur les points on-route encore non validés ---
    function updateOnRouteRenderer() {
        let onRoutePts = unvisitedPoints.filter(function(p) { return p.onRoute })
        if (onRoutePts.length === 0) {
            clearGeometry(onRouteRenderer)
            return
        }
        // MULTIPOINT : chaque point devient un cercle rouge grâce à lineWidth: 14
        let pts = []
        for (let i = 0; i < onRoutePts.length; i++) {
            pts.push(onRoutePts[i].x.toFixed(6) + " " + onRoutePts[i].y.toFixed(6))
        }
        let wkt = "MULTIPOINT(" + pts.join(",") + ")"
        let geom = GeometryUtils.createGeometryFromWkt(wkt)
        if (geom) onRouteRenderer.geometryWrapper.qgsGeometry = geom
    }

    // --- Parseur WKT : extrait les coordonnées du premier anneau extérieur ---
    // Gère POLYGON((x y,...)) et MULTIPOLYGON(((x y,...)))
    function parseOuterRingCoords(wkt) {
        try {
            // Supprimer le préfixe POLYGON ou MULTIPOLYGON et les premières parenthèses
            let cleaned = wkt.replace(/^MULTIPOLYGON\s*\(\s*\(\s*\(/, "((")
                              .replace(/^POLYGON\s*\(/, "(")
            // Extraire le contenu du premier anneau entre parenthèses
            let match = cleaned.match(/\(([^)]+)\)/)
            if (!match) return null
            let pairs = match[1].trim().split(",")
            let coords = []
            for (let i = 0; i < pairs.length; i++) {
                let parts = pairs[i].trim().split(/\s+/)
                if (parts.length >= 2) {
                    let x = parseFloat(parts[0])
                    let y = parseFloat(parts[1])
                    if (!isNaN(x) && !isNaN(y)) coords.push([x, y])
                }
            }
            return coords.length >= 2 ? coords : null
        } catch(e) { return null }
    }

    // --- DÉMARRAGE NAVIGATION : commun points/lignes et polygones ---
    function proceedWithNavigation(rawPoints) {
        if (rawPoints.length < 1) { showHudMessage(tr("Aucun point trouvé")); return }

        unvisitedPoints = rawPoints
        totalPointsCount = rawPoints.length
        
        // Premier tri
        let startPos = getCurrentGpsPosition()
        if (!startPos) startPos = getMapCenter() 
        if (!startPos) startPos = rawPoints[0]
        
        currentTarget = getClosestPoint(startPos, unvisitedPoints).point
        navState = "DRIVING"
        parkedLocation = null
        isNavigating = true
        lastProcessPos = null
        
        // Optimisation Trip en tache de fond
        if (unvisitedPoints.length >= 2 && unvisitedPoints.length < 50) {
            optimizeEntireTour(startPos)
        }
        
        iface.logMessage("Nav démarrée.", Qgis.Info)
        updateNavigationLoop()
    }

    function optimizeEntireTour(startPos) {
        let coords = startPos.x.toFixed(6) + "," + startPos.y.toFixed(6) + ";"
        coords += unvisitedPoints.map(p => p.x.toFixed(6) + "," + p.y.toFixed(6)).join(";")
        
        let url = "https://routing.openstreetmap.de/routed-car/trip/v1/driving/" + coords + "?source=first"
        
        var xhrTrip = new XMLHttpRequest()
        xhrTrip.onreadystatechange = function() {
            if (xhrTrip.readyState === XMLHttpRequest.DONE && xhrTrip.status === 200) {
                try {
                    let json = JSON.parse(xhrTrip.responseText)
                    if (json.waypoints) {
                        let newOrder = []
                        let waypoints = json.waypoints.sort((a,b) => a.waypoint_index - b.waypoint_index)
                        for (let i = 0; i < waypoints.length; i++) {
                            let idx = waypoints[i].location_index
                            if (idx > 0) newOrder.push(unvisitedPoints[idx - 1])
                        }
                        if (newOrder.length === unvisitedPoints.length) {
                            unvisitedPoints = newOrder
                            currentTarget = unvisitedPoints[0]
                            iface.logMessage("Tournée optimisée par OSRM.", Qgis.Success)
                        }
                    }
                } catch(e) {}
            }
        }
        xhrTrip.open("GET", url)
        xhrTrip.send()
    }

    function getClosestPoint(pos, pointsArray) {
        if (!pointsArray || pointsArray.length === 0) return null
        let minDist = 1e9
        let closest = null
        for (let i = 0; i < pointsArray.length; i++) {
            let pt = pointsArray[i]
            let d = getDistMeters(pos, pt)
            if (d < minDist) { minDist = d; closest = pt }
        }
        return { point: closest, distance: minDist }
    }

    function pickBestVertex(pt) {
        // Si route connue → sommet le plus proche de la route
        // Fallback : trajet GPS parcouru (traveledCoords) — évite la dépendance circulaire
        // où la route est calculée vers le mauvais sommet et confirme ce même mauvais sommet
        let verts = polygonVertices[pt.id]
        if (!verts || verts.length === 0) return pt

        // Choisir la référence : route Valhalla si dispo, sinon trajet GPS parcouru
        let refCoords = null
        if (lastRouteCoords && lastRouteCoords.length >= 2) {
            refCoords = lastRouteCoords
        } else if (traveledCoords && traveledCoords.length >= 2) {
            // Convertir traveledCoords [{x,y}] en [[x,y]] pour minDistToRouteLine
            refCoords = traveledCoords.map(function(p) { return [p.x, p.y] })
        }
        if (!refCoords) return pt

        let bestPt = null
        let bestDist = 1e9
        for (let k = 0; k < verts.length; k++) {
            let d = minDistToRouteLine(verts[k], refCoords)
            if (d < bestDist) { bestDist = d; bestPt = verts[k] }
        }
        if (!bestPt) return pt
        return { id: pt.id, x: bestPt.x, y: bestPt.y, onRoute: bestDist < 20, isolated: pt.isolated }
    }

    // --- 8. BOUCLE PRINCIPALE ---
    function updateNavigationLoop() {
        if (!isNavigating) return

        let myPos = getCurrentGpsPosition()
        if (!myPos) myPos = getMapCenter() 
        if (!myPos) return

        // --- ENREGISTREMENT DU TRAJET PARCOURU (anti-demi-tour) ---
        if (navState === "DRIVING") {
            let lastTraveled = traveledCoords.length > 0 ? traveledCoords[traveledCoords.length - 1] : null
            if (!lastTraveled || getDistMeters(myPos, lastTraveled) > 15) {
                traveledCoords.push({ x: myPos.x, y: myPos.y })
            }
        }

        // --- NOUVEAU : CALCUL DE LA DISTANCE POUR LE HUD ---
        let targetDist = 0
        if (navState === "RETURNING_TO_CAR" && parkedLocation) {
            targetDist = getDistMeters(myPos, parkedLocation)
        } else if (currentTarget) {
            targetDist = getDistMeters(myPos, currentTarget)
        }
        
        // Formatage de la distance (Mètres ou Kilomètres)
        if (targetDist > 1000) {
            distanceText = (targetDist / 1000).toFixed(1) + " km"
        } else if (targetDist > 0) {
            distanceText = Math.round(targetDist) + " m"
        } else {
            distanceText = "-- m"
        }
        // --------------------------------------------------    

        // FLYBY Validation — position actuelle + trajet déjà parcouru (anti-demi-tour)
        let targetWasValidated = false
        let remainingPoints =[]
        let flybyRadius = (navState === "DRIVING" || navState === "RETURNING_TO_CAR") ? 15 : 10

        for (let i = 0; i < unvisitedPoints.length; i++) {
            let pt = unvisitedPoints[i]
            // Vérification 1 : proximité immédiate (comportement original)
            let nearNow = getDistMeters(myPos, pt) <= flybyRadius
            // Vérification 2 : le point onRoute est proche d'un endroit déjà parcouru (anti-demi-tour)
            let nearTraveled = false
            if (!nearNow && pt.onRoute) {
                for (let t = 0; t < traveledCoords.length; t++) {
                    if (getDistMeters(traveledCoords[t], pt) <= flybyRadius) {
                        nearTraveled = true
                        break
                    }
                }
            }
            if (nearNow || nearTraveled) {
                if (currentTarget && pt.id === currentTarget.id) {
                    targetWasValidated = true
                    showHudMessage(tr("✅ Cible atteinte !"))
                    // Ne garer la voiture que si le point suivant nécessite vraiment de marcher.
                    // Si des points restants sont onRoute ou à portée de conduite → pas de parking.
                    if (navState === "DRIVING") {
                        let nextPts = unvisitedPoints.filter(function(p) { return p.id !== pt.id })
                        let needsPark = shouldParkHere(myPos, nextPts)
                        if (needsPark) parkedLocation = { x: myPos.x, y: myPos.y }
                    }
                } else {
                    showHudMessage(tr("✅ Point validé\nau passage !"))
                }
            } else {
                remainingPoints.push(pt)
            }
        }
        unvisitedPoints = remainingPoints
        updateOnRouteRenderer()
        updatePolygonCenterRenderer()
        updateArrowRenderer()

        // TRANSITIONS
        if (unvisitedPoints.length === 0) {
            if (parkedLocation && navState !== "RETURNING_TO_CAR") {
                navState = "RETURNING_TO_CAR"
                showHudMessage(tr("Retour au véhicule."))
            } else if (navState !== "RETURNING_TO_CAR") {
                stopNavigation()
                showHudMessage(tr("🏁 Terminé !"))
                return
            }
        } 
        else if (targetWasValidated || !currentTarget || !unvisitedPoints.find(p => p.id === currentTarget.id)) {
            // Choix du prochain
            if (parkedLocation) {
                // Privilégier les points onRoute (accessibles en voiture) même depuis le parking
let onRoutePoints = unvisitedPoints.filter(function(p) { return p.onRoute && !p.isolated })
let next = onRoutePoints.length > 0
    ? getClosestPoint(myPos, onRoutePoints)
    : getClosestPoint(myPos, unvisitedPoints)
if (!next) {
                    navState = "RETURNING_TO_CAR"
                } else {
                    let pt = next.point
                    let distToNext = next.distance
                    let distToParked = getDistMeters(myPos, parkedLocation)

                    // Règle 1 — Point isolé (inaccessible en voiture) → toujours à pied
                    if (pt.isolated) {
                        currentTarget = pt
                        navState = "WALKING_TO_POI"
                        updatePolygonCenterRenderer()
                        updateArrowRenderer()
                        showHudMessage(tr("Accès à pied\n(point isolé)"))

                    } else {
                        // Règles 2/3/4 — Comparaison de temps : marcher vs retourner au véhicule
                        // Vitesse marche : 1.2 m/s | Vitesse voiture : 8.3 m/s (30 km/h)
                        // Distance voiture estimée = vol d'oiseau × 1.4 (facteur de détour typique)
                        let walkSpeed  = 1.2   // m/s
                        let driveSpeed = 8.3   // m/s

                        let timeWalk = distToNext / walkSpeed

                        // Temps voiture : retour à pied jusqu'à la voiture + trajet routier vers le sommet
                        let driveDistEst = getDistMeters(parkedLocation, pt) * 1.4
                        let timeCar  = distToParked / walkSpeed + driveDistEst / driveSpeed

                        if (timeWalk <= timeCar) {
                            // Plus rapide à pied
                            currentTarget = pt
                            navState = "WALKING_TO_POI"
                            updatePolygonCenterRenderer()
                            updateArrowRenderer()
                            let saved = Math.round((timeCar - timeWalk) / 60)
                            showHudMessage(tr("👟 À pied plus rapide") + "\n(~" + saved + " " + tr("min gagnées") + ")")
                        } else {
                            // Plus rapide en voiture
                            navState = "RETURNING_TO_CAR"
                            let saved = Math.round((timeWalk - timeCar) / 60)
                            showHudMessage(tr("🚗 Retour voiture") + "\n(~" + saved + " " + tr("min gagnées") + ")")
                        }
                    }
                }
            } else {
    // Pas encore garé : sélection globale via /locate sur tous les sommets de toutes les géométries
    // → pour chaque géométrie : meilleur sommet = celui le plus proche d'une route
    // → parmi tous ces meilleurs sommets : choisir celui le plus proche de myPos
    lastRouteCoords = null
    currentTarget = null   // pas de cible provisoire — on attend /locate
    navState = "DRIVING"
    lastProcessPos = null
    selectNextTarget(myPos, function(bestTarget) {
        if (navState !== "DRIVING") return
        if (!bestTarget) return
        if (!unvisitedPoints.find(function(p) { return p.id === bestTarget.id })) return
        currentTarget = bestTarget
        unvisitedPoints = unvisitedPoints.map(function(p) { return p.id === bestTarget.id ? bestTarget : p })
        updateOnRouteRenderer()
        updatePolygonCenterRenderer()
        updateArrowRenderer()
        mapCanvas.refresh()
    })
   }
}
        if (unvisitedPoints.length === 0 && navState !== "RETURNING_TO_CAR") return

// MAJ Marqueurs
        let activeTarget = (navState === "RETURNING_TO_CAR" && parkedLocation) ? parkedLocation : currentTarget;
        if (activeTarget && activeTarget.x) {
            let wktTarget = "POINT(" + activeTarget.x + " " + activeTarget.y + ")"
            let g = GeometryUtils.createGeometryFromWkt(wktTarget)
            if(g) targetTransformer.sourcePosition = GeometryUtils.centroid(g)
        }
        if (parkedLocation && parkedLocation.x) {
            let wktCar = "POINT(" + parkedLocation.x + " " + parkedLocation.y + ")"
            let g = GeometryUtils.createGeometryFromWkt(wktCar)
            if(g) carTransformer.sourcePosition = GeometryUtils.centroid(g)
        } else {
            // CORRECTION ERREUR : Utilisation WKT pour cacher le marqueur
            let emptyPoint = GeometryUtils.createGeometryFromWkt("POINT(0 0)")
            if(emptyPoint) carTransformer.sourcePosition = GeometryUtils.centroid(emptyPoint)
        }

        // 5. TRACÉS
        var needsRefresh = false

        if (navState === "RETURNING_TO_CAR") {
            if (!parkedLocation) return
            if (getDistMeters(myPos, parkedLocation) < 20) {
                parkedLocation = null
                navState = "DRIVING"
                lastProcessPos = null
                lastRouteCoords = null
                lastFootPos = null
                showHudMessage(tr("En route."))
                updateNavigationLoop()
                return
            }
            if (!lastFootPos || getDistMeters(myPos, lastFootPos) > 3) {
                lastFootPos = myPos
                clearGeometry(carRenderer)
                drawDirectLine(myPos, parkedLocation, footRenderer)
                needsRefresh = true
            }
        } 
        else if (navState === "WALKING_TO_POI") {
            if (!currentTarget) return
            if (!lastFootPos || getDistMeters(myPos, lastFootPos) > 3) {
                lastFootPos = myPos
                clearGeometry(carRenderer)
                drawDirectLine(myPos, currentTarget, footRenderer)
                needsRefresh = true
            }
        }
        else if (navState === "DRIVING") {
            if (!currentTarget) return
            if (lastRouteCoords && lastRouteCoords.length >= 2) {
                if (trimRouteToCurrentPos(myPos)) needsRefresh = true
            }
            if (!lastProcessPos || getDistMeters(myPos, lastProcessPos) > 40) {
                lastProcessPos = myPos
                fetchOsrmRoute(myPos, currentTarget)
            }
        }

        if (needsRefresh) mapCanvas.refresh()
    }
    // --- Sélectionne la prochaine cible optimale via /locate Valhalla ---
    // 1. Collecte tous les sommets de toutes les géométries restantes (non-isolées)
    // 2. Un seul appel /locate → distance à la route pour chaque sommet
    // 3. Pour chaque géométrie : garde le sommet le plus proche d'une route
    // 4. Parmi ces meilleurs sommets : choisit celui le plus proche de myPos
    // 5. Fallback pour les géométries sans sommets proches de route (isolées) : sommet le plus proche de myPos
    function selectNextTarget(myPos, onDone) {
        let snapNavState = navState

        // Construire index : pour chaque sommet → quel pt (id, isolated)
        let allVerts = []   // { vert: {x,y}, ptId, isolated }
        for (let i = 0; i < unvisitedPoints.length; i++) {
            let pt = unvisitedPoints[i]
            if (pt.isolated) continue   // les isolés sont gérés séparément
            let verts = polygonVertices[pt.id]
            if (verts && verts.length > 0) {
                for (let j = 0; j < verts.length; j++) {
                    allVerts.push({ vert: verts[j], ptId: pt.id, isolated: false })
                }
            } else {
                // Point/ligne : pas de polygonVertices → utiliser le point directement
                allVerts.push({ vert: { x: pt.x, y: pt.y }, ptId: pt.id, isolated: false })
            }
        }

        if (allVerts.length === 0) {
            // Que des isolés → fallback simple
            let fb = getClosestPoint(myPos, unvisitedPoints)
            onDone(fb ? fb.point : null)
            return
        }

        let locations = allVerts.map(function(e) { return { lon: e.vert.x, lat: e.vert.y } })
        let body = JSON.stringify({ locations: locations, costing: "auto" })
        let url = "https://valhalla1.openstreetmap.de/locate"

        var req = new XMLHttpRequest()
        req.timeout = 8000
        req.ontimeout = function() {
            // Fallback : géométrie la plus proche de myPos
            let fb = getClosestPoint(myPos, unvisitedPoints.filter(function(p) { return !p.isolated }))
            if (!fb) fb = getClosestPoint(myPos, unvisitedPoints)
            onDone(fb ? fb.point : null)
        }
        req.onerror = req.ontimeout
        req.onreadystatechange = function() {
            if (req.readyState !== XMLHttpRequest.DONE) return
            if (navState !== snapNavState) return
            if (req.status === 200) {
                try {
                    let json = JSON.parse(req.responseText)

                    // Étape 1 : pour chaque géométrie, trouver son sommet le plus proche d'une route
                    // edges[0].distance est un ratio 0-1 le long du tronçon, PAS une distance en mètres
                    // La vraie distance = getDistMeters(sommet_original, correlated_lat/lon)
                    let bestPerPt = {}   // ptId → { vert, roadDist }
                    for (let k = 0; k < json.length && k < allVerts.length; k++) {
                        let entry = json[k]
                        let roadDist = 1e9
                        if (entry && entry.edges && entry.edges.length > 0) {
                            let edge = entry.edges[0]
                            if (edge.correlated_lat !== undefined && edge.correlated_lon !== undefined) {
                                // Distance réelle entre le sommet et son snap sur la route
                                roadDist = getDistMeters(
                                    allVerts[k].vert,
                                    { x: edge.correlated_lon, y: edge.correlated_lat }
                                )
                            }
                        }
                        let ptId = allVerts[k].ptId
                        if (!bestPerPt[ptId] || roadDist < bestPerPt[ptId].roadDist) {
                            bestPerPt[ptId] = { vert: allVerts[k].vert, roadDist: roadDist }
                        }
                    }

                    // Étape 2 : parmi les meilleurs sommets par géométrie, choisir celui le plus proche de myPos
                    // Ignorer les géométries dont le meilleur sommet est à > 200m d'une route (seront traitées en isolé)
                    let bestTarget = null
                    let bestScore = 1e9
                    for (let ptId in bestPerPt) {
                        let b = bestPerPt[ptId]
                        let distToMe = getDistMeters(myPos, b.vert)
                        // Géométries proches d'une route : score = distance à myPos
                        // Géométries loin de toute route (> 200m) : ignorées ici → fallback isolé
                        if (b.roadDist <= 200 && distToMe < bestScore) {
                            bestScore = distToMe
                            let pt = unvisitedPoints.find(function(p) { return p.id === parseInt(ptId) || p.id === ptId })
                            if (pt) bestTarget = { id: pt.id, x: b.vert.x, y: b.vert.y, onRoute: b.roadDist < 20, isolated: pt.isolated }
                        }
                    }

                    // Étape 3 : si aucune géométrie avec sommet proche route → fallback toutes géométries
                    if (!bestTarget) {
                        let fb = getClosestPoint(myPos, unvisitedPoints)
                        bestTarget = fb ? fb.point : null
                    }

                    onDone(bestTarget)
                    return
                } catch(e) {}
            }
            // Erreur HTTP → fallback
            let fb = getClosestPoint(myPos, unvisitedPoints)
            onDone(fb ? fb.point : null)
        }
        req.open("POST", url)
        req.setRequestHeader("Content-Type", "application/json")
        req.send(body)
    }

    // --- 9. ROUTAGE VALHALLA — costing auto + use_tracks:1 (chemins agricoles, pistes, voies carrossables) ---
    function fetchOsrmRoute(start, end) {
        // (guard onRoute supprimé : refinePolygonTargetsFromRoute doit toujours pouvoir corriger le sommet)
        let snapNavState = navState
        let snapTarget = currentTarget
        valhallaRequest(start, end, snapNavState, snapTarget, function(coords, snap, distOffRoad) {
            if (navState !== snapNavState || currentTarget !== snapTarget) return
            applyRouteResult(start, end, coords, snap, distOffRoad, snapNavState, snapTarget)
        })
    }

    // Décode le polyline6 de Valhalla en tableau [[lon, lat], ...]
    function decodePolyline6(encoded) {
        let coords = []
        let index = 0, lat = 0, lng = 0
        while (index < encoded.length) {
            let b, shift = 0, result = 0
            do {
                b = encoded.charCodeAt(index++) - 63
                result |= (b & 0x1f) << shift
                shift += 5
            } while (b >= 0x20)
            let dlat = (result & 1) ? ~(result >> 1) : (result >> 1)
            lat += dlat
            shift = 0; result = 0
            do {
                b = encoded.charCodeAt(index++) - 63
                result |= (b & 0x1f) << shift
                shift += 5
            } while (b >= 0x20)
            let dlng = (result & 1) ? ~(result >> 1) : (result >> 1)
            lng += dlng
            coords.push([lng / 1e6, lat / 1e6])  // [lon, lat] — même ordre qu'OSRM
        }
        return coords
    }

    function valhallaRequest(start, end, snapNavState, snapTarget, callback) {
        let url = "https://valhalla1.openstreetmap.de/route"
        let body = JSON.stringify({
            locations: [
                { lon: start.x, lat: start.y, type: "break" },
                { lon: end.x,   lat: end.y,   type: "break" }
            ],
            costing: "auto",
            costing_options: {
                auto: {
                    use_tracks: 1.0,    // accepter les chemins agricoles et pistes carrossables
                    use_roads:  0.8,
                    use_ferry:  0.0,
                    top_speed:  80
                }
            },
            directions_options: { units: "kilometers" }
        })
        var req = new XMLHttpRequest()
        req.timeout = 4000
        req.ontimeout = function() { callback(null, null, 1e9) }
        req.onerror   = function() { callback(null, null, 1e9) }
        req.onreadystatechange = function() {
            if (req.readyState !== XMLHttpRequest.DONE) return
            if (navState !== snapNavState || currentTarget !== snapTarget) return
            if (req.status === 200) {
                try {
                    let json = JSON.parse(req.responseText)
                    if (json.trip && json.trip.legs && json.trip.legs.length > 0) {
                        let coords = decodePolyline6(json.trip.legs[0].shape)
                        if (coords && coords.length >= 2) {
                            let snap = { x: coords[coords.length-1][0], y: coords[coords.length-1][1] }
                            callback(coords, snap, getDistMeters(snap, end))
                            return
                        }
                    }
                } catch(e) {}
            }
            callback(null, null, 1e9)
        }
        req.open("POST", url)
        req.setRequestHeader("Content-Type", "application/json")
        req.send(body)
    }

    function applyRouteResult(start, end, coords, snap, distOffRoad, snapNavState, snapTarget) {
        if (!coords) { drawDirectLine(start, end, carRenderer); return }
        if (navState !== snapNavState || currentTarget !== snapTarget) return
        // Prolonger la route de 10m au-delà du point cible
        let extCoords = coords
        if (coords.length >= 2) {
            let p1 = coords[coords.length - 2]
            let p2 = coords[coords.length - 1]
            let dx = p2[0] - p1[0]
            let dy = p2[1] - p1[1]
            let segLen = getDistMeters({ x: p1[0], y: p1[1] }, { x: p2[0], y: p2[1] })
            if (segLen > 0) {
                // 10m en degrés (approximation : 1 degré �� 111320m en lat, cos(lat)*111320 en lon)
                let mPerDegLat = 111320
                let mPerDegLon = Math.cos(p2[1] * Math.PI / 180) * 111320
                let extLon = p2[0] + (dx / segLen) * (10 / mPerDegLon)
                let extLat = p2[1] + (dy / segLen) * (10 / mPerDegLat)
                extCoords = coords.concat([[extLon, extLat]])
            }
        }
        drawLineFromCoords(extCoords, carRenderer)
        lastRouteCoords = coords
        refinePolygonTargetsFromRoute(coords, snap)
        if (distOffRoad > 20 && !(currentTarget && currentTarget.onRoute)) {
            routeHasFootSegment = true
            drawDirectLine(snap, currentTarget, footRenderer)
            if (getDistMeters(start, snap) < 30) {
                parkedLocation = snap
                navState = "WALKING_TO_POI"
                lastFootPos = null
                updatePolygonCenterRenderer()
                updateArrowRenderer()
                showHudMessage(tr("Fin de route.\nFinir à pied."))
            }
        } else {
            routeHasFootSegment = false
            clearGeometry(footRenderer)
        }
        mapCanvas.refresh()
    } 

    // --- AFFINAGE POST-ROUTE : re-évalue les sommets polygon contre la route réelle ---
    // Même priorité que resolvePolygonBoundaryPoints : parking > route > GPS
    // Utilise minDistToRouteLine (projection sur segments) pour couvrir les 2 côtés de route
    function refinePolygonTargetsFromRoute(routeCoords, snap) {
        if (!routeCoords || routeCoords.length < 2) return
        let hasParking = parkedLocation && parkedLocation.x

        // Construire refCoords : routeCoords en coupant les derniers 30m
        // Construire refCoords : routeCoords en coupant les derniers 120m
        // → conserve la partie centrale qui longe la vraie voirie près des bons sommets
        let refCoords = routeCoords
        let cumDist = 0
        for (let i = routeCoords.length - 2; i >= 1; i--) {
            cumDist += getDistMeters(
                { x: routeCoords[i][0],   y: routeCoords[i][1] },
                { x: routeCoords[i+1][0], y: routeCoords[i+1][1] }
            )
            if (cumDist > 120) { refCoords = routeCoords.slice(0, i + 1); break }
        }
        if (refCoords.length < 2) refCoords = routeCoords.slice(0, routeCoords.length - 1)
        if (refCoords.length < 2) return

        let updated = unvisitedPoints.map(function(pt) {
            let verts = polygonVertices[pt.id]
            if (!verts || verts.length === 0) return pt

            let bestPt = null
            let bestDist = 1e9

            if (hasParking) {
                // PRIORITÉ 1 : garé → sommet minimisant (distance parking + distance à la route)
                for (let j = 0; j < verts.length; j++) {
                    let dParking = getDistMeters(parkedLocation, verts[j])
                    let dRoute = minDistToRouteLine(verts[j], refCoords)
                    let d = dParking + dRoute
                    if (d < bestDist) { bestDist = d; bestPt = verts[j] }
                }
            } else {
                // PRIORITÉ 2 : sommet le plus proche de la route (hors les 30 derniers mètres)
                for (let j = 0; j < verts.length; j++) {
                    let d = minDistToRouteLine(verts[j], refCoords)
                    if (d < bestDist) { bestDist = d; bestPt = verts[j] }
                }
                if (bestDist > 250) return pt
            }

            if (!bestPt) return pt

            // onRoute : sommet ≤ 20m de la route tronquée
            let isOnRoute = minDistToRouteLine(bestPt, refCoords) < 20
            return { id: pt.id, x: bestPt.x, y: bestPt.y, onRoute: isOnRoute, isolated: pt.isolated }
        })

        unvisitedPoints = updated
        if (currentTarget) {
            let refreshed = unvisitedPoints.find(function(p) { return p.id === currentTarget.id })
            if (refreshed) currentTarget = refreshed
        }
        updateOnRouteRenderer()
        updatePolygonCenterRenderer()
        updateArrowRenderer()
        mapCanvas.refresh()
    }
    // --- Chaîne les polygones isolés vers le sommet du voisin le plus proche accessible ---
    // Polygone isolé : tous ses sommets à > 200m de toute route connue.
    // On le rattache à son polygone voisin accessible le plus proche :
    //   → sommet de l'isolé le plus proche du voisin = point d'approche
    //   → OSRM atteindra la zone, le tronçon à pied fera le reste
    function chainIsolatedPoints(rawPoints) {
        let isolated = rawPoints.filter(function(p) { return p.isolated })
        if (isolated.length === 0) return
        let accessible = rawPoints.filter(function(p) { return !p.isolated })
        if (accessible.length === 0) return  // tout est isolé → on ne peut pas chaîner

        for (let i = 0; i < isolated.length; i++) {
            let iso = isolated[i]
            let isoVerts = polygonVertices[iso.id]
            if (!isoVerts || isoVerts.length === 0) continue

            // Trouver le voisin accessible dont un sommet est le plus proche d'un sommet de l'isolé
            let bestNeighborVert = null
            let bestPairDist = 1e9
            let bestIsoVert = null

            for (let j = 0; j < accessible.length; j++) {
                let acc = accessible[j]
                let accVerts = polygonVertices[acc.id]
                let accPts = (accVerts && accVerts.length > 0) ? accVerts : [{ x: acc.x, y: acc.y }]
                for (let v = 0; v < accPts.length; v++) {
                    for (let w = 0; w < isoVerts.length; w++) {
                        let d = getDistMeters(accPts[v], isoVerts[w])
                        if (d < bestPairDist) {
                            bestPairDist = d
                            bestNeighborVert = accPts[v]
                            bestIsoVert = isoVerts[w]
                        }
                    }
                }
            }
            if (!bestIsoVert) continue

            // Mettre à jour la position de navigation de l'isolé vers son point d'approche
            let idx = rawPoints.indexOf(iso)
            if (idx >= 0) {
                rawPoints[idx] = {
                    id: iso.id,
                    x: bestIsoVert.x,
                    y: bestIsoVert.y,
                    onRoute: false,
                    isolated: true,
                    chained: true
                }
            }
        }
    }

    // --- Décide si on doit garer la voiture ici ou continuer en voiture ---
    // Retourne true uniquement si le prochain point nécessite vraiment de marcher :
    //   - aucun point restant n'est onRoute (accessible en voiture)
    //   - ET le point le plus proche est trop loin pour la marche depuis la route
    function shouldParkHere(myPos, remainingPts) {
        if (!remainingPts || remainingPts.length === 0) return false
        let next = getClosestPoint(myPos, remainingPts)
        if (!next) return false
        let pt = next.point

        // Point isolé → toujours se garer et marcher (voiture ne peut pas y aller)
        if (pt.isolated) return true

        // Point sur la route courante à ≤ 30m → se garer et marcher
       // if (pt.onRoute && next.distance <= 30) return true

        // Toutes les autres situations → reprendre la voiture (ne pas créer de parking)
        return false
    }

    // --- Rendu fuschia : centroïdes des points onRoute + centroïde de la cible à pied courante ---
    function updatePolygonCenterRenderer() {
    let empty = GeometryUtils.createGeometryFromWkt("LINESTRING(0 0, 0.000001 0.000001)")
    // Points onRoute sur l'itinéraire
    let candidates = unvisitedPoints.filter(function(p) { return p.onRoute })
    // Ajouter la cible active si on marche vers elle (même si pas onRoute)
    if (navState === "WALKING_TO_POI" && currentTarget &&
        !candidates.find(function(p) { return p.id === currentTarget.id })) {
        candidates = candidates.concat([currentTarget])
    }
    if (candidates.length === 0) {
        if (empty) polygonCenterRenderer.geometryWrapper.qgsGeometry = empty
        return
    }
    let polygons = []
    for (let i = 0; i < candidates.length; i++) {
        let verts = polygonVertices[candidates[i].id]
        if (!verts || verts.length < 3) continue
        // Construire l'anneau extérieur et le fermer si nécessaire
        let ring = verts.map(function(v) { return v.x.toFixed(6) + " " + v.y.toFixed(6) })
        let first = verts[0], last = verts[verts.length - 1]
        if (first.x !== last.x || first.y !== last.y) {
            ring.push(first.x.toFixed(6) + " " + first.y.toFixed(6))
        }
        polygons.push("((" + ring.join(",") + "))")
    }
    if (polygons.length === 0) {
        if (empty) polygonCenterRenderer.geometryWrapper.qgsGeometry = empty
        return
    }
    let wkt = polygons.length === 1
        ? "POLYGON" + polygons[0]
        : "MULTIPOLYGON(" + polygons.join(",") + ")"
    let geom = GeometryUtils.createGeometryFromWkt(wkt)
    if (geom) polygonCenterRenderer.geometryWrapper.qgsGeometry = geom
}

    function updateArrowRenderer() {
    let empty = GeometryUtils.createGeometryFromWkt("LINESTRING(0 0, 0.000001 0.000001)")
    if (empty) arrowRenderer.geometryWrapper.qgsGeometry = empty
}

    // --- 10. DESSIN ---
    function drawDirectLine(start, end, renderer) {
        let wkt = "LINESTRING(" + start.x.toFixed(6) + " " + start.y.toFixed(6) + ", " + end.x.toFixed(6) + " " + end.y.toFixed(6) + ")"
        let geom = GeometryUtils.createGeometryFromWkt(wkt)
        if(geom) renderer.geometryWrapper.qgsGeometry = geom
       // mapCanvas.refresh()
    }

    function drawLineFromCoords(coords, renderer) {
        if (!coords || coords.length < 2) return
        let pts = []
        for (let i = 0; i < coords.length; i++) pts.push(coords[i][0] + " " + coords[i][1])
        let wkt = "LINESTRING(" + pts.join(",") + ")"
        let geom = GeometryUtils.createGeometryFromWkt(wkt)
        if(geom) renderer.geometryWrapper.qgsGeometry = geom
    }

    function clearGeometry(renderer) {
        let empty = GeometryUtils.createGeometryFromWkt("LINESTRING(0 0, 0.000001 0.000001)") 
        if(empty) renderer.geometryWrapper.qgsGeometry = empty
    }

    function trimRouteToCurrentPos(myPos) {
    if (!lastRouteCoords || lastRouteCoords.length < 2) return false
    let minDist = 1e9
    let closestIdx = 0
    for (let i = 0; i < lastRouteCoords.length; i++) {
        let pt = { x: lastRouteCoords[i][0], y: lastRouteCoords[i][1] }
        let d = getDistMeters(myPos, pt)
        if (d < minDist) { minDist = d; closestIdx = i }
    }

    // Auto-parking : si tracé restant < 60m et qu'il y a un tronçon à pied
    if (routeHasFootSegment) {
        let remainingDist = 0
        for (let j = closestIdx; j < lastRouteCoords.length - 1; j++) {
            remainingDist += getDistMeters(
                { x: lastRouteCoords[j][0],   y: lastRouteCoords[j][1] },
                { x: lastRouteCoords[j+1][0], y: lastRouteCoords[j+1][1] }
            )
        }
        if (remainingDist < 10 && navState === "DRIVING") {
            parkedLocation = { x: myPos.x, y: myPos.y }
            currentTarget = pickBestVertex(currentTarget)
            navState = "WALKING_TO_POI"
            routeHasFootSegment = false
            updatePolygonCenterRenderer()
            updateArrowRenderer()
            showHudMessage(tr("Voiture stationnée.\nFinir à pied."))
            return true
        }
    }

    if (closestIdx === 0) return false
    let remaining = lastRouteCoords.slice(closestIdx)
    lastRouteCoords = remaining
    if (remaining.length >= 2) {
        drawLineFromCoords(remaining, carRenderer)
    }
    return true
}
    // --- 11. UTILS ---
    function getCurrentGpsPosition() {
        if (iface.positionSource && iface.positionSource.active) {
            let gpsPt = iface.positionSource.sourcePosition
            if (gpsPt && (gpsPt.x !== 0 || gpsPt.y !== 0)) return { x: gpsPt.x, y: gpsPt.y }
        }
        return null
    }
    
    function getMapCenter() {
        let extent = mapCanvas.mapSettings.extent
        let cx = (extent.xMinimum + extent.xMaximum) / 2
        let cy = (extent.yMinimum + extent.yMaximum) / 2
        let wkt = "POINT(" + cx + " " + cy + ")"
        let g = GeometryUtils.createGeometryFromWkt(wkt)
        if (g) {
            let p = GeometryUtils.centroid(g)
            let w = GeometryUtils.reprojectPointToWgs84(p, mapCanvas.mapSettings.destinationCrs)
            if (w) return { x: w.x, y: w.y }
        }
        return null
    }

    function getDistMeters(pt1, pt2) {
        if (!pt1 || !pt2) return 100000;
        var R = 6371000; 
        var dLat = (pt2.y - pt1.y) * (Math.PI/180);
        var dLon = (pt2.x - pt1.x) * (Math.PI/180); 
        var a = Math.sin(dLat/2) * Math.sin(dLat/2) + Math.cos(pt1.y * (Math.PI/180)) * Math.cos(pt2.y * (Math.PI/180)) * Math.sin(dLon/2) * Math.sin(dLon/2); 
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a)); 
        return R * c; 
    }
}