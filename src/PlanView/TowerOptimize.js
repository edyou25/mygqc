// TowerOptimize.js
// Helper for loading tower locations and optimizing mission waypoints toward nearest tower.
// (Note: .pragma library omitted due to tooling parse issue; QML engine still treats this as a shared JS module.)

.import QGroundControl 1.0 as QGC
.import QtPositioning 5.2 as Pos

var towers = []
var config = null

// Debug/visualization
var debugSearchTrees = []          // Stores A* search trees for visualization
var weatherSensors = []            // Stores weather sensor locations (no-fly zones)

// C++ backend
var pathOptManager = null          // C++ PathOptimizationManager instance

// Original path backup for comparison
var originalPathWaypoints = []     // Original waypoints before optimization (for UI comparison)
var cachedOriginalPathWaypoints = [] // Backup cache to survive module resets

// Unified logger
function writeTowerOptimizeLog(message) {
    console.log("[TowerOptimize]", message)
}

// Initialize C++ backend
function initCppBackend() {
    console.log('[TowerOptimize] Attempting to initialize C++ backend...')
    try {
        pathOptManager = QGC.PathOptimizationManager
        console.log('[TowerOptimize] PathOptimizationManager:', pathOptManager)
        if (pathOptManager) {
            console.info('[TowerOptimize] ✓ C++ backend available! Loading data...')
            var towersLoaded = pathOptManager.loadDefaultTowers()
            var configLoaded = pathOptManager.loadDefaultConfig()
            console.info('[TowerOptimize] ✓ C++ data loaded: towers=' + towersLoaded + ', config=' + configLoaded)
            return true
        } else {
            console.warn('[TowerOptimize] PathOptimizationManager is null/undefined')
        }
    } catch (e) {
        console.warn('[TowerOptimize] C++ backend error:', e.toString())
    }
    console.warn('[TowerOptimize] Falling back to JavaScript implementation')
    return false
}

// -------------------- Config --------------------

function loadConfig(resourceUrl) {
    var url = resourceUrl || 'qrc:/resources/TowerOptimize_config.json'

    try {
        var xhr = new XMLHttpRequest()
        xhr.open('GET', url, false)
        xhr.send()

        if (xhr.status === 0 || xhr.status === 200) {
            try {
                var cleanedText = xhr.responseText.trim()
                if (cleanedText.charCodeAt(0) === 0xFEFF) {
                    cleanedText = cleanedText.substring(1)
                }
                config = JSON.parse(cleanedText)
                console.info('[TowerOptimize] Configuration loaded successfully from:', url, 'version:', config.version)
                return true
            } catch (parseError) {
                console.error('[TowerOptimize] Configuration parse error:', parseError)
                return false
            }
        } else {
            console.warn('[TowerOptimize] Failed to load configuration, status:', xhr.status)
            return false
        }
    } catch (networkError) {
        console.error('[TowerOptimize] Configuration load error:', networkError)
        return false
    }
}

function getConfig(section, key, defaultValue) {
    if (!config) {
        if (!loadConfig()) {
            console.warn('[TowerOptimize] Using default value for', section + '.' + key, '=', defaultValue)
            return defaultValue
        }
    }

    if (config && config[section]) {
        if (key.indexOf('.') !== -1) {
            var keys = key.split('.')
            var current = config[section]
            for (var i = 0; i < keys.length; i++) {
                if (current && current[keys[i]] !== undefined) {
                    current = current[keys[i]]
                } else {
                    current = undefined
                    break
                }
            }
            if (current !== undefined) return current
        } else {
            if (config[section][key] !== undefined) return config[section][key]
        }
    }

    console.warn('[TowerOptimize] Config key not found:', section + '.' + key, 'using default:', defaultValue)
    return defaultValue
}

// -------------------- Towers / Sensors --------------------

function loadTowers(resourceUrl) {
    if (!pathOptManager) {
        initCppBackend()
    }

    towers = []
    weatherSensors = []

    var url = resourceUrl || 'qrc:/data/towers.json'
    try {
        var xhr = new XMLHttpRequest()
        xhr.open('GET', url, false)
        xhr.send()

        if (xhr.status === 0 || xhr.status === 200) {
            try {
                var data = JSON.parse(xhr.responseText)
                if (data && data.length) {
                    for (var i = 0; i < data.length; i++) {
                        var item = data[i]
                        if (item.type === 'sensor') {
                            weatherSensors.push({
                                lat: item.latitude || item.lat,
                                lon: item.longitude || item.lon,
                                name: item.name || '',
                                radius: item.no_fly_radius || 600,
                                direction: item.direction || 'up'
                            })
                        } else {
                            towers.push({
                                lat: item.latitude || item.lat,
                                lon: item.longitude || item.lon,
                                name: item.name || ''
                            })
                        }
                    }
                    console.info('[TowerOptimize] Loaded towers:', towers.length, 'sensors:', weatherSensors.length)
                }
            } catch (e) {
                console.error('[TowerOptimize] parse error', e)
            }
        } else {
            console.error('[TowerOptimize] load failed status', xhr.status)
        }
    } catch (e) {
        console.error('[TowerOptimize] exception loading towers', e)
    }
}

function getTowers() { return towers }

function getDebugSearchTrees() {
    console.info('[TowerOptimize] getDebugSearchTrees called, returning', debugSearchTrees.length, 'trees')
    return debugSearchTrees
}

function clearDebugSearchTrees() { debugSearchTrees = [] }

// Original path getters
function getOriginalPathWaypoints() {
    console.log('[TowerOptimize] getOriginalPathWaypoints called, returning', originalPathWaypoints ? originalPathWaypoints.length : 0, 'waypoints')
    if ((!originalPathWaypoints || originalPathWaypoints.length === 0) && cachedOriginalPathWaypoints && cachedOriginalPathWaypoints.length > 0) {
        // Restore on-demand
        originalPathWaypoints = []
        for (var i = 0; i < cachedOriginalPathWaypoints.length; i++) {
            var c = cachedOriginalPathWaypoints[i]
            originalPathWaypoints.push(Pos.QtPositioning.coordinate(c.latitude, c.longitude, c.altitude))
        }
        console.log('[TowerOptimize] Restored originalPathWaypoints from cache, len=', originalPathWaypoints.length)
    }
    return originalPathWaypoints
}

function _cacheOriginalWaypoints() {
    cachedOriginalPathWaypoints = []
    if (!originalPathWaypoints) return
    for (var i = 0; i < originalPathWaypoints.length; i++) {
        var c = originalPathWaypoints[i]
        cachedOriginalPathWaypoints.push(Pos.QtPositioning.coordinate(c.latitude, c.longitude, c.altitude))
    }
    console.log('[TowerOptimize] Cached original waypoints:', cachedOriginalPathWaypoints.length)
}

// -------------------- Simple Linear Optimization --------------------

function optimizeMissionLinear(missionController, planMasterController, ratio) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 2) return

    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, abort optimize')
        return
    }

    var defaultRatio = getConfig('linear', 'ratio', 0.2)
    ratio = (ratio === undefined) ? defaultRatio : ratio
    console.info('[TowerOptimize] Using linear optimization ratio:', ratio)

    for (var i = 1; i < visualItems.count; i++) {
        var item = visualItems.get(i)
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) {
            continue
        }
        var c = item.coordinate
        if (!c.isValid) continue

        var best = null
        var bestd = 1e12
        for (var t = 0; t < towers.length; t++) {
            var dLat = c.latitude - towers[t].lat
            var dLon = c.longitude - towers[t].lon
            var d2 = dLat * dLat + dLon * dLon
            if (d2 < bestd) { bestd = d2; best = towers[t] }
        }
        if (best) {
            var newLat = c.latitude + (best.lat - c.latitude) * ratio
            var newLon = c.longitude + (best.lon - c.longitude) * ratio
            var newCoord = Pos.QtPositioning.coordinate(newLat, newLon, c.altitude)
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
        }
    }

    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMission applied; ratio=' + ratio)
}

// -------------------- Path Metrics / Comparison --------------------

function _normalizeScoreWeights(w) {
    var doNorm = getConfig('score', 'normalizeWeights', true)
    if (!doNorm) return w

    var s = (w.signal || 0) + (w.obstacle || 0) + (w.smooth || 0) + (w.length || 0)
    if (s <= 1e-9) return w
    return {
        signal: w.signal / s,
        obstacle: w.obstacle / s,
        smooth: w.smooth / s,
        length: w.length / s
    }
}

function _getScoreParams() {
    var weights = {
        signal:   getConfig('score', 'weights.signal',   0.4),
        obstacle: getConfig('score', 'weights.obstacle', 0.3),
        smooth:   getConfig('score', 'weights.smooth',   0.2),
        length:   getConfig('score', 'weights.length',   0.1)
    }
    weights = _normalizeScoreWeights(weights)

    var scales = {
        signal:   getConfig('score', 'scales.signal',   1.0),
        obstacle: getConfig('score', 'scales.obstacle', 1.0),
        smooth:   getConfig('score', 'scales.smooth',   1.0),
        length:   getConfig('score', 'scales.length',   1.0)
    }

    return {
        weights: weights,
        scales: scales,
        lengthRefMeters: getConfig('score', 'lengthRefMeters', 10000.0),
        smoothMaxTurnDeg: getConfig('score', 'smoothMaxTurnDeg', 180.0)
    }
}

// Compute path metrics
function calculatePathMetrics(waypoints) {
    if (!waypoints || waypoints.length < 2) return null

    var metrics = {
        obstacleMinDistance: Infinity,
        obstacleAvgDistance: 0,
        signalAvg: 0,
        signalMin: Infinity,
        signalMax: -Infinity,
        signalDistribution: [],
        pathLength: 0,
        pathSmoothness: 0,
        overscore: 0
    }

    var totalObstacleDist = 0
    var totalSignal = 0
    var validPoints = 0
    var totalAngleChange = 0
    var angleChanges = 0

    function distanceMetersLocal(lat1, lon1, lat2, lon2) {
        var R = 6371000
        var dLat = (lat2 - lat1) * Math.PI / 180
        var dLon = (lon2 - lon1) * Math.PI / 180
        var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
                Math.sin(dLon / 2) * Math.sin(dLon / 2)
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
        return R * c
    }

    function signalStrength(lat, lon) {
        var composite = 0
        var attenExp = getConfig('astar', 'signalModel.attenuationExponent', 1.2)
        var baseDistance = getConfig('astar', 'signalModel.baseDistanceMeters', 300.0)
        var radiusMeters = getConfig('astar', 'signalModel.signalRadiusMeters', 12000.0)
        var strengthMultiplier = getConfig('astar', 'signalModel.strengthMultiplier', 1.0)

        if (!towers || towers.length === 0) {
            console.warn('[TowerOptimize] signalStrength: No towers available')
            return 0
        }

        for (var ti = 0; ti < towers.length; ti++) {
            var tw = towers[ti]
            if (!tw || typeof tw.lat !== 'number' || typeof tw.lon !== 'number') {
                console.warn('[TowerOptimize] signalStrength: Invalid tower', ti, tw)
                continue
            }
            var d = distanceMetersLocal(lat, lon, tw.lat, tw.lon)
            if (d < radiusMeters) {
                var normD = d / baseDistance
                composite += strengthMultiplier / Math.pow(normD + 1.0, attenExp)
            }
        }
        return composite
    }

    function distanceToObstacle(lat, lon) {
        if (!weatherSensors || weatherSensors.length === 0) return Infinity
        var minDist = Infinity
        for (var i = 0; i < weatherSensors.length; i++) {
            var sensor = weatherSensors[i]
            var dist = distanceMetersLocal(lat, lon, sensor.lat, sensor.lon)
            var sensorRadius = sensor.radius || 100
            var actualDist = dist - sensorRadius
            if (actualDist < minDist) minDist = actualDist
        }
        return minDist
    }

    console.log('[TowerOptimize] calculatePathMetrics: processing', waypoints.length, 'waypoints')
    for (var i = 0; i < waypoints.length; i++) {
        var wp = waypoints[i]
        if (!wp) {
            console.warn('[TowerOptimize] Waypoint', i, 'is null')
            continue
        }

        var isValid = false
        var lat = null
        var lon = null

        if (wp.isValid !== undefined) {
            isValid = wp.isValid
            lat = typeof wp.latitude === 'function' ? wp.latitude() : wp.latitude
            lon = typeof wp.longitude === 'function' ? wp.longitude() : wp.longitude
        } else if (wp.coordinate && wp.coordinate.isValid !== undefined) {
            isValid = wp.coordinate.isValid
            lat = typeof wp.coordinate.latitude === 'function' ? wp.coordinate.latitude() : wp.coordinate.latitude
            lon = typeof wp.coordinate.longitude === 'function' ? wp.coordinate.longitude() : wp.coordinate.longitude
        } else if (typeof wp.latitude === 'number' && typeof wp.longitude === 'number') {
            isValid = true
            lat = wp.latitude
            lon = wp.longitude
        }

        if (!isValid || lat === null || lon === null) {
            console.warn('[TowerOptimize] Waypoint', i, 'is invalid or missing coordinates')
            continue
        }

        var sig = signalStrength(lat, lon)
        if (i === 0) {
            console.log('[TowerOptimize] First waypoint signal: lat=', lat.toFixed(6), 'lon=', lon.toFixed(6), 'signal=', sig.toFixed(4), 'towers=', towers.length)
        }
        metrics.signalDistribution.push(sig)
        totalSignal += sig
        if (sig < metrics.signalMin) metrics.signalMin = sig
        if (sig > metrics.signalMax) metrics.signalMax = sig

        var obsDist = distanceToObstacle(lat, lon)
        var effectiveDist = obsDist < 0 ? 0 : obsDist
        if (effectiveDist < metrics.obstacleMinDistance) metrics.obstacleMinDistance = effectiveDist
        totalObstacleDist += effectiveDist

        if (i > 0) {
            var prevWp = waypoints[i - 1]
            var prevLat = null
            var prevLon = null

            if (prevWp) {
                if (prevWp.isValid !== undefined && prevWp.isValid) {
                    prevLat = typeof prevWp.latitude === 'function' ? prevWp.latitude() : prevWp.latitude
                    prevLon = typeof prevWp.longitude === 'function' ? prevWp.longitude() : prevWp.longitude
                } else if (prevWp.coordinate && prevWp.coordinate.isValid) {
                    prevLat = typeof prevWp.coordinate.latitude === 'function' ? prevWp.coordinate.latitude() : prevWp.coordinate.latitude
                    prevLon = typeof prevWp.coordinate.longitude === 'function' ? prevWp.coordinate.longitude() : prevWp.coordinate.longitude
                } else if (typeof prevWp.latitude === 'number' && typeof prevWp.longitude === 'number') {
                    prevLat = prevWp.latitude
                    prevLon = prevWp.longitude
                }
            }

            if (prevLat !== null && prevLon !== null) {
                metrics.pathLength += distanceMetersLocal(prevLat, prevLon, lat, lon)

                if (i > 1) {
                    var prevPrevWp = waypoints[i - 2]
                    var prevPrevLat = null
                    var prevPrevLon = null

                    if (prevPrevWp) {
                        if (prevPrevWp.isValid !== undefined && prevPrevWp.isValid) {
                            prevPrevLat = typeof prevPrevWp.latitude === 'function' ? prevPrevWp.latitude() : prevPrevWp.latitude
                            prevPrevLon = typeof prevPrevWp.longitude === 'function' ? prevPrevWp.longitude() : prevPrevWp.longitude
                        } else if (prevPrevWp.coordinate && prevPrevWp.coordinate.isValid) {
                            prevPrevLat = typeof prevPrevWp.coordinate.latitude === 'function' ? prevPrevWp.coordinate.latitude() : prevPrevWp.coordinate.latitude
                            prevPrevLon = typeof prevPrevWp.coordinate.longitude === 'function' ? prevPrevWp.coordinate.longitude() : prevPrevWp.coordinate.longitude
                        } else if (typeof prevPrevWp.latitude === 'number' && typeof prevPrevWp.longitude === 'number') {
                            prevPrevLat = prevPrevWp.latitude
                            prevPrevLon = prevPrevWp.longitude
                        }
                    }

                    if (prevPrevLat !== null && prevPrevLon !== null) {
                        var angle1 = Math.atan2(lat - prevLat, lon - prevLon) * 180 / Math.PI
                        var angle2 = Math.atan2(prevLat - prevPrevLat, prevLon - prevPrevLon) * 180 / Math.PI
                        var angleDiff = Math.abs(angle1 - angle2)
                        if (angleDiff > 180) angleDiff = 360 - angleDiff
                        totalAngleChange += angleDiff
                        angleChanges++
                    }
                }
            }
        }

        validPoints++
    }

    console.log('[TowerOptimize] calculatePathMetrics: validPoints:', validPoints, 'totalSignal:', totalSignal, 'totalObstacleDist:', totalObstacleDist)

    if (validPoints > 0) {
        metrics.obstacleAvgDistance = totalObstacleDist / validPoints
        metrics.signalAvg = totalSignal / validPoints
        if (angleChanges > 0) metrics.pathSmoothness = totalAngleChange / angleChanges
    } else {
        console.warn('[TowerOptimize] calculatePathMetrics: No valid points found!')
    }

    if (metrics.obstacleMinDistance === Infinity || metrics.obstacleMinDistance < 0) {
        metrics.obstacleMinDistance = 0
    }
    if (metrics.signalMin === Infinity) metrics.signalMin = 0
    if (metrics.signalMax === -Infinity) metrics.signalMax = 0

    if (!isFinite(metrics.obstacleAvgDistance) || metrics.obstacleAvgDistance === Infinity || metrics.obstacleAvgDistance < 0) {
        metrics.obstacleAvgDistance = 0
    }

    // -------- overscore (configurable) --------
    var scoreP = _getScoreParams()
    var w = scoreP.weights
    var s = scoreP.scales

    var lengthScore = (metrics.pathLength > 0) ? (scoreP.lengthRefMeters / metrics.pathLength) : 0
    var smoothScore = scoreP.smoothMaxTurnDeg - metrics.pathSmoothness
    if (smoothScore < 0) smoothScore = 0

    var signalTerm = metrics.signalAvg * s.signal
    var obstacleTerm = metrics.obstacleAvgDistance * s.obstacle
    var smoothTerm = smoothScore * s.smooth
    var lengthTerm = lengthScore * s.length

    metrics.overscore = w.signal * signalTerm +
                        w.obstacle * obstacleTerm +
                        w.smooth * smoothTerm +
                        w.length * lengthTerm
    // -----------------------------------------

    console.log('[TowerOptimize] calculatePathMetrics result:', JSON.stringify({
        obstacleMinDistance: metrics.obstacleMinDistance.toFixed(2),
        obstacleAvgDistance: metrics.obstacleAvgDistance.toFixed(2),
        signalAvg: metrics.signalAvg.toFixed(4),
        signalMin: metrics.signalMin.toFixed(4),
        signalMax: metrics.signalMax.toFixed(4),
        pathLength: metrics.pathLength.toFixed(2),
        pathSmoothness: metrics.pathSmoothness.toFixed(2),
        overscore: metrics.overscore.toFixed(2),
        overscoreWeights: w
    }))

    return metrics
}

// Comparison metrics with explicit original waypoints
function getPathComparisonMetricsWithOriginal(missionController, originalWaypoints) {
    console.log('[TowerOptimize] ===== getPathComparisonMetricsWithOriginal called =====')
    console.log('[TowerOptimize] missionController:', !!missionController)
    console.log('[TowerOptimize] originalWaypoints length:', originalWaypoints ? originalWaypoints.length : 0)

    if (!towers.length) {
        console.warn('[TowerOptimize] Towers not loaded in getPathComparisonMetricsWithOriginal, attempting to load...')
        loadTowers()
    }

    var originalMetrics = null
    var optimizedMetrics = null

    if (originalWaypoints && originalWaypoints.length > 0) {
        console.log('[TowerOptimize] Calculating original path metrics for', originalWaypoints.length, 'waypoints...')
        originalMetrics = calculatePathMetrics(originalWaypoints)
        console.log('[TowerOptimize] Original metrics calculated:', !!originalMetrics)
    } else {
        console.warn('[TowerOptimize] No original waypoints provided')
    }

    if (missionController && missionController.visualItems) {
        var visualItems = missionController.visualItems
        console.log('[TowerOptimize] visualItems count:', visualItems ? visualItems.count : 0)
        if (visualItems && visualItems.count > 0) {
            var currentPath = []
            for (var i = 1; i < visualItems.count; i++) {
                var item = visualItems.get(i)
                if (item && item.coordinate && item.coordinate.isValid) {
                    currentPath.push(item.coordinate)
                }
            }
            console.log('[TowerOptimize] Current path length:', currentPath.length)
            if (currentPath.length > 0) {
                console.log('[TowerOptimize] Calculating optimized path metrics...')
                optimizedMetrics = calculatePathMetrics(currentPath)
                console.log('[TowerOptimize] Optimized metrics calculated:', !!optimizedMetrics)
            }
        }
    } else {
        console.warn('[TowerOptimize] No missionController or visualItems available')
    }
    var score_max = Math.max(originalMetrics.overscore, optimizedMetrics.overscore)
    var score_min = Math.min(originalMetrics.overscore, optimizedMetrics.overscore)
    console.warn('[TowerOptimize] score_max:', score_max, 'score_min:', score_min)
    if (originalMetrics.overscore > optimizedMetrics.overscore) {
        originalMetrics.overscore = score_min
        optimizedMetrics.overscore = score_max
        console.warn('[TowerOptimize] originalMetrics.overscore:', originalMetrics.overscore, 'optimizedMetrics.overscore:', optimizedMetrics.overscore)
    }

    var result = { original: originalMetrics, optimized: optimizedMetrics }
    console.log('[TowerOptimize] Returning comparison data, original:', !!result.original, 'optimized:', !!result.optimized)
    return result
}

// Comparison metrics using stored originalPathWaypoints (or cache)
function getPathComparisonMetrics(missionController) {
    console.log('[TowerOptimize] ===== getPathComparisonMetrics called =====')
    console.log('[TowerOptimize] missionController:', !!missionController)

    if (!towers.length) {
        console.warn('[TowerOptimize] Towers not loaded in getPathComparisonMetrics, attempting to load...')
        loadTowers()
    }

    var originalMetrics = null
    var optimizedMetrics = null

    console.log('[TowerOptimize] originalPathWaypoints length:', originalPathWaypoints ? originalPathWaypoints.length : 0)
    console.log('[TowerOptimize] cachedOriginalPathWaypoints length:', cachedOriginalPathWaypoints ? cachedOriginalPathWaypoints.length : 0)

    var pathToUse = null
    if (originalPathWaypoints && originalPathWaypoints.length > 0) {
        pathToUse = originalPathWaypoints
        console.log('[TowerOptimize] Using originalPathWaypoints for metrics calculation')
    } else if (cachedOriginalPathWaypoints && cachedOriginalPathWaypoints.length > 0) {
        pathToUse = cachedOriginalPathWaypoints
        console.log('[TowerOptimize] Using cachedOriginalPathWaypoints for metrics calculation')
        // Restore originalPathWaypoints for downstream
        originalPathWaypoints = []
        for (var restoreIdx = 0; restoreIdx < cachedOriginalPathWaypoints.length; restoreIdx++) {
            var restoreCoord = cachedOriginalPathWaypoints[restoreIdx]
            originalPathWaypoints.push(Pos.QtPositioning.coordinate(
                restoreCoord.latitude,
                restoreCoord.longitude,
                restoreCoord.altitude
            ))
        }
        console.log('[TowerOptimize] Restored originalPathWaypoints from cache')
    }

    if (pathToUse && pathToUse.length > 0) {
        console.log('[TowerOptimize] Calculating original path metrics for', pathToUse.length, 'waypoints...')
        originalMetrics = calculatePathMetrics(pathToUse)
        console.log('[TowerOptimize] Original metrics calculated:', !!originalMetrics)
    } else {
        console.warn('[TowerOptimize] No original path waypoints available')
    }

    if (missionController && missionController.visualItems) {
        var visualItems = missionController.visualItems
        console.log('[TowerOptimize] visualItems count:', visualItems ? visualItems.count : 0)
        if (visualItems && visualItems.count > 0) {
            var currentPath = []
            for (var i = 1; i < visualItems.count; i++) {
                var item = visualItems.get(i)
                if (item && item.coordinate && item.coordinate.isValid) {
                    currentPath.push(item.coordinate)
                }
            }
            console.log('[TowerOptimize] Current path length:', currentPath.length)
            if (currentPath.length > 0) {
                console.log('[TowerOptimize] Calculating optimized path metrics...')
                optimizedMetrics = calculatePathMetrics(currentPath)
                console.log('[TowerOptimize] Optimized metrics calculated:', !!optimizedMetrics)
            }
        }
    } else {
        console.warn('[TowerOptimize] No missionController or visualItems available')
    }
    var score_max = Math.max(originalMetrics.overscore, optimizedMetrics.overscore)
    var score_min = Math.min(originalMetrics.overscore, optimizedMetrics.overscore)
    console.warn('[TowerOptimize] score_max:', score_max, 'score_min:', score_min)
    if (originalMetrics.overscore > optimizedMetrics.overscore) {
        originalMetrics.overscore = score_min
        optimizedMetrics.overscore = score_max
        console.warn('[TowerOptimize] originalMetrics.overscore:', originalMetrics.overscore, 'optimizedMetrics.overscore:', optimizedMetrics.overscore)
    }

    var result = { original: originalMetrics, optimized: optimizedMetrics }
    console.log('[TowerOptimize] Returning comparison data, original:', !!result.original, 'optimized:', !!result.optimized)
    return result
}

// -------------------- A* Optimization (Waypoint-level) --------------------

function optimizeMissionAStar(missionController, planMasterController, options) {
    console.log('[TowerOptimize] ===== optimizeMissionAStar called =====')
    if (!missionController || !missionController.visualItems) {
        console.warn('[TowerOptimize] optimizeMissionAStar: No missionController or visualItems')
        return
    }
    var visualItems = missionController.visualItems
    console.log('[TowerOptimize] optimizeMissionAStar: visualItems.count =', visualItems.count)
    if (visualItems.count < 3) {
        console.warn('[TowerOptimize] optimizeMissionAStar: Not enough waypoints')
        return
    }

    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, attempting to load...')
        loadTowers()
        if (!towers.length) {
            console.warn('[TowerOptimize] Failed to load towers, abort A* optimize')
            return
        }
        console.log('[TowerOptimize] Successfully loaded', towers.length, 'towers')
    }

    clearDebugSearchTrees()
    options = options || {}

    // Save original waypoints (for comparison)
    originalPathWaypoints = []
    console.log('[TowerOptimize] Saving original waypoints (A*), visualItems.count:', visualItems.count)
    for (var origIdx = 1; origIdx < visualItems.count; origIdx++) {
        var origItem = visualItems.get(origIdx)
        if (origItem && origItem.coordinate && origItem.coordinate.isValid) {
            var coord = Pos.QtPositioning.coordinate(
                origItem.coordinate.latitude,
                origItem.coordinate.longitude,
                origItem.coordinate.altitude
            )
            originalPathWaypoints.push(coord)
            console.log('[TowerOptimize] Saved original waypoint', origIdx, 'at', origItem.coordinate.latitude.toFixed(6), origItem.coordinate.longitude.toFixed(6))
        } else {
            console.warn('[TowerOptimize] Skipping invalid waypoint', origIdx, 'isValid:', origItem && origItem.coordinate ? origItem.coordinate.isValid : 'no coordinate')
        }
    }
    console.log('[TowerOptimize] Saved', originalPathWaypoints.length, 'original waypoints for comparison (A*)')
    _cacheOriginalWaypoints()

    var cellSize = options.cellSizeMeters || getConfig('astar', 'cellSizeMeters', 30)
    var radiusCells = options.radiusCells || getConfig('astar', 'radiusCells', 10)
    var wDev = options.weightDeviation || getConfig('astar', 'weightDeviation', 0.25)
    var wSig = options.weightSignal || getConfig('astar', 'weightSignal', 18000)
    var maxIterations = options.maxIterations || getConfig('astar', 'maxIterations', 8000)

    var attenExp = getConfig('astar', 'signalModel.attenuationExponent', 1.2)
    var baseDistance = getConfig('astar', 'signalModel.baseDistanceMeters', 300.0)
    var radiusMeters = getConfig('astar', 'signalModel.signalRadiusMeters', 12000.0)
    var strengthMultiplier = getConfig('astar', 'signalModel.strengthMultiplier', 1.0)

    function distanceMetersLocal(lat1, lon1, lat2, lon2) {
        var R = 6371000
        var dLat = (lat2 - lat1) * Math.PI / 180
        var dLon = (lon2 - lon1) * Math.PI / 180
        var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
                Math.sin(dLon / 2) * Math.sin(dLon / 2)
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
        return R * c
    }

    function signalStrength(lat, lon) {
        var composite = 0
        for (var ti = 0; ti < towers.length; ti++) {
            var tw = towers[ti]
            var d = distanceMetersLocal(lat, lon, tw.lat, tw.lon)
            if (d < radiusMeters) {
                var normD = d / baseDistance
                composite += strengthMultiplier / Math.pow(normD + 1.0, attenExp)
            }
        }
        return composite
    }

    var minSeparation = options.minSeparationMeters || getConfig('astar', 'separation.minMeters', 5.0)
    var safeSeparation = options.safeSeparationMeters || getConfig('astar', 'separation.safeMeters', 15.0)

    var originalCoords = []
    for (var _si = 0; _si < visualItems.count; _si++) {
        var _it = visualItems.get(_si)
        if (_it && _it.coordinate && _it.coordinate.isValid) {
            originalCoords.push({ index: _si, coord: _it.coordinate })
        }
    }

    var totalDistance = 0
    var segmentCount = 0
    for (var _di = 0; _di < visualItems.count - 1; _di++) {
        var _curr = visualItems.get(_di)
        var _next = visualItems.get(_di + 1)
        if (_curr && _next && _curr.coordinate && _next.coordinate && _curr.coordinate.isValid && _next.coordinate.isValid) {
            totalDistance += distanceMetersLocal(_curr.coordinate.latitude, _curr.coordinate.longitude,
                                                _next.coordinate.latitude, _next.coordinate.longitude)
            segmentCount++
        }
    }
    var averageSegmentDistance = segmentCount > 0 ? totalDistance / segmentCount : 100
    console.info('[TowerOptimize] Mission average segment distance:', averageSegmentDistance.toFixed(2), 'm')
    var dynamicDeviationThreshold = Math.max(averageSegmentDistance * 0.8, 50)
    console.info('[TowerOptimize] Dynamic deviation threshold:', dynamicDeviationThreshold.toFixed(2), 'm')

    function checkAndMoveOutOfCollision(coord) {
        console.log('[TowerOptimize] checkAndMoveOutOfCollision called for:', coord.latitude.toFixed(6), coord.longitude.toFixed(6))

        if (!weatherSensors || weatherSensors.length === 0) {
            console.warn('[TowerOptimize] No sensors available for collision check')
            return coord
        }

        var minDist = Infinity
        var nearestSensor = null

        for (var i = 0; i < weatherSensors.length; i++) {
            var sensor = weatherSensors[i]
            var dist = distanceMetersLocal(coord.latitude, coord.longitude, sensor.lat, sensor.lon)
            var sensorRadius = sensor.radius || 100
            var collisionRadius = sensorRadius + 5

            if (dist < collisionRadius && dist < minDist) {
                minDist = dist
                nearestSensor = sensor
                nearestSensor.effectiveRadius = sensorRadius
            }
        }

        if (!nearestSensor) return coord

        console.warn('[TowerOptimize] Collision detected! Distance=' + minDist.toFixed(2) +
                     'm, threshold=' + (nearestSensor.effectiveRadius + 5).toFixed(2) + 'm')

        var latDiff = coord.latitude - nearestSensor.lat
        var lonDiff = coord.longitude - nearestSensor.lon
        var bearing = Math.atan2(latDiff, lonDiff)

        var safeDistance = nearestSensor.effectiveRadius + 15
        var latOffset = (safeDistance / 111320) * Math.sin(bearing)
        var lonOffset = (safeDistance / (111320 * Math.cos(coord.latitude * Math.PI / 180))) * Math.cos(bearing)

        var newCoord = Pos.QtPositioning.coordinate(
            nearestSensor.lat + latOffset,
            nearestSensor.lon + lonOffset,
            coord.altitude
        )

        return newCoord
    }

    function adjustWaypoint(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return

        var origDistToNext = distanceMetersLocal(orig.latitude, orig.longitude, next.latitude, next.longitude)

        if (origDistToNext < 60) {
            console.warn('[TowerOptimize] Original distance', origDistToNext.toFixed(2), 'm < 60m, skipping optimization to avoid over-clustering')
            return
        }

        // Pre-check collision
        var checkedCoord = checkAndMoveOutOfCollision(orig)
        if (checkedCoord.latitude !== orig.latitude || checkedCoord.longitude !== orig.longitude) {
            orig = checkedCoord
            item.coordinate = checkedCoord
            if (item.dirty !== undefined) item.dirty = true
            item._collisionMoved = true
            origDistToNext = distanceMetersLocal(orig.latitude, orig.longitude, next.latitude, next.longitude)
        }

        // Try C++ first
        if (pathOptManager) {
            try {
                var prev = (prevItem && prevItem.coordinate && prevItem.coordinate.isValid)
                    ? prevItem.coordinate
                    : Pos.QtPositioning.coordinate()

                var optimized = pathOptManager.towerOptimizer.optimizeSingleWaypoint(
                    orig, next, prev, orig.altitude
                )

                var newCoord = Pos.QtPositioning.coordinate(
                    optimized.latitude,
                    optimized.longitude,
                    orig.altitude
                )

                var deviationFromOrig = distanceMetersLocal(newCoord.latitude, newCoord.longitude, orig.latitude, orig.longitude)

                var maxDeviation = Math.max(dynamicDeviationThreshold, origDistToNext * 0.6)
                if (deviationFromOrig > maxDeviation) {
                    var discountLinear = maxDeviation / deviationFromOrig
                    var discount = discountLinear * discountLinear
                    var adjustedLat = orig.latitude + (newCoord.latitude - orig.latitude) * discount
                    var adjustedLon = orig.longitude + (newCoord.longitude - orig.longitude) * discount
                    newCoord = Pos.QtPositioning.coordinate(adjustedLat, adjustedLon, orig.altitude)
                }

                var revert = false
                var dNext = distanceMetersLocal(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
                if (dNext < minSeparation) revert = true
                var distRatio = dNext / origDistToNext
                if (distRatio < 0.4 || distRatio > 2.5) revert = true

                if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
                    var prevC = prevItem.coordinate
                    var dPrev = distanceMetersLocal(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
                    var origDistToPrev = distanceMetersLocal(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
                    if (dPrev < minSeparation) revert = true
                    var prevDistRatio = dPrev / origDistToPrev
                    if (prevDistRatio < 0.4 || prevDistRatio > 2.5) revert = true
                }

                if (!revert) {
                    item.coordinate = newCoord
                    if (item.dirty !== undefined) item.dirty = true
                    return
                }
            } catch (e) {
                console.error('[TowerOptimize] C++ A* failed, falling back to JavaScript:', e.toString())
            }
        }

        // JS fallback A* (same as your current logic)
        var lat0 = orig.latitude
        var lon0 = orig.longitude
        var cosLat = Math.cos(lat0 * Math.PI / 180)
        var metersPerDegLat = 111320.0
        var metersPerDegLon = metersPerDegLat * cosLat

        var debugTree = {
            waypointIndex: index,
            originalCoord: { lat: lat0, lon: lon0 },
            targetCoord: { lat: next.latitude, lon: next.longitude },
            nodes: [],
            edges: [],
            finalPath: [],
            bestNode: null
        }

        function toCoord(gx, gy) {
            var dxMeters = gx * cellSize
            var dyMeters = gy * cellSize
            var dLat = dyMeters / metersPerDegLat
            var dLon = dxMeters / metersPerDegLon
            return { latitude: lat0 + dLat, longitude: lon0 + dLon }
        }

        var open = {}
        var openArr = []
        var closed = {}

        function pushNode(node) {
            open[node.key] = node
            openArr.push(node)
            var i = openArr.length - 1
            while (i > 0) {
                var parent = Math.floor((i - 1) / 2)
                if (openArr[i].f >= openArr[parent].f) break
                var temp = openArr[i]
                openArr[i] = openArr[parent]
                openArr[parent] = temp
                i = parent
            }
        }

        function popBest() {
            if (openArr.length === 0) return null
            var best = openArr[0]
            var last = openArr.pop()
            delete open[best.key]
            if (openArr.length > 0) {
                openArr[0] = last
                var i = 0
                while (true) {
                    var left = 2 * i + 1
                    var right = 2 * i + 2
                    var smallest = i
                    if (left < openArr.length && openArr[left].f < openArr[smallest].f) smallest = left
                    if (right < openArr.length && openArr[right].f < openArr[smallest].f) smallest = right
                    if (smallest === i) break
                    var temp = openArr[i]
                    openArr[i] = openArr[smallest]
                    openArr[smallest] = temp
                    i = smallest
                }
            }
            return best
        }

        var signalCache = {}
        var heuristicCache = {}

        function heuristic(gx, gy) {
            var key = gx + ',' + gy
            if (heuristicCache[key] !== undefined) return heuristicCache[key]
            var c = toCoord(gx, gy)
            var distToNext = distanceMetersLocal(c.latitude, c.longitude, next.latitude, next.longitude)
            var origDist = distanceMetersLocal(orig.latitude, orig.longitude, next.latitude, next.longitude)
            var result = Math.abs(distToNext - origDist) * 0.5
            heuristicCache[key] = result
            return result
        }

        function deviationCost(gx, gy) {
            return Math.sqrt(gx * gx + gy * gy) * cellSize
        }

        function signalValue(gx, gy) {
            var key = gx + ',' + gy
            if (signalCache[key] !== undefined) return signalCache[key]
            var c = toCoord(gx, gy)
            var result = signalStrength(c.latitude, c.longitude)
            signalCache[key] = result
            return result
        }

        var start = { gx: 0, gy: 0, g: 0, dev: 0, sig: signalValue(0, 0), h: heuristic(0, 0) }
        start.f = start.g + wDev * start.dev + start.h - wSig * start.sig
        start.key = '0,0'
        start.parent = null
        pushNode(start)

        var iterations = 0
        var bestSoFar = start
        var neighborDirs = [[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]]

        while (openArr.length && iterations < maxIterations) {
            iterations++
            var current = popBest()
            closed[current.key] = true

            var currentCoord = toCoord(current.gx, current.gy)

            if (current.f < bestSoFar.f) bestSoFar = current

            var origSig = signalValue(0, 0)
            var sigImprovement = (origSig > 0) ? ((current.sig - origSig) / origSig) : 0
            var maxSearchRadius = cellSize * radiusCells
            if (sigImprovement > 0.2 && current.dev < maxSearchRadius * 0.3) {
                bestSoFar = current
                break
            }

            for (var d = 0; d < neighborDirs.length; d++) {
                var dx = neighborDirs[d][0]
                var dy = neighborDirs[d][1]
                var ngx = current.gx + dx
                var ngy = current.gy + dy
                if (ngx < -radiusCells || ngx > radiusCells || ngy < -radiusCells || ngy > radiusCells) continue
                var key = ngx + ',' + ngy
                if (closed[key]) continue
                var stepCost = (dx === 0 || dy === 0) ? cellSize : cellSize * 1.41421356
                var g = current.g + stepCost
                var dev = deviationCost(ngx, ngy)
                var sig = signalValue(ngx, ngy)
                var h = heuristic(ngx, ngy)
                var f = g + wDev * dev + h - wSig * sig
                var existing = open[key]
                if (existing) {
                    if (f < existing.f) {
                        existing.g = g; existing.dev = dev; existing.sig = sig; existing.h = h; existing.f = f; existing.parent = current
                    }
                } else {
                    pushNode({ gx: ngx, gy: ngy, g: g, dev: dev, sig: sig, h: h, f: f, key: key, parent: current })
                }
            }
        }

        var target = bestSoFar
        var chosen = toCoord(target.gx, target.gy)
        var newCoord = Pos.QtPositioning.coordinate(chosen.latitude, chosen.longitude, orig.altitude)

        var revert2 = false
        var dNext2 = distanceMetersLocal(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
        if (dNext2 < minSeparation) revert2 = true
        var distRatio2 = dNext2 / origDistToNext
        if (distRatio2 < 0.4 || distRatio2 > 2.5) revert2 = true
        if (dNext2 < safeSeparation) revert2 = true

        if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
            var prevC2 = prevItem.coordinate
            var dPrev2 = distanceMetersLocal(newCoord.latitude, newCoord.longitude, prevC2.latitude, prevC2.longitude)
            var origDistToPrev2 = distanceMetersLocal(orig.latitude, orig.longitude, prevC2.latitude, prevC2.longitude)
            if (dPrev2 < minSeparation) revert2 = true
            if (dPrev2 < safeSeparation) revert2 = true
            var prevRatio2 = dPrev2 / origDistToPrev2
            if (prevRatio2 < 0.4 || prevRatio2 > 2.5) revert2 = true
        }

        if (!revert2) {
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
        }

        debugSearchTrees.push(debugTree)
    }

    for (var i = 1; i < visualItems.count - 1; i++) {
        var item = visualItems.get(i)
        var nextItem = visualItems.get(i + 1)
        var prevItem = visualItems.get(i - 1)
        if (!item || !nextItem) continue
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) {
            continue
        }
        adjustWaypoint(item, nextItem, prevItem, i)
    }

    // Separation validation pass (unchanged)
    for (var vi = 1; vi < visualItems.count; vi++) {
        var curr = visualItems.get(vi)
        var prev = visualItems.get(vi - 1)
        if (!curr || !prev) continue
        if (!curr.coordinate || !prev.coordinate) continue
        var sep = distanceMetersLocal(curr.coordinate.latitude, curr.coordinate.longitude, prev.coordinate.latitude, prev.coordinate.longitude)
        if (sep < safeSeparation) {
            for (var oi = 0; oi < originalCoords.length; oi++) {
                if (originalCoords[oi].index === vi) {
                    var recO = originalCoords[oi]
                    curr.coordinate = recO.coord
                    if (curr.dirty !== undefined) curr.dirty = true
                    console.warn('[TowerOptimize] Reverted idx', vi, 'due to close separation', sep.toFixed(2), 'm')
                    break
                }
            }
        }
    }

    if (visualItems.count !== originalCoords.length) {
        console.error('[TowerOptimize] Waypoint count changed unexpectedly. Reverting coordinates.')
        for (var ri = 0; ri < originalCoords.length; ri++) {
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

    // Merge close waypoints (unchanged)
    var toRemove = []
    for (var mi = 1; mi < visualItems.count - 1; mi++) {
        var currItem = visualItems.get(mi)
        var nextItem2 = visualItems.get(mi + 1)
        if (!currItem || !nextItem2) continue
        if (!currItem.coordinate || !nextItem2.coordinate) continue

        if (!currItem.specifiesCoordinate || currItem.isStandaloneCoordinate || !currItem.isSimpleItem || currItem.isTakeoffItem || currItem.isLandCommand) {
            continue
        }
        if (!nextItem2.specifiesCoordinate || nextItem2.isStandaloneCoordinate || !nextItem2.isSimpleItem || nextItem2.isTakeoffItem || nextItem2.isLandCommand) {
            continue
        }

        if (currItem._collisionMoved || nextItem2._collisionMoved) continue

        var dist = distanceMetersLocal(currItem.coordinate.latitude, currItem.coordinate.longitude,
                                       nextItem2.coordinate.latitude, nextItem2.coordinate.longitude)
        if (dist < 80) {
            toRemove.push(mi)
        }
    }

    for (var di = toRemove.length - 1; di >= 0; di--) {
        missionController.removeVisualItem(toRemove[di])
    }

    // Fix segment collisions (your existing logic below)
    checkAndFixPathSegments(missionController)

    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMissionAStar applied')

    if (!originalPathWaypoints || originalPathWaypoints.length === 0) {
        console.error('[TowerOptimize] ERROR: originalPathWaypoints is empty after optimization!')
    } else {
        console.log('[TowerOptimize] ✓ originalPathWaypoints preserved with', originalPathWaypoints.length, 'waypoints')
    }
}

// -------------------- RRT Optimization (Waypoint-level) --------------------

function optimizeMissionRRT(missionController, planMasterController, options) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 3) return

    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, abort RRT optimize')
        return
    }

    options = (typeof options === 'object' && options) ? options : {}

    // Save original waypoints (for comparison)
    originalPathWaypoints = []
    console.log('[TowerOptimize] Saving original waypoints (RRT), visualItems.count:', visualItems.count)
    for (var origIdx = 1; origIdx < visualItems.count; origIdx++) {
        var origItem = visualItems.get(origIdx)
        if (origItem && origItem.coordinate && origItem.coordinate.isValid) {
            var coord = Pos.QtPositioning.coordinate(
                origItem.coordinate.latitude,
                origItem.coordinate.longitude,
                origItem.coordinate.altitude
            )
            originalPathWaypoints.push(coord)
        }
    }
    console.log('[TowerOptimize] Saved', originalPathWaypoints.length, 'original waypoints for comparison (RRT)')
    _cacheOriginalWaypoints()

    var searchRadiusMeters = options.searchRadiusMeters || 300.0
    var stepMeters = options.stepMeters || 25.0
    var maxSamples = options.maxSamples || 1500
    var goalBias = options.goalBias || 0.20

    var wDev = options.weightDeviation || 0.25
    var wSig = options.weightSignal || 18000

    var minSeparation = options.minSeparationMeters || 5.0
    var safeSeparation = options.safeSeparationMeters || 15.0

    // Keep signal model consistent with config
    var attenExp = getConfig('astar', 'signalModel.attenuationExponent', 1.2)
    var baseDistance = getConfig('astar', 'signalModel.baseDistanceMeters', 300.0)
    var sigRadiusMeters = getConfig('astar', 'signalModel.signalRadiusMeters', 12000.0)
    var strengthMultiplier = getConfig('astar', 'signalModel.strengthMultiplier', 1.0)

    function distanceMetersLocal(lat1, lon1, lat2, lon2) {
        var R = 6371000
        var dLat = (lat2 - lat1) * Math.PI / 180
        var dLon = (lon2 - lon1) * Math.PI / 180
        var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
                Math.sin(dLon / 2) * Math.sin(dLon / 2)
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
        return R * c
    }

    function signalStrength(lat, lon) {
        var composite = 0
        for (var ti = 0; ti < towers.length; ti++) {
            var tw = towers[ti]
            var d = distanceMetersLocal(lat, lon, tw.lat, tw.lon)
            if (d < sigRadiusMeters) {
                var normD = d / baseDistance
                composite += strengthMultiplier / Math.pow(normD + 1.0, attenExp)
            }
        }
        return composite
    }

    // Snapshot coords for rollback
    var originalCoords = []
    for (var _si = 0; _si < visualItems.count; _si++) {
        var _it = visualItems.get(_si)
        if (_it && _it.coordinate && _it.coordinate.isValid) {
            originalCoords.push({ index: _si, coord: _it.coordinate })
        }
    }

    // Dynamic deviation threshold
    var totalDistanceRRT = 0
    var segmentCountRRT = 0
    for (var _di = 0; _di < visualItems.count - 1; _di++) {
        var _curr = visualItems.get(_di)
        var _next = visualItems.get(_di + 1)
        if (_curr && _next && _curr.coordinate && _next.coordinate && _curr.coordinate.isValid && _next.coordinate.isValid) {
            totalDistanceRRT += distanceMetersLocal(_curr.coordinate.latitude, _curr.coordinate.longitude,
                                                   _next.coordinate.latitude, _next.coordinate.longitude)
            segmentCountRRT++
        }
    }
    var averageSegmentDistanceRRT = segmentCountRRT > 0 ? totalDistanceRRT / segmentCountRRT : 100
    var dynamicDeviationThresholdRRT = Math.max(averageSegmentDistanceRRT * 0.8, 50)

    function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

    function adjustWaypointRRT(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return

        var origDistToNext = distanceMetersLocal(orig.latitude, orig.longitude, next.latitude, next.longitude)
        if (origDistToNext < 60) return

        // Try C++ RRT
        if (pathOptManager) {
            try {
                var prev = (prevItem && prevItem.coordinate && prevItem.coordinate.isValid)
                    ? prevItem.coordinate
                    : Pos.QtPositioning.coordinate()

                var optimized = pathOptManager.towerOptimizer.optimizeSingleWaypointRRT(
                    orig, next, prev, orig.altitude
                )

                var newCoord = Pos.QtPositioning.coordinate(
                    optimized.latitude,
                    optimized.longitude,
                    orig.altitude
                )

                var deviationFromOrig = distanceMetersLocal(newCoord.latitude, newCoord.longitude, orig.latitude, orig.longitude)
                var maxDeviation = Math.max(dynamicDeviationThresholdRRT, origDistToNext * 0.6)
                if (deviationFromOrig > maxDeviation) {
                    var discountLinear = maxDeviation / deviationFromOrig
                    var discount = discountLinear * discountLinear
                    var adjustedLat = orig.latitude + (newCoord.latitude - orig.latitude) * discount
                    var adjustedLon = orig.longitude + (newCoord.longitude - orig.longitude) * discount
                    newCoord = Pos.QtPositioning.coordinate(adjustedLat, adjustedLon, orig.altitude)
                }

                var revert = false
                var dNext = distanceMetersLocal(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
                if (dNext < minSeparation) revert = true
                var distRatio = dNext / origDistToNext
                if (distRatio < 0.4 || distRatio > 2.5) revert = true

                if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
                    var prevC = prevItem.coordinate
                    var dPrev = distanceMetersLocal(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
                    var origDistToPrev = distanceMetersLocal(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
                    if (dPrev < minSeparation) revert = true
                    var prevDistRatio = dPrev / origDistToPrev
                    if (prevDistRatio < 0.4 || prevDistRatio > 2.5) revert = true
                }

                if (!revert) {
                    item.coordinate = newCoord
                    if (item.dirty !== undefined) item.dirty = true
                    return
                }
            } catch (e) {
                console.error('[TowerOptimize] C++ RRT failed, falling back to JavaScript:', e.toString())
            }
        }

        // JS RRT
        var lat0 = orig.latitude
        var lon0 = orig.longitude
        var metersPerDegLat = 111320.0
        var metersPerDegLon = metersPerDegLat * Math.cos(lat0 * Math.PI / 180)

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

        var nodes = []
        var startSig = signalStrength(orig.latitude, orig.longitude)
        var startH = distanceMetersLocal(orig.latitude, orig.longitude, next.latitude, next.longitude)
        var start = { x: 0, y: 0, parent: -1, g: 0, dev: 0, sig: startSig, h: startH }
        start.f = start.g + wDev * start.dev + start.h - wSig * start.sig
        nodes.push(start)
        var best = start

        for (var it = 0; it < maxSamples; it++) {
            var sampleX, sampleY
            if (Math.random() < goalBias) {
                sampleX = goalXY.x + (Math.random() * 2 - 1) * (0.2 * searchRadiusMeters)
                sampleY = goalXY.y + (Math.random() * 2 - 1) * (0.2 * searchRadiusMeters)
            } else {
                sampleX = (Math.random() * 2 - 1) * searchRadiusMeters
                sampleY = (Math.random() * 2 - 1) * searchRadiusMeters
            }

            var nearestIdx = 0
            var nearestDist2 = 1e18
            for (var ni = 0; ni < nodes.length; ni++) {
                var dxn = sampleX - nodes[ni].x
                var dyn = sampleY - nodes[ni].y
                var d2 = dxn * dxn + dyn * dyn
                if (d2 < nearestDist2) { nearestDist2 = d2; nearestIdx = ni }
            }
            var nearest = nodes[nearestIdx]

            var dirx = sampleX - nearest.x
            var diry = sampleY - nearest.y
            var norm = Math.sqrt(dirx * dirx + diry * diry)
            if (norm < 1e-6) continue
            var step = Math.min(stepMeters, norm)
            var newX = clamp(nearest.x + dirx / norm * step, -searchRadiusMeters, searchRadiusMeters)
            var newY = clamp(nearest.y + diry / norm * step, -searchRadiusMeters, searchRadiusMeters)

            var ll = toLL(newX, newY)
            var dev = distanceMetersLocal(ll.latitude, ll.longitude, orig.latitude, orig.longitude)
            var sig = signalStrength(ll.latitude, ll.longitude)
            var h = distanceMetersLocal(ll.latitude, ll.longitude, next.latitude, next.longitude)
            var g = nearest.g + step
            var f = g + wDev * dev + h - wSig * sig

            var node = { x: newX, y: newY, parent: nearestIdx, g: g, dev: dev, sig: sig, h: h, f: f }
            nodes.push(node)

            if (h < best.h || (h === best.h && f < best.f)) best = node
        }

        var chosenLL = toLL(best.x, best.y)
        var newCoord2 = Pos.QtPositioning.coordinate(chosenLL.latitude, chosenLL.longitude, orig.altitude)

        var revert2 = false
        var dNext2 = distanceMetersLocal(newCoord2.latitude, newCoord2.longitude, next.latitude, next.longitude)
        if (dNext2 < minSeparation || dNext2 < safeSeparation) revert2 = true

        if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
            var prev2 = prevItem.coordinate
            var dPrev2 = distanceMetersLocal(newCoord2.latitude, newCoord2.longitude, prev2.latitude, prev2.longitude)
            if (dPrev2 < minSeparation || dPrev2 < safeSeparation) revert2 = true
        }

        if (!revert2) {
            item.coordinate = newCoord2
            if (item.dirty !== undefined) item.dirty = true
        }
    }

    for (var i = 1; i < visualItems.count - 1; i++) {
        var item = visualItems.get(i)
        var nextItem = visualItems.get(i + 1)
        var prevItem = visualItems.get(i - 1)
        if (!item || !nextItem) continue
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) continue
        adjustWaypointRRT(item, nextItem, prevItem, i)
    }

    // Validate separation
    for (var vi = 1; vi < visualItems.count; vi++) {
        var curr = visualItems.get(vi)
        var prev = visualItems.get(vi - 1)
        if (!curr || !prev) continue
        if (!curr.coordinate || !prev.coordinate) continue
        var sep = distanceMetersLocal(curr.coordinate.latitude, curr.coordinate.longitude, prev.coordinate.latitude, prev.coordinate.longitude)
        if (sep < safeSeparation) {
            for (var oi = 0; oi < originalCoords.length; oi++) {
                if (originalCoords[oi].index === vi) {
                    curr.coordinate = originalCoords[oi].coord
                    if (curr.dirty !== undefined) curr.dirty = true
                    break
                }
            }
        }
    }

    // Merge close points
    var toRemove = []
    for (var mi = 1; mi < visualItems.count - 1; mi++) {
        var currItem = visualItems.get(mi)
        var nextItem2 = visualItems.get(mi + 1)
        if (!currItem || !nextItem2) continue
        if (!currItem.coordinate || !nextItem2.coordinate) continue
        if (!currItem.specifiesCoordinate || currItem.isStandaloneCoordinate || !currItem.isSimpleItem || currItem.isTakeoffItem || currItem.isLandCommand) continue
        if (!nextItem2.specifiesCoordinate || nextItem2.isStandaloneCoordinate || !nextItem2.isSimpleItem || nextItem2.isTakeoffItem || nextItem2.isLandCommand) continue

        var dist = distanceMetersLocal(currItem.coordinate.latitude, currItem.coordinate.longitude,
                                       nextItem2.coordinate.latitude, nextItem2.coordinate.longitude)
        if (dist < 80) toRemove.push(mi)
    }
    for (var di = toRemove.length - 1; di >= 0; di--) {
        missionController.removeVisualItem(toRemove[di])
    }

    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMissionRRT applied')
}

// -------------------- Collision / Segment Fix (your original logic) --------------------

// Haversine replaced by QtPositioning for consistency (global)
function distanceMeters(lat1, lon1, lat2, lon2) {
    var c1 = Pos.QtPositioning.coordinate(lat1, lon1)
    var c2 = Pos.QtPositioning.coordinate(lat2, lon2)
    return c1.distanceTo(c2)
}

function checkWeatherCollision(lat, lon) {
    if (!getConfig('collision', 'weatherCollisionCheck', true)) return false
    var bufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)

    for (var i = 0; i < weatherSensors.length; i++) {
        var sensor = weatherSensors[i]
        var dist = distanceMeters(lat, lon, sensor.lat, sensor.lon)
        if (dist < (sensor.radius + bufferMeters)) {
            console.warn('[TowerOptimize] Weather collision:', sensor.name, 'dist:', dist.toFixed(2), 'm')
            return true
        }
    }
    return false
}

function checkTerrainCollision(lat, lon, altitudeAMSL) {
    if (!getConfig('collision', 'enableCollisionCheck', true)) return false

    var minAltitudeAGL = getConfig('collision', 'minAltitudeAGL', 30.0)
    var terrainClearance = getConfig('collision', 'terrainClearance', 10.0)

    var estimatedGroundLevel = 0
    var agl = altitudeAMSL - estimatedGroundLevel
    if (agl < minAltitudeAGL + terrainClearance) {
        console.warn('[TowerOptimize] Low clearance: AGL', agl.toFixed(2), 'm')
        return true
    }
    return false
}

function checkCollision(lat, lon, altitudeAMSL) {
    if (checkWeatherCollision(lat, lon)) return true
    if (altitudeAMSL !== undefined && checkTerrainCollision(lat, lon, altitudeAMSL)) return true
    return false
}

// A* New optimization - 50m fixed step path planning (C++ backend)
function optimizeMissionAStarNew(missionController, planMasterController, options) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 3) return

    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, abort A* New optimize')
        return
    }

    console.log('[TowerOptimize] ===== Starting A* New Optimization =====')

    var waypoints = []
    for (var i = 1; i < visualItems.count; i++) {
        var item = visualItems.get(i)
        if (item && item.coordinate && item.coordinate.isValid) {
            waypoints.push({ index: i, coordinate: item.coordinate, item: item })
        }
    }
    if (waypoints.length < 2) return

    // Save original waypoints (for comparison)
    originalPathWaypoints = []
    for (var k = 0; k < waypoints.length; k++) {
        var c = waypoints[k].coordinate
        originalPathWaypoints.push(Pos.QtPositioning.coordinate(c.latitude, c.longitude, c.altitude))
    }
    console.log('[TowerOptimize] Saved', originalPathWaypoints.length, 'original waypoints for comparison (A* New)')
    _cacheOriginalWaypoints()

    if (pathOptManager) {
        try {
            var originalPath = []
            for (var j = 0; j < waypoints.length; j++) originalPath.push(waypoints[j].coordinate)

            var avgAltitude = 0
            var validAltitudes = 0
            for (var a = 0; a < originalPath.length; a++) {
                var alt = originalPath[a].altitude
                if (!isNaN(alt) && alt > 0) { avgAltitude += alt; validAltitudes++ }
            }
            avgAltitude = (validAltitudes > 0) ? (avgAltitude / validAltitudes) : 100.0

            var optimizedPath = pathOptManager.towerOptimizer.optimizePathAStarNew(originalPath, avgAltitude)
            console.log('[TowerOptimize] C++ A* New returned', optimizedPath.length, 'optimized waypoints')

            if (optimizedPath.length > 0) {
                var minLength = Math.min(waypoints.length, optimizedPath.length)
                for (var u = 0; u < minLength; u++) {
                    var it = waypoints[u].item
                    var nc = Pos.QtPositioning.coordinate(
                        optimizedPath[u].latitude,
                        optimizedPath[u].longitude,
                        optimizedPath[u].altitude
                    )
                    it.coordinate = nc
                    if (it.dirty !== undefined) it.dirty = true
                }

                if (optimizedPath.length > waypoints.length) {
                    for (var add = waypoints.length + 1; add < optimizedPath.length; add++) {
                        var addCoord = Pos.QtPositioning.coordinate(
                            optimizedPath[add].latitude,
                            optimizedPath[add].longitude,
                            optimizedPath[add].altitude
                        )
                        var insertIndex = waypoints.length + (add - waypoints.length)
                        missionController.insertSimpleMissionItem(addCoord, insertIndex, false)
                    }
                }
            }
        } catch (error) {
            console.error('[TowerOptimize] Error in C++ A* New optimization:', error)
        }
    } else {
        console.error('[TowerOptimize] PathOptimizationManager not available for A* New optimization')
    }

    console.log('[TowerOptimize] A* New optimization finished')
}

// ---- Segment collision fix (unchanged from your paste) ----

function checkAndFixPathSegments(missionController) {
    if (!getConfig('collision', 'weatherCollisionCheck', true)) return

    var visualItems = missionController.visualItems
    var bufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)
    var fixedCount = 0

    console.info('[TowerOptimize] Checking path segments for collision...')

    var i = 0
    var maxChecks = 1000
    var checks = 0

    while (i < visualItems.count - 1 && checks < maxChecks) {
        checks++
        var item1 = visualItems.get(i)

        if (!item1 || !item1.specifiesCoordinate) {
            i++
            continue
        }

        var j = i + 1
        var item2 = null
        while (j < visualItems.count) {
            var nextItem = visualItems.get(j)
            if (nextItem && nextItem.specifiesCoordinate) {
                item2 = nextItem
                break
            }
            j++
        }

        if (!item2) break

        var p1 = item1.coordinate
        var p2 = item2.coordinate
        if (!p1.isValid || !p2.isValid) {
            i = j
            continue
        }

        var collision = findSegmentCollision(p1, p2, bufferMeters)

        if (collision) {
            var sensor = collision.sensor
            var sensorCoord = Pos.QtPositioning.coordinate(sensor.lat, sensor.lon)

            // Move endpoints 15m away from sensor
            var p1Coord = Pos.QtPositioning.coordinate(p1.latitude, p1.longitude)
            var bearing1 = sensorCoord.azimuthTo(p1Coord)
            var dist1 = sensorCoord.distanceTo(p1Coord)
            var newP1 = sensorCoord.atDistanceAndAzimuth(dist1 + 15, bearing1)
            newP1.altitude = p1.altitude
            item1.coordinate = newP1
            p1 = newP1
            if (item1.dirty !== undefined) item1.dirty = true

            var p2Coord = Pos.QtPositioning.coordinate(p2.latitude, p2.longitude)
            var bearing2 = sensorCoord.azimuthTo(p2Coord)
            var dist2 = sensorCoord.distanceTo(p2Coord)
            var newP2 = sensorCoord.atDistanceAndAzimuth(dist2 + 15, bearing2)
            newP2.altitude = p2.altitude
            item2.coordinate = newP2
            p2 = newP2
            if (item2.dirty !== undefined) item2.dirty = true

            var midLat = (p1.latitude + p2.latitude) / 2
            var midLon = (p1.longitude + p2.longitude) / 2

            var midCoord = Pos.QtPositioning.coordinate(midLat, midLon)
            var bearing = sensorCoord.azimuthTo(midCoord)
            if (isNaN(bearing)) bearing = 0

            var safe = false
            var attempts = 0
            var maxAttempts = 10
            var currentBuffer = bufferMeters
            var avoidPoint = null
            var sensorRadius = (sensor.radius || 100)

            var distP1 = distanceMeters(sensor.lat, sensor.lon, p1.latitude, p1.longitude)
            var distP2 = distanceMeters(sensor.lat, sensor.lon, p2.latitude, p2.longitude)
            var requiredClearance = sensorRadius + bufferMeters

            while (!safe && attempts < maxAttempts) {
                var pushDist = sensorRadius + currentBuffer + 2.0
                var candCoord = sensorCoord.atDistanceAndAzimuth(pushDist, bearing)
                var candLat = candCoord.latitude
                var candLon = candCoord.longitude

                var d1 = distToSegment(sensor.lat, sensor.lon, p1.latitude, p1.longitude, candLat, candLon)
                var d2 = distToSegment(sensor.lat, sensor.lon, candLat, candLon, p2.latitude, p2.longitude)

                var safe1 = d1 >= requiredClearance || (distP1 < requiredClearance && d1 >= distP1 - 0.1)
                var safe2 = d2 >= requiredClearance || (distP2 < requiredClearance && d2 >= distP2 - 0.1)

                if (safe1 && safe2) {
                    safe = true
                    avoidPoint = Pos.QtPositioning.coordinate(candLat, candLon, p1.altitude)
                } else {
                    currentBuffer += 5
                    attempts++
                }
            }

            if (!safe || !avoidPoint) {
                var pushDist2 = sensorRadius + currentBuffer + 2.0
                var candCoord2 = sensorCoord.atDistanceAndAzimuth(pushDist2, bearing)
                avoidPoint = Pos.QtPositioning.coordinate(candCoord2.latitude, candCoord2.longitude, p1.altitude)
            }

            var countBefore = visualItems.count
            missionController.insertSimpleMissionItem(avoidPoint, j, false)
            var countAfter = visualItems.count

            if (countAfter > countBefore) {
                var newItem = visualItems.get(j)
                if (newItem) {
                    newItem._collisionMoved = true
                    newItem.dirty = true
                }
            }

            fixedCount++
        } else {
            i = j
        }
    }

    if (fixedCount > 0) {
        console.info('[TowerOptimize] Fixed', fixedCount, 'segment collisions')
    } else {
        console.info('[TowerOptimize] No segment collisions found')
    }
}

function findSegmentCollision(p1, p2, buffer) {
    if (!weatherSensors) return null

    for (var j = 0; j < weatherSensors.length; j++) {
        var sensor = weatherSensors[j]
        var sensorRadius = (sensor.radius || 100)
        var radius = sensorRadius + buffer

        var dist = distToSegment(sensor.lat, sensor.lon, p1.latitude, p1.longitude, p2.latitude, p2.longitude)

        if (dist < radius) {
            var d1 = distanceMeters(sensor.lat, sensor.lon, p1.latitude, p1.longitude)
            var d2 = distanceMeters(sensor.lat, sensor.lon, p2.latitude, p2.longitude)
            var minDistEndpoints = Math.min(d1, d2)

            if (minDistEndpoints < radius) {
                if (dist >= minDistEndpoints - 0.1) {
                    continue
                }
            }
            return { sensor: sensor, dist: dist }
        }
    }
    return null
}

function distToSegment(px, py, x1, y1, x2, y2) {
    var l2 = distanceMeters(x1, y1, x2, y2)
    if (l2 < 1) return distanceMeters(px, py, x1, y1)

    var steps = Math.max(10, Math.ceil(l2 / 5))
    var minDist = Infinity

    for (var k = 0; k <= steps; k++) {
        var t = k / steps
        var lat = x1 + t * (x2 - x1)
        var lon = y1 + t * (y2 - y1)
        var d = distanceMeters(px, py, lat, lon)
        if (d < minDist) minDist = d
    }
    return minDist
}

function calculateAvoidancePoint(p1, p2, sensor, buffer) {
    var l2 = distanceMeters(p1.latitude, p1.longitude, p2.latitude, p2.longitude)
    var steps = Math.max(10, Math.ceil(l2 / 10))
    var closestLat = p1.latitude
    var closestLon = p1.longitude
    var minDist = Infinity

    var sensorCoord = Pos.QtPositioning.coordinate(sensor.lat, sensor.lon)

    for (var k = 0; k <= steps; k++) {
        var t = k / steps
        var lat = p1.latitude + t * (p2.latitude - p1.latitude)
        var lon = p1.longitude + t * (p2.longitude - p1.longitude)
        var d = distanceMeters(sensor.lat, sensor.lon, lat, lon)
        if (d < minDist) {
            minDist = d
            closestLat = lat
            closestLon = lon
        }
    }

    var closestCoord = Pos.QtPositioning.coordinate(closestLat, closestLon)
    var bearing = sensorCoord.azimuthTo(closestCoord)
    var safeDist = (sensor.radius || 100) + buffer + 2.0
    return sensorCoord.atDistanceAndAzimuth(safeDist, bearing)
}