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

// A* based adjustment: For each eligible waypoint (excluding last), perform grid search
// to find a new coordinate balancing: (1) stay close to original waypoint, (2) be closer
// to next waypoint (progress), (3) maximize signal strength from towers.
// Movement: 8-direction (N,S,E,W, diagonals). Cost function (to minimize):
//    f = gMove + wDev*distOriginal + hNext - wSig*signalStrength
// where hNext is Euclidean to next waypoint, signalStrength uses inverse-power model.
// Weights chosen empirically and can be tuned.
function optimizeMissionRepel(missionController, planMasterController, options) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 3) return
    if (!towers.length) {
        console.log('[TowerOptimize] No towers loaded, abort A* optimize')
        return
    }
    options = options || {}
    var cellSize = options.cellSizeMeters || 30            // grid cell size in meters
    var radiusCells = options.radiusCells || 10            // search radius (square) => (2*radiusCells+1)^2 nodes max
    var wDev = options.weightDeviation || 0.25             // penalty weight for distance from original waypoint
    var wSig = options.weightSignal || 18000                // reward weight for signal strength
    var maxIterations = options.maxIterations || 8000

    // Signal model parameters (align with heatmap layer for consistency)
    var attenExp = 1.2
    var baseDistance = 300.0
    var radiusMeters = 12000.0
    var strengthMultiplier = 1.0

    function distanceMeters(lat1, lon1, lat2, lon2) {
        var R = 6371000
        var dLat = (lat2-lat1) * Math.PI/180
        var dLon = (lon2-lon1) * Math.PI/180
        var a = Math.sin(dLat/2)*Math.sin(dLat/2) + Math.cos(lat1*Math.PI/180)*Math.cos(lat2*Math.PI/180)*Math.sin(dLon/2)*Math.sin(dLon/2)
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
        return R * c
    }

    function signalStrength(lat, lon) {
        var composite = 0
        for (var ti=0; ti<towers.length; ti++) {
            var tw = towers[ti]
            var d = distanceMeters(lat, lon, tw.lat, tw.lon)
            if (d < radiusMeters) {
                var normD = d / baseDistance
                composite += strengthMultiplier / Math.pow(normD + 1.0, attenExp)
            }
        }
        return composite
    }

    // Minimum separation (meters) to prevent collapsing two adjacent waypoints into effectively one
    var minSeparation = options.minSeparationMeters || 5.0          // basic revert threshold
    var safeSeparation = options.safeSeparationMeters || 15.0        // stronger spacing to avoid downstream merge logic

    // Snapshot original coordinates to allow revert if something unexpected changes count
    var originalCoords = []
    for (var _si=0; _si<visualItems.count; _si++) {
        var _it = visualItems.get(_si)
        if (_it && _it.coordinate && _it.coordinate.isValid) {
            originalCoords.push({ index:_si, coord:_it.coordinate })
        }
    }

    function logItem(prefix, idx, itm) {
        try {
            if (!itm || !itm.coordinate) return
            console.log('[TowerOptimize]', prefix, 'idx', idx, 'lat', itm.coordinate.latitude, 'lon', itm.coordinate.longitude)
        } catch(e) {}
    }

    function adjustWaypoint(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return
        var lat0 = orig.latitude
        var lon0 = orig.longitude
        var cosLat = Math.cos(lat0 * Math.PI/180)
        var metersPerDegLat = 111320.0
        var metersPerDegLon = metersPerDegLat * cosLat

        function toCoord(gx, gy) { // grid offset in cells
            var dxMeters = gx * cellSize
            var dyMeters = gy * cellSize
            var dLat = dyMeters / metersPerDegLat
            var dLon = dxMeters / metersPerDegLon
            return { latitude: lat0 + dLat, longitude: lon0 + dLon }
        }

        function goalGridOffsets() { // approximate grid location of next waypoint (clamped to radius)
            var dLatMeters = (next.latitude - lat0) * metersPerDegLat
            var dLonMeters = (next.longitude - lon0) * metersPerDegLon
            var gx = Math.round(dLonMeters / cellSize)
            var gy = Math.round(dLatMeters / cellSize)
            if (gx > radiusCells) gx = radiusCells; else if (gx < -radiusCells) gx = -radiusCells
            if (gy > radiusCells) gy = radiusCells; else if (gy < -radiusCells) gy = -radiusCells
            return { gx: gx, gy: gy }
        }

        var goal = goalGridOffsets()
        var goalKey = goal.gx + ',' + goal.gy
        var open = {}
        var openArr = []
        var closed = {}
        function pushNode(node) { open[node.key] = node; openArr.push(node) }
        function popBest() {
            var bestIndex = 0; var bestF = openArr[0].f
            for (var i=1;i<openArr.length;i++) { if (openArr[i].f < bestF) { bestF = openArr[i].f; bestIndex=i } }
            var n = openArr.splice(bestIndex,1)[0]
            delete open[n.key]
            return n
        }
        function heuristic(gx, gy) {
            var c = toCoord(gx, gy)
            return distanceMeters(c.latitude, c.longitude, next.latitude, next.longitude)
        }
        function deviationCost(gx, gy) {
            var c = toCoord(gx, gy)
            return distanceMeters(c.latitude, c.longitude, orig.latitude, orig.longitude)
        }
        function signalValue(gx, gy) {
            var c = toCoord(gx, gy)
            return signalStrength(c.latitude, c.longitude)
        }

        var start = { gx:0, gy:0, g:0, dev:0, sig: signalValue(0,0), h: heuristic(0,0) }
        start.f = start.g + wDev*start.dev + start.h - wSig*start.sig
        start.key = '0,0'
        start.parent = null
        pushNode(start)
        var iterations = 0
        var bestSoFar = start
        var neighborDirs = [
            [1,0],[ -1,0],[0,1],[0,-1], [1,1],[1,-1],[-1,1],[-1,-1]
        ]
        while (openArr.length && iterations < maxIterations) {
            iterations++
            var current = popBest()
            closed[current.key] = true
            // Track best (lowest f) node that is closer to next
            if (current.h < bestSoFar.h || (current.h === bestSoFar.h && current.f < bestSoFar.f)) {
                bestSoFar = current
            }
            if (current.key === goalKey) { bestSoFar = current; break }
            for (var d=0; d<neighborDirs.length; d++) {
                var dx = neighborDirs[d][0]
                var dy = neighborDirs[d][1]
                var ngx = current.gx + dx
                var ngy = current.gy + dy
                if (ngx < -radiusCells || ngx > radiusCells || ngy < -radiusCells || ngy > radiusCells) continue
                var key = ngx + ',' + ngy
                if (closed[key]) continue
                var stepCost = (dx===0 || dy===0) ? cellSize : cellSize * 1.41421356
                var g = current.g + stepCost
                var dev = deviationCost(ngx, ngy)
                var sig = signalValue(ngx, ngy)
                var h = heuristic(ngx, ngy)
                var f = g + wDev*dev + h - wSig*sig
                var existing = open[key]
                if (existing) {
                    if (f < existing.f) {
                        existing.g = g; existing.dev = dev; existing.sig = sig; existing.h = h; existing.f = f; existing.parent = current
                    }
                } else {
                    pushNode({ gx:ngx, gy:ngy, g:g, dev:dev, sig:sig, h:h, f:f, key:key, parent: current })
                }
            }
        }
        // Choose bestSoFar path end node.
        var target = bestSoFar
        var chosen = toCoord(target.gx, target.gy)
        var newCoord = QtPositioning.coordinate(chosen.latitude, chosen.longitude, orig.altitude)
        // Separation checks
        var revert = false
        var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
        if (dNext < minSeparation) revert = true
        if (dNext < safeSeparation) {
            // Too close to next, likely to trigger merge elsewhere
            revert = true
        }
        if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
            var prevC = prevItem.coordinate
            var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
            if (dPrev < minSeparation) revert = true
            if (dPrev < safeSeparation) revert = true
        }
        if (!revert) {
            logItem('BEFORE', index, item)
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
            logItem('AFTER', index, item)
        } else {
            // Keep original (no move)
            logItem('SKIP', index, item)
        }
    }

    for (var i=1; i<visualItems.count-1; i++) { // skip first and last
        var item = visualItems.get(i)
        var nextItem = visualItems.get(i+1)
        var prevItem = visualItems.get(i-1)
        if (!item || !nextItem) continue
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) continue
        adjustWaypoint(item, nextItem, prevItem, i)
    }
    // Additional spacing validation pass; revert any violations using snapshot
    for (var vi=1; vi<visualItems.count; vi++) {
        var curr = visualItems.get(vi)
        var prev = visualItems.get(vi-1)
        if (!curr || !prev) continue
        if (!curr.coordinate || !prev.coordinate) continue
        var sep = distanceMeters(curr.coordinate.latitude, curr.coordinate.longitude, prev.coordinate.latitude, prev.coordinate.longitude)
        if (sep < safeSeparation) {
            // revert current to original snapshot
            for (var oi=0; oi<originalCoords.length; oi++) {
                if (originalCoords[oi].index === vi) {
                    var recO = originalCoords[oi]
                    curr.coordinate = recO.coord
                    if (curr.dirty !== undefined) curr.dirty = true
                    console.log('[TowerOptimize] Reverted idx', vi, 'due to close separation', sep.toFixed(2),'m')
                    break
                }
            }
        }
    }
    // Post-condition: ensure count unchanged
    if (visualItems.count !== originalCoords.length) {
        console.log('[TowerOptimize] Waypoint count changed unexpectedly. Reverting coordinates.')
        for (var ri=0; ri<originalCoords.length; ri++) {
            var rec = originalCoords[ri]
            if (rec.index < visualItems.count) {
                var itm = visualItems.get(rec.index)
                if (itm && itm.coordinate && itm.coordinate.isValid) {
                    itm.coordinate = rec.coord
                    if (itm.dirty !== undefined) itm.dirty = true
                }
            }
        }
    }
    if (planMasterController) planMasterController.dirty = true
    console.log('[TowerOptimize] optimizeMissionRepel A* applied')
}
