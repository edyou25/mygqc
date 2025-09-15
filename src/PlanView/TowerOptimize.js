// TowerOptimize.js
// Helper for loading tower locations and optimizing mission waypoints toward nearest tower.
// (Note: .pragma library omitted due to tooling parse issue; QML engine still treats this as a shared JS module.)

var towers = []

function loadTowers(resourceUrl) {
    towers = []
    var url = resourceUrl || 'qrc:/data/towers.json'
    try {
        var xhr = new XMLHttpRequest()
        xhr.open('GET', url)
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 0 || xhr.status === 200) {
                    try {
                        var data = JSON.parse(xhr.responseText)
                        if (data && data.length) {
                            towers = data.map(function(t){
                                return { lat: t.latitude || t.lat, lon: t.longitude || t.lon, name: t.name || '' }
                            })
                            console.log('[TowerOptimize] Loaded towers:', towers.length)
                        }
                    } catch(e) { console.log('[TowerOptimize] parse error', e) }
                } else {
                    console.log('[TowerOptimize] load failed status', xhr.status)
                }
            }
        }
        xhr.send()
    } catch(e) {
        console.log('[TowerOptimize] exception loading towers', e)
    }
}

function optimizeMission(missionController, planMasterController, ratio) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 2) return
    if (!towers.length) {
        console.log('[TowerOptimize] No towers loaded, abort optimize')
        return
    }
    ratio = (ratio === undefined) ? 0.2 : ratio
    for (var i=1; i<visualItems.count; i++) { // skip home/settings item at 0
        var item = visualItems.get(i)
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) {
            continue
        }
        var c = item.coordinate
        if (!c.isValid) continue
        var best=null; var bestd=1e12
        for (var t=0; t<towers.length; t++) {
            var dLat = c.latitude - towers[t].lat
            var dLon = c.longitude - towers[t].lon
            var d2 = dLat*dLat + dLon*dLon
            if (d2 < bestd) { bestd = d2; best = towers[t] }
        }
        if (best) {
            var newLat = c.latitude + (best.lat - c.latitude) * ratio
            var newLon = c.longitude + (best.lon - c.longitude) * ratio
            var newCoord = QtPositioning.coordinate(newLat, newLon, c.altitude)
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
        }
    }
    if (planMasterController) planMasterController.dirty = true
    console.log('[TowerOptimize] optimizeMission applied; ratio=' + ratio)
}

function getTowers() { return towers }

function optimizeMissionRepel(missionController, planMasterController, ratio) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 2) return
    if (!towers.length) {
        console.log('[TowerOptimize] No towers loaded, abort repel optimize')
        return
    }
    ratio = (ratio === undefined) ? 0.2 : ratio
    for (var i=1; i<visualItems.count; i++) {
        var item = visualItems.get(i)
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) {
            continue
        }
        var c = item.coordinate
        if (!c.isValid) continue
        var best=null; var bestd=1e12
        for (var t=0; t<towers.length; t++) {
            var dLat = c.latitude - towers[t].lat
            var dLon = c.longitude - towers[t].lon
            var d2 = dLat*dLat + dLon*dLon
            if (d2 < bestd) { bestd = d2; best = towers[t] }
        }
        if (best) {
            // Move away: invert direction from tower to waypoint
            var newLat = c.latitude + (c.latitude - best.lat) * ratio
            var newLon = c.longitude + (c.longitude - best.lon) * ratio
            var newCoord = QtPositioning.coordinate(newLat, newLon, c.altitude)
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
        }
    }
    if (planMasterController) planMasterController.dirty = true
    console.log('[TowerOptimize] optimizeMissionRepel applied; ratio=' + ratio)
}
