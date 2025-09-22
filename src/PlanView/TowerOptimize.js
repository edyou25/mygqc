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

function optimizeMissionLinear(missionController, planMasterController, ratio) {
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
function optimizeMissionAStar(missionController, planMasterController, options) {
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
    console.log('[TowerOptimize] optimizeMissionAStar A* applied')
}

// ...existing code...

function optimizeMissionRRT(missionController, planMasterController, options) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 3) return
    if (!towers.length) {
        console.log('[TowerOptimize] No towers loaded, abort RRT optimize')
        return
    }

    // 兼容传入数字的老调用方式（例如 0.2）
    options = (typeof options === 'object' && options) ? options : {}

    // RRT 参数
    var searchRadiusMeters     = options.searchRadiusMeters     || 300.0   // 局部搜索半径
    var stepMeters             = options.stepMeters             || 25.0    // 每次扩展步长
    var maxSamples             = options.maxSamples             || 1500    // 采样次数
    var goalBias               = options.goalBias               || 0.20    // 采样朝向下一点的概率

    // 代价权重（与 A* 保持一致的意义）
    var wDev = options.weightDeviation || 0.25
    var wSig = options.weightSignal    || 18000

    // 最小间距保护，确保不与相邻点“合并”
    var minSeparation   = options.minSeparationMeters || 5.0
    var safeSeparation  = options.safeSeparationMeters || 15.0

    // 信号模型（与热力层 / A* 对齐）
    var attenExp          = 1.2
    var baseDistance      = 300.0
    var sigRadiusMeters   = 12000.0
    var strengthMultiplier= 1.0

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
            if (d < sigRadiusMeters) {
                var normD = d / baseDistance
                composite += strengthMultiplier / Math.pow(normD + 1.0, attenExp)
            }
        }
        return composite
    }

    function logItem(prefix, idx, itm) {
        try {
            if (!itm || !itm.coordinate) return
            console.log('[TowerOptimize]', prefix, 'idx', idx, 'lat', itm.coordinate.latitude, 'lon', itm.coordinate.longitude)
        } catch(e) {}
    }

    // 快照坐标，必要时回滚
    var originalCoords = []
    for (var _si=0; _si<visualItems.count; _si++) {
        var _it = visualItems.get(_si)
        if (_it && _it.coordinate && _it.coordinate.isValid) {
            originalCoords.push({ index:_si, coord:_it.coordinate })
        }
    }

    function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

    function adjustWaypointRRT(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return

        var lat0 = orig.latitude
        var lon0 = orig.longitude
        var metersPerDegLat = 111320.0
        var metersPerDegLon = metersPerDegLat * Math.cos(lat0 * Math.PI/180)

        function toLL(x, y) {
            var lat = lat0 + (y / metersPerDegLat)
            var lon = lon0 + (x / metersPerDegLon)
            return { latitude: lat, longitude: lon }
        }
        function toXY(lat, lon) {
            var y = (lat - lat0) * metersPerDegLat
            var x = (lon - lon0) * metersPerDegLon
            return { x: x, y: y }
        }

        var goalXY = toXY(next.latitude, next.longitude)

        // RRT 节点：x,y（米为单位，原点在 orig）；g 为路径累积代价（距离）
        var nodes = []
        var startLat = orig.latitude
        var startLon = orig.longitude
        var startSig = signalStrength(startLat, startLon)
        var startH   = distanceMeters(startLat, startLon, next.latitude, next.longitude)
        var startDev = 0
        var start = { x:0, y:0, parent:-1, g:0, dev:startDev, sig:startSig, h:startH }
        start.f = start.g + wDev*start.dev + start.h - wSig*start.sig
        nodes.push(start)
        var best = start

        for (var it=0; it<maxSamples; it++) {
            // 采样
            var sampleX, sampleY
            if (Math.random() < goalBias) {
                // 朝向下一点采样，可加少量噪声
                sampleX = goalXY.x + (Math.random()*2 - 1) * (0.2 * searchRadiusMeters)
                sampleY = goalXY.y + (Math.random()*2 - 1) * (0.2 * searchRadiusMeters)
            } else {
                sampleX = (Math.random()*2 - 1) * searchRadiusMeters
                sampleY = (Math.random()*2 - 1) * searchRadiusMeters
            }

            // 找最近节点
            var nearestIdx = 0
            var nearestDist2 = 1e18
            for (var ni=0; ni<nodes.length; ni++) {
                var dxn = sampleX - nodes[ni].x
                var dyn = sampleY - nodes[ni].y
                var d2  = dxn*dxn + dyn*dyn
                if (d2 < nearestDist2) { nearestDist2 = d2; nearestIdx = ni }
            }
            var nearest = nodes[nearestIdx]

            // 沿着方向前进一步（stepMeters）
            var dirx = sampleX - nearest.x
            var diry = sampleY - nearest.y
            var norm = Math.sqrt(dirx*dirx + diry*diry)
            if (norm < 1e-6) continue
            var step = Math.min(stepMeters, norm)
            var newX = nearest.x + dirx / norm * step
            var newY = nearest.y + diry / norm * step
            newX = clamp(newX, -searchRadiusMeters, searchRadiusMeters)
            newY = clamp(newY, -searchRadiusMeters, searchRadiusMeters)

            // 评价新节点
            var ll = toLL(newX, newY)
            var dev = distanceMeters(ll.latitude, ll.longitude, orig.latitude, orig.longitude)
            var sig = signalStrength(ll.latitude, ll.longitude)
            var h   = distanceMeters(ll.latitude, ll.longitude, next.latitude, next.longitude)
            var g   = nearest.g + step
            var f   = g + wDev*dev + h - wSig*sig

            var node = { x:newX, y:newY, parent: nearestIdx, g:g, dev:dev, sig:sig, h:h, f:f }
            nodes.push(node)

            // 选择更优
            if (h < best.h || (h === best.h && f < best.f)) {
                best = node
            }
        }

        var chosenLL = toLL(best.x, best.y)
        var newCoord = QtPositioning.coordinate(chosenLL.latitude, chosenLL.longitude, orig.altitude)

        // 与前后点的最小间距保护
        var revert = false
        var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
        if (dNext < minSeparation || dNext < safeSeparation) revert = true

        if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
            var prev = prevItem.coordinate
            var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prev.latitude, prev.longitude)
            if (dPrev < minSeparation || dPrev < safeSeparation) revert = true
        }

        if (!revert) {
            logItem('BEFORE', index, item)
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
            logItem('AFTER', index, item)
        } else {
            logItem('SKIP', index, item)
        }
    }

    // 逐个中间点本地 RRT 优化
    for (var i=1; i<visualItems.count-1; i++) {
        var item = visualItems.get(i)
        var nextItem = visualItems.get(i+1)
        var prevItem = visualItems.get(i-1)
        if (!item || !nextItem) continue
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) continue
        adjustWaypointRRT(item, nextItem, prevItem, i)
    }

    // 二次全局间距验证，不满足则回滚该点
    for (var vi=1; vi<visualItems.count; vi++) {
        var curr = visualItems.get(vi)
        var prev = visualItems.get(vi-1)
        if (!curr || !prev) continue
        if (!curr.coordinate || !prev.coordinate) continue
        var sep = distanceMeters(curr.coordinate.latitude, curr.coordinate.longitude, prev.coordinate.latitude, prev.coordinate.longitude)
        if (sep < safeSeparation) {
            for (var oi=0; oi<originalCoords.length; oi++) {
                if (originalCoords[oi].index === vi) {
                    var recO = originalCoords[oi]
                    curr.coordinate = recO.coord
                    if (curr.dirty !== undefined) curr.dirty = true
                    console.log('[TowerOptimize][RRT] Reverted idx', vi, 'due to close separation', sep.toFixed(2),'m')
                    break
                }
            }
        }
    }

    // 数量检查（理论不会变化）
    if (visualItems.count !== originalCoords.length) {
        console.log('[TowerOptimize][RRT] Waypoint count changed unexpectedly. Reverting coordinates.')
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
    console.log('[TowerOptimize] optimizeMissionRRT applied')
}

// ...existing code...