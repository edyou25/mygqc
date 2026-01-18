// TowerOptimize.js
// Helper for loading tower locations and optimizing mission waypoints toward nearest tower.
// (Note: .pragma library omitted due to tooling parse issue; QML engine still treats this as a shared JS module.)

.import QGroundControl 1.0 as QGC
.import QtPositioning 5.2 as Pos

var towers = []
var config = null
var debugSearchTrees = [] // 存储A*搜索树用于可视化
var weatherSensors = []   // 存储天气传感器位置（禁飞区）
var pathOptManager = null // C++ PathOptimizationManager 实例
var originalPathWaypoints = [] // 存储优化前的原始路径点，用于对比显示

// JavaScript日志函数 - 统一通过C++处理
function writeTowerOptimizeLog(message) {
    console.log("[TowerOptimize]", message);
}

// 初始化C++后端
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
    } catch(e) {
        console.warn('[TowerOptimize] C++ backend error:', e.toString())
    }
    console.warn('[TowerOptimize] Falling back to JavaScript implementation')
    return false
}

// 配置管理函数
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
            } catch(parseError) {
                console.error('[TowerOptimize] Configuration parse error:', parseError)
                return false
            }
        } else {
            console.warn('[TowerOptimize] Failed to load configuration, status:', xhr.status)
            return false
        }
    } catch(networkError) {
        console.error('[TowerOptimize] Configuration load error:', networkError)
        return false
    }
}

function getConfig(section, key, defaultValue) {
    // 自动加载配置（如果还没有加载）
    if (!config) {
        if (!loadConfig()) {
            console.warn('[TowerOptimize] Using default value for', section + '.' + key, '=', defaultValue)
            return defaultValue
        }
    }
    
    if (config && config[section]) {
        // 支持嵌套键名（如 'signalModel.attenuationExponent'）
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
            if (current !== undefined) {
                return current
            }
        } else {
            // 简单键名
            if (config[section][key] !== undefined) {
                return config[section][key]
            }
        }
    }
    
    console.warn('[TowerOptimize] Config key not found:', section + '.' + key, 'using default:', defaultValue)
    return defaultValue
}

function loadTowers(resourceUrl) {
    // 尝试初始化C++后端（会加载C++侧的数据）
    if (!pathOptManager) {
        initCppBackend()
    }
    
    // 无论是否有C++后端，都加载JavaScript侧的数据
    // JavaScript的signalStrength会用这些数据
    towers = []
    var url = resourceUrl || 'qrc:/data/towers.json'
    try {
        var xhr = new XMLHttpRequest()
        xhr.open('GET', url, false)  // 同步加载！
        xhr.send()
        
        if (xhr.status === 0 || xhr.status === 200) {
            try {
                var data = JSON.parse(xhr.responseText)
                if (data && data.length) {
                    weatherSensors = []
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
            } catch(e) { 
                console.error('[TowerOptimize] parse error', e) 
            }
        } else {
            console.error('[TowerOptimize] load failed status', xhr.status)
        }
    } catch(e) {
        console.error('[TowerOptimize] exception loading towers', e)
    }
}

function optimizeMissionLinear(missionController, planMasterController, ratio) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 2) return
    
    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, abort optimize')
        return
    }
    // 从配置文件读取默认比例
    var defaultRatio = getConfig('linear', 'ratio', 0.2)
    ratio = (ratio === undefined) ? defaultRatio : ratio
    console.info('[TowerOptimize] Using linear optimization ratio:', ratio)
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
            var newCoord = Pos.QtPositioning.coordinate(newLat, newLon, c.altitude)
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
        }
    }
    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMission applied; ratio=' + ratio)
}

function getTowers() { return towers }

function getDebugSearchTrees() { 
    console.info('[TowerOptimize] getDebugSearchTrees called, returning', debugSearchTrees.length, 'trees')
    return debugSearchTrees 
}

function clearDebugSearchTrees() { debugSearchTrees = [] }

// 获取原始路径点，用于对比显示
function getOriginalPathWaypoints() {
    console.log('[TowerOptimize] getOriginalPathWaypoints called, returning', originalPathWaypoints ? originalPathWaypoints.length : 0, 'waypoints')
    console.log('[TowerOptimize] originalPathWaypoints in getOriginalPathWaypoints:', originalPathWaypoints)
    return originalPathWaypoints
}

// 存储原始路径点的备份（用于对比指标计算）
var cachedOriginalPathWaypoints = []

// 计算路径指标
function calculatePathMetrics(waypoints) {
    if (!waypoints || waypoints.length < 2) {
        return null
    }
    
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
        var attenExp = getConfig('astar', 'signalModel.attenuationExponent', 1.2)
        var baseDistance = getConfig('astar', 'signalModel.baseDistanceMeters', 300.0)
        var radiusMeters = getConfig('astar', 'signalModel.signalRadiusMeters', 12000.0)
        var strengthMultiplier = getConfig('astar', 'signalModel.strengthMultiplier', 1.0)
        
        if (!towers || towers.length === 0) {
            console.warn('[TowerOptimize] signalStrength: No towers available')
            return 0
        }
        
        for (var ti=0; ti<towers.length; ti++) {
            var tw = towers[ti]
            if (!tw || typeof tw.lat !== 'number' || typeof tw.lon !== 'number') {
                console.warn('[TowerOptimize] signalStrength: Invalid tower', ti, tw)
                continue
            }
            var d = distanceMeters(lat, lon, tw.lat, tw.lon)
            if (d < radiusMeters) {
                var normD = d / baseDistance
                composite += strengthMultiplier / Math.pow(normD + 1.0, attenExp)
            }
        }
        return composite
    }
    
    function distanceToObstacle(lat, lon) {
        if (!weatherSensors || weatherSensors.length === 0) {
            return Infinity
        }
        var minDist = Infinity
        for (var i = 0; i < weatherSensors.length; i++) {
            var sensor = weatherSensors[i]
            var dist = distanceMeters(lat, lon, sensor.lat, sensor.lon)
            var sensorRadius = sensor.radius || 100
            var actualDist = dist - sensorRadius
            if (actualDist < minDist) {
                minDist = actualDist
            }
        }
        return minDist
    }
    
    // 计算路径长度和信号强度
    console.log('[TowerOptimize] calculatePathMetrics: processing', waypoints.length, 'waypoints')
    for (var i = 0; i < waypoints.length; i++) {
        var wp = waypoints[i]
        if (!wp) {
            console.warn('[TowerOptimize] Waypoint', i, 'is null')
            continue
        }
        
        // 检查坐标有效性 - 支持多种坐标对象格式
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
            // 直接是坐标值
            isValid = true
            lat = wp.latitude
            lon = wp.longitude
        }
        
        if (!isValid || lat === null || lon === null) {
            console.warn('[TowerOptimize] Waypoint', i, 'is invalid or missing coordinates')
            continue
        }
        
        // 计算信号强度
        var sig = signalStrength(lat, lon)
        if (i === 0) {
            console.log('[TowerOptimize] First waypoint signal calculation: lat=', lat.toFixed(6), 'lon=', lon.toFixed(6), 'signal=', sig.toFixed(4), 'towers=', towers.length)
        }
        metrics.signalDistribution.push(sig)
        totalSignal += sig
        if (sig < metrics.signalMin) metrics.signalMin = sig
        if (sig > metrics.signalMax) metrics.signalMax = sig
        
        // 计算障碍物距离
        var obsDist = distanceToObstacle(lat, lon)
        if (obsDist < metrics.obstacleMinDistance) {
            metrics.obstacleMinDistance = obsDist
        }
        totalObstacleDist += obsDist
        
        // 计算路径长度
        if (i > 0) {
            var prevWp = waypoints[i-1]
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
                metrics.pathLength += distanceMeters(prevLat, prevLon, lat, lon)
                
                // 计算角度变化（平滑性）
                if (i > 1) {
                    var prevPrevWp = waypoints[i-2]
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
        if (angleChanges > 0) {
            metrics.pathSmoothness = totalAngleChange / angleChanges
        }
    } else {
        console.warn('[TowerOptimize] calculatePathMetrics: No valid points found!')
    }
    
    if (metrics.obstacleMinDistance === Infinity) {
        metrics.obstacleMinDistance = 0
    }
    if (metrics.signalMin === Infinity) {
        metrics.signalMin = 0
    }
    if (metrics.signalMax === -Infinity) {
        metrics.signalMax = 0
    }
    
    // 如果障碍物平均距离是Infinity，设置为0（表示没有障碍物）
    if (!isFinite(metrics.obstacleAvgDistance) || metrics.obstacleAvgDistance === Infinity) {
        metrics.obstacleAvgDistance = 0
    }
    
    // 计算overscore分数（综合评分，值越大越好）
    // overscore = 信号强度 * 0.4 + 障碍物距离 * 0.3 + 路径平滑性 * 0.2 + 路径长度倒数 * 0.1
    var lengthScore = metrics.pathLength > 0 ? 10000 / metrics.pathLength : 0
    var smoothScore = 180 - metrics.pathSmoothness  // 角度变化越小越好
    metrics.overscore = metrics.signalAvg * 0.4 + 
                        metrics.obstacleAvgDistance * 0.3 + 
                        smoothScore * 0.2 + 
                        lengthScore * 0.1
    
    console.log('[TowerOptimize] calculatePathMetrics result:', JSON.stringify({
        obstacleMinDistance: metrics.obstacleMinDistance.toFixed(2),
        obstacleAvgDistance: metrics.obstacleAvgDistance.toFixed(2),
        signalAvg: metrics.signalAvg.toFixed(4),
        signalMin: metrics.signalMin.toFixed(4),
        signalMax: metrics.signalMax.toFixed(4),
        pathLength: metrics.pathLength.toFixed(2),
        pathSmoothness: metrics.pathSmoothness.toFixed(2),
        overscore: metrics.overscore.toFixed(2)
    }))
    
    return metrics
}

// 获取原始路径和优化后路径的指标（使用传入的原始路径点）
function getPathComparisonMetricsWithOriginal(missionController, originalWaypoints) {
    console.log('[TowerOptimize] ===== getPathComparisonMetricsWithOriginal called =====')
    console.log('[TowerOptimize] missionController:', !!missionController)
    console.log('[TowerOptimize] originalWaypoints length:', originalWaypoints ? originalWaypoints.length : 0)
    
    // 确保towers已加载
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
        if (originalMetrics) {
            console.log('[TowerOptimize] Original metrics - signalAvg:', originalMetrics.signalAvg, 'obstacleAvgDistance:', originalMetrics.obstacleAvgDistance)
        }
    } else {
        console.warn('[TowerOptimize] No original waypoints provided')
    }
    
    // 获取当前优化后的路径
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
    
    var result = {
        original: originalMetrics,
        optimized: optimizedMetrics
    }
    console.log('[TowerOptimize] Returning comparison data, original:', !!result.original, 'optimized:', !!result.optimized)
    return result
}

// 获取原始路径和优化后路径的指标
function getPathComparisonMetrics(missionController) {
    console.log('[TowerOptimize] ===== getPathComparisonMetrics called =====')
    console.log('[TowerOptimize] missionController:', !!missionController)
    
    // 确保towers已加载
    if (!towers.length) {
        console.warn('[TowerOptimize] Towers not loaded in getPathComparisonMetrics, attempting to load...')
        loadTowers()
    }
    
    var originalMetrics = null
    var optimizedMetrics = null
    
    console.log('[TowerOptimize] originalPathWaypoints:', originalPathWaypoints)
    console.log('[TowerOptimize] originalPathWaypoints type:', typeof originalPathWaypoints)
    console.log('[TowerOptimize] originalPathWaypoints length:', originalPathWaypoints ? originalPathWaypoints.length : 0)
    console.log('[TowerOptimize] cachedOriginalPathWaypoints length:', cachedOriginalPathWaypoints ? cachedOriginalPathWaypoints.length : 0)
    
    // 优先使用 originalPathWaypoints，如果为空则使用缓存
    var pathToUse = null
    if (originalPathWaypoints && originalPathWaypoints.length > 0) {
        pathToUse = originalPathWaypoints
        console.log('[TowerOptimize] Using originalPathWaypoints for metrics calculation')
    } else if (cachedOriginalPathWaypoints && cachedOriginalPathWaypoints.length > 0) {
        pathToUse = cachedOriginalPathWaypoints
        console.log('[TowerOptimize] Using cachedOriginalPathWaypoints for metrics calculation')
        // 恢复 originalPathWaypoints
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
        if (originalMetrics) {
            console.log('[TowerOptimize] Original metrics - signalAvg:', originalMetrics.signalAvg, 'obstacleAvgDistance:', originalMetrics.obstacleAvgDistance)
        }
    } else {
        console.warn('[TowerOptimize] No original path waypoints available')
        console.warn('[TowerOptimize] This might mean optimization was not called, or originalPathWaypoints was cleared')
    }
    
    // 获取当前优化后的路径
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
    
    var result = {
        original: originalMetrics,
        optimized: optimizedMetrics
    }
    console.log('[TowerOptimize] Returning comparison data, original:', !!result.original, 'optimized:', !!result.optimized)
    return result
}

// A* based adjustment: For each eligible waypoint (excluding last), perform grid search
// to find a new coordinate balancing: (1) stay close to original waypoint, (2) be closer
// to next waypoint (progress), (3) maximize signal strength from towers.
// Movement: 8-direction (N,S,E,W, diagonals). Cost function (to minimize):
//    f = gMove + wDev*distOriginal + hNext - wSig*signalStrength
// where hNext is Euclidean to next waypoint, signalStrength uses inverse-power model.
// Weights chosen empirically and can be tuned.
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
    
    // 如果towers未加载，尝试加载
    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, attempting to load...')
        loadTowers()
        if (!towers.length) {
            console.warn('[TowerOptimize] Failed to load towers, abort A* optimize')
            return
        }
        console.log('[TowerOptimize] Successfully loaded', towers.length, 'towers')
    }
    
    // 清除之前的debug数据
    clearDebugSearchTrees()
    options = options || {}
    
    // 记录优化前的原始路径点，用于对比显示
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
    console.log('[TowerOptimize] originalPathWaypoints after saving:', originalPathWaypoints)
    
    // 同时保存到缓存中，防止模块变量被重置
    cachedOriginalPathWaypoints = []
    for (var cacheIdx = 0; cacheIdx < originalPathWaypoints.length; cacheIdx++) {
        var cachedCoord = originalPathWaypoints[cacheIdx]
        cachedOriginalPathWaypoints.push(Pos.QtPositioning.coordinate(
            cachedCoord.latitude,
            cachedCoord.longitude,
            cachedCoord.altitude
        ))
    }
    console.log('[TowerOptimize] Cached', cachedOriginalPathWaypoints.length, 'original waypoints')
    
    // 从配置文件读取A*参数
    var cellSize = options.cellSizeMeters || getConfig('astar', 'cellSizeMeters', 30)
    var radiusCells = options.radiusCells || getConfig('astar', 'radiusCells', 10)
    var wDev = options.weightDeviation || getConfig('astar', 'weightDeviation', 0.25)
    var wSig = options.weightSignal || getConfig('astar', 'weightSignal', 18000)
    var maxIterations = options.maxIterations || getConfig('astar', 'maxIterations', 8000)

    // Signal model parameters (align with heatmap layer for consistency)
    var attenExp = getConfig('astar', 'signalModel.attenuationExponent', 1.2)
    var baseDistance = getConfig('astar', 'signalModel.baseDistanceMeters', 300.0)
    var radiusMeters = getConfig('astar', 'signalModel.signalRadiusMeters', 12000.0)
    var strengthMultiplier = getConfig('astar', 'signalModel.strengthMultiplier', 1.0)

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
    var minSeparation = options.minSeparationMeters || getConfig('astar', 'separation.minMeters', 5.0)
    var safeSeparation = options.safeSeparationMeters || getConfig('astar', 'separation.safeMeters', 15.0)

    // Snapshot original coordinates to allow revert if something unexpected changes count
    var originalCoords = []
    for (var _si=0; _si<visualItems.count; _si++) {
        var _it = visualItems.get(_si)
        if (_it && _it.coordinate && _it.coordinate.isValid) {
            originalCoords.push({ index:_si, coord:_it.coordinate })
        }
    }

    // 计算航线平均间距，用于动态调整折扣阈值
    var totalDistance = 0
    var segmentCount = 0
    for (var _di=0; _di<visualItems.count-1; _di++) {
        var _curr = visualItems.get(_di)
        var _next = visualItems.get(_di+1)
        if (_curr && _next && _curr.coordinate && _next.coordinate && _curr.coordinate.isValid && _next.coordinate.isValid) {
            totalDistance += distanceMeters(_curr.coordinate.latitude, _curr.coordinate.longitude,
                                           _next.coordinate.latitude, _next.coordinate.longitude)
            segmentCount++
        }
    }
    var averageSegmentDistance = segmentCount > 0 ? totalDistance / segmentCount : 100
    console.info('[TowerOptimize] Mission average segment distance:', averageSegmentDistance.toFixed(2), 'm')
    // 使用平均间距的0.8倍作为动态阈值（比平均间距略小）
    var dynamicDeviationThreshold = Math.max(averageSegmentDistance * 0.8, 50)
    console.info('[TowerOptimize] Dynamic deviation threshold:', dynamicDeviationThreshold.toFixed(2), 'm')

    // 碰撞检测和移动函数
    function checkAndMoveOutOfCollision(coord) {
        console.log('[TowerOptimize] checkAndMoveOutOfCollision called for:', coord.latitude.toFixed(6), coord.longitude.toFixed(6))
        
        // 使用JavaScript本地的weatherSensors数据
        if (!weatherSensors || weatherSensors.length === 0) {
            console.warn('[TowerOptimize] No sensors available for collision check')
            return coord
        }
        
        console.log('[TowerOptimize] Checking collision with', weatherSensors.length, 'sensors')
        
        // 找到最近的碰撞sensor
        var minDist = Infinity
        var nearestSensor = null
        
        for (var i = 0; i < weatherSensors.length; i++) {
            var sensor = weatherSensors[i]
            var dist = distanceMeters(coord.latitude, coord.longitude, sensor.lat, sensor.lon)
            // weatherSensors使用radius字段
            var sensorRadius = sensor.radius || 100
            // 碰撞检测阈值：noFlyRadius + 5m buffer
            var collisionRadius = sensorRadius + 5
            
            console.log('[TowerOptimize] Sensor', sensor.name, 'distance:', dist.toFixed(2), 'm, radius:', sensorRadius, 'm, threshold:', collisionRadius.toFixed(2), 'm')
            
            if (dist < collisionRadius && dist < minDist) {
                minDist = dist
                nearestSensor = sensor
                nearestSensor.effectiveRadius = sensorRadius  // 保存实际使用的半径
            }
        }
        
        if (!nearestSensor) {
            console.log('[TowerOptimize] No collision detected')
            return coord  // 无碰撞
        }
        
        console.warn('[TowerOptimize] Collision detected! Distance=' + minDist.toFixed(2) + 
                     'm, threshold=' + (nearestSensor.effectiveRadius + 5).toFixed(2) + 'm')
        
        // 计算从sensor到当前点的方向
        var latDiff = coord.latitude - nearestSensor.lat
        var lonDiff = coord.longitude - nearestSensor.lon
        var bearing = Math.atan2(latDiff, lonDiff)
        
        // 移动到安全距离：noFlyRadius + 15m
        var safeDistance = nearestSensor.effectiveRadius + 15  // 100 + 15 = 115m
        var latOffset = (safeDistance / 111320) * Math.sin(bearing)
        var lonOffset = (safeDistance / (111320 * Math.cos(coord.latitude * Math.PI / 180))) * Math.cos(bearing)
        
        var newCoord = Pos.QtPositioning.coordinate(
            nearestSensor.lat + latOffset,
            nearestSensor.lon + lonOffset,
            coord.altitude
        )
        
        var movedDist = distanceMeters(coord.latitude, coord.longitude, newCoord.latitude, newCoord.longitude)
        console.warn('[TowerOptimize] Moved waypoint out of collision: sensor=' + nearestSensor.name + 
                     ', was=' + minDist.toFixed(2) + 'm, now=' + safeDistance.toFixed(2) + 'm, moved=' + movedDist.toFixed(2) + 'm')
        
        return newCoord
    }

    function adjustWaypoint(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return
        
        // 计算原始距离用于调试
        var origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
        console.log('[TowerOptimize] ========== Waypoint', index, '==========')
        console.log('[TowerOptimize] Original coord:', orig.latitude.toFixed(6), orig.longitude.toFixed(6), 'alt:', orig.altitude.toFixed(2))
        console.log('[TowerOptimize] Next coord:', next.latitude.toFixed(6), next.longitude.toFixed(6))
        console.log('[TowerOptimize] Original distance to next:', origDistToNext.toFixed(2), 'm')
        
        // 保护机制：原始waypoint间距太小时，减少优化强度
        if (origDistToNext < 60) {
            console.warn('[TowerOptimize] Original distance', origDistToNext.toFixed(2), 'm < 60m, skipping optimization to avoid over-clustering')
            return
        }
        
        if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
            var prevC = prevItem.coordinate
            var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
            console.log('[TowerOptimize] Prev coord:', prevC.latitude.toFixed(6), prevC.longitude.toFixed(6))
            console.log('[TowerOptimize] Original distance to prev:', origDistToPrev.toFixed(2), 'm')
        }
        
        // *** 预处理：检测并移动碰撞点出禁飞区 ***
        console.log('[TowerOptimize] Pre-check collision for waypoint', index, 'at', orig.latitude.toFixed(6), orig.longitude.toFixed(6))
        console.log('[TowerOptimize] weatherSensors available:', weatherSensors ? weatherSensors.length : 0)
        
        var checkedCoord = checkAndMoveOutOfCollision(orig)
        if (checkedCoord.latitude !== orig.latitude || checkedCoord.longitude !== orig.longitude) {
            // 发生了移动 - 立即更新item坐标
            console.warn('[TowerOptimize] ⚠ Waypoint', index, 'moved out of collision zone')
            orig = checkedCoord
            item.coordinate = checkedCoord  // 立即更新waypoint坐标
            if (item.dirty !== undefined) item.dirty = true
            item._collisionMoved = true  // 标记为避障移动，防止被合并删除
            origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
            console.log('[TowerOptimize] After collision avoidance, new orig:', orig.latitude.toFixed(6), orig.longitude.toFixed(6))
            console.log('[TowerOptimize] New distance to next:', origDistToNext.toFixed(2), 'm')
            console.log('[TowerOptimize] Item coordinate updated to avoid collision, marked as collision-moved')
        } else {
            console.log('[TowerOptimize] No collision detected or no movement needed')
        }
        
        // 尝试使用C++实现
        if (pathOptManager) {
            try {
                console.info('[TowerOptimize] Using C++ A* for waypoint', index, 'from', orig.latitude.toFixed(6), orig.longitude.toFixed(6))
                
                // 获取prev坐标（如果存在）
                var prev = (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) 
                    ? prevItem.coordinate 
                    : Pos.QtPositioning.coordinate()  // 无效坐标
                
                // 调用C++ A*优化（传递正确的4个参数）
                var optimized = pathOptManager.towerOptimizer.optimizeSingleWaypoint(
                    orig, next, prev, orig.altitude
                )
                
                // 应用优化结果
                var newCoord = Pos.QtPositioning.coordinate(
                    optimized.latitude, 
                    optimized.longitude, 
                    orig.altitude
                )
                
                console.log('[TowerOptimize] C++ optimized coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
                
                // 计算偏离原始位置的距离
                var deviationFromOrig = distanceMeters(newCoord.latitude, newCoord.longitude, orig.latitude, orig.longitude)
                console.log('[TowerOptimize] Deviation from original:', deviationFromOrig.toFixed(2), 'm')
                
                // 自适应折扣：使用动态阈值
                var maxDeviation = Math.max(dynamicDeviationThreshold, origDistToNext * 0.6)
                if (deviationFromOrig > maxDeviation) {
                    var discountLinear = maxDeviation / deviationFromOrig
                    var discount = discountLinear * discountLinear  // 平方衰减
                    console.warn('[TowerOptimize] Deviation', deviationFromOrig.toFixed(2), 'm exceeds', maxDeviation.toFixed(2), 'm, applying squared discount', discount.toFixed(3))
                    
                    var adjustedLat = orig.latitude + (newCoord.latitude - orig.latitude) * discount
                    var adjustedLon = orig.longitude + (newCoord.longitude - orig.longitude) * discount
                    newCoord = Pos.QtPositioning.coordinate(adjustedLat, adjustedLon, orig.altitude)
                    console.log('[TowerOptimize] Discounted coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
                }
                
                // 间距检查（保留JavaScript的检查逻辑）
                var revert = false
                var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
                console.log('[TowerOptimize] New distance to next:', dNext.toFixed(2), 'm (was', origDistToNext.toFixed(2), 'm)')
                
                // 硬性约束：最小间距
                if (dNext < minSeparation) {
                    console.warn('[TowerOptimize] C++ result: too close to next', dNext.toFixed(2), 'm')
                    revert = true
                }
                
                // 软约束：保持原始间距的合理比例（40%-250%）
                var distRatio = dNext / origDistToNext
                console.log('[TowerOptimize] Distance ratio to next:', distRatio.toFixed(2), '(range: [0.4, 2.5])')
                if (distRatio < 0.4 || distRatio > 2.5) {
                    console.warn('[TowerOptimize] C++ result: distance ratio', distRatio.toFixed(2), 'out of range [0.4, 2.5]')
                    revert = true
                }
                
                if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
                    var prevC = prevItem.coordinate
                    var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
                    var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
                    console.log('[TowerOptimize] New distance to prev:', dPrev.toFixed(2), 'm (was', origDistToPrev.toFixed(2), 'm)')
                    
                    if (dPrev < minSeparation) {
                        console.warn('[TowerOptimize] C++ result: too close to prev', dPrev.toFixed(2), 'm')
                        revert = true
                    }
                    
                    var prevDistRatio = dPrev / origDistToPrev
                    console.log('[TowerOptimize] Distance ratio to prev:', prevDistRatio.toFixed(2), '(range: [0.4, 2.5])')
                    if (prevDistRatio < 0.4 || prevDistRatio > 2.5) {
                        console.warn('[TowerOptimize] C++ result: prev distance ratio', prevDistRatio.toFixed(2), 'out of range [0.4, 2.5]')
                        revert = true
                    }
                }
                
                if (!revert) {
                    console.log('[TowerOptimize] ✓ C++ A* optimization APPLIED for waypoint', index)
                    console.log('[TowerOptimize] Final coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
                    item.coordinate = newCoord
                    if (item.dirty !== undefined) item.dirty = true
                    return  // 成功，提前返回
                } else {
                    console.warn('[TowerOptimize] C++ result reverted due to spacing constraints')
                }
                
            } catch(e) {
                console.error('[TowerOptimize] C++ A* failed, falling back to JavaScript:', e.toString())
            }
        }
        
        // JavaScript实现（回退或C++不可用时）
        var lat0 = orig.latitude
        var lon0 = orig.longitude
        var cosLat = Math.cos(lat0 * Math.PI/180)
        var metersPerDegLat = 111320.0
        var metersPerDegLon = metersPerDegLat * cosLat
        
        // Debug数据收集
        var debugTree = {
            waypointIndex: index,
            originalCoord: { lat: lat0, lon: lon0 },
            targetCoord: { lat: next.latitude, lon: next.longitude },
            nodes: [],
            edges: [],
            finalPath: [],
            bestNode: null
        }
        console.info('[TowerOptimize] Using JavaScript A* for waypoint', index, 'from', lat0.toFixed(6), lon0.toFixed(6))

        function toCoord(gx, gy) { // grid offset in cells
            var dxMeters = gx * cellSize
            var dyMeters = gy * cellSize
            var dLat = dyMeters / metersPerDegLat
            var dLon = dxMeters / metersPerDegLon
            return { latitude: lat0 + dLat, longitude: lon0 + dLon }
        }

        // 【关键修正】目标不应该是next waypoint，而是原始位置的周围区域
        // 目标是找到信号更好的点，同时保持waypoint之间的间距
        function goalGridOffsets() {
            // 不设置具体目标点，而是在整个搜索半径内寻找最优解
            // 返回null表示没有明确目标，依靠代价函数引导搜索
            return null
        }

        var goal = goalGridOffsets()
        var goalKey = (goal !== null) ? (goal.gx + ',' + goal.gy) : null
        var open = {}
        var openArr = []
        var closed = {}
        
        // 优化的优先队列：使用最小堆而不是线性搜索
        function pushNode(node) { 
            open[node.key] = node
            openArr.push(node)
            // 上浮操作维护堆性质
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
                // 下沉操作维护堆性质
                var i = 0
                while (true) {
                    var left = 2 * i + 1
                    var right = 2 * i + 2
                    var smallest = i
                    
                    if (left < openArr.length && openArr[left].f < openArr[smallest].f) {
                        smallest = left
                    }
                    if (right < openArr.length && openArr[right].f < openArr[smallest].f) {
                        smallest = right
                    }
                    if (smallest === i) break
                    
                    var temp = openArr[i]
                    openArr[i] = openArr[smallest]
                    openArr[smallest] = temp
                    i = smallest
                }
            }
            return best
        }
        // 添加缓存以避免重复计算
        var signalCache = {}
        var heuristicCache = {}
        
        function heuristic(gx, gy) {
            // 【修正】启发式函数：倾向于保持与前后waypoint的合理距离
            // 而不是拉向next waypoint
            var key = gx + ',' + gy
            if (heuristicCache[key] !== undefined) return heuristicCache[key]
            var c = toCoord(gx, gy)
            
            // 计算到next和prev的距离
            var distToNext = distanceMeters(c.latitude, c.longitude, next.latitude, next.longitude)
            
            // 计算原始两点间距离
            var origDist = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
            
            // 惩罚过度偏离原始路径方向的点
            // 理想情况：新点保持在原点到next的路径上，但可以左右偏移找信号
            var result = Math.abs(distToNext - origDist) * 0.5  // 偏离路径的惩罚
            
            heuristicCache[key] = result
            return result
        }
        
        function deviationCost(gx, gy) {
            // 使用快速欧几里得距离近似（网格空间）
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
            
            // 记录当前节点到debug树
            var currentCoord = toCoord(current.gx, current.gy)
            debugTree.nodes.push({
                coord: { lat: currentCoord.latitude, lon: currentCoord.longitude },
                gx: current.gx, gy: current.gy,
                f: current.f, g: current.g, h: current.h,
                dev: current.dev, sig: current.sig,
                isClosed: true,
                isBest: false
            })
            
            // Track best (lowest total cost f) node
            if (current.f < bestSoFar.f) {
                bestSoFar = current
            }
            
            // 【修正】终止条件：找到足够好的解时提前退出
            // 条件：信号强度显著提升 且 没有过度偏离原始位置
            var origSig = signalValue(0, 0)
            var sigImprovement = (origSig > 0) ? ((current.sig - origSig) / origSig) : 0
            var maxSearchRadius = cellSize * radiusCells
            
            if (goalKey && current.key === goalKey) { 
                bestSoFar = current
                break 
            }
            
            // 早期终止：信号提升超过20% 且 偏离原点不超过搜索半径的30%
            if (sigImprovement > 0.2 && current.dev < maxSearchRadius * 0.3) {
                console.info('[TowerOptimize] Early termination: signal improved by', (sigImprovement*100).toFixed(1), '% at iteration', iterations)
                bestSoFar = current
                break
            }
            
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
                
                // 记录边连接
                var childCoord = toCoord(ngx, ngy)
                debugTree.edges.push({
                    from: { lat: currentCoord.latitude, lon: currentCoord.longitude },
                    to: { lat: childCoord.latitude, lon: childCoord.longitude },
                    cost: stepCost,
                    f: f
                })
                
                if (existing) {
                    if (f < existing.f) {
                        existing.g = g; existing.dev = dev; existing.sig = sig; existing.h = h; existing.f = f; existing.parent = current
                    }
                } else {
                    var newNode = { gx:ngx, gy:ngy, g:g, dev:dev, sig:sig, h:h, f:f, key:key, parent: current }
                    pushNode(newNode)
                    
                    // 记录open节点
                    debugTree.nodes.push({
                        coord: { lat: childCoord.latitude, lon: childCoord.longitude },
                        gx: ngx, gy: ngy,
                        f: f, g: g, h: h,
                        dev: dev, sig: sig,
                        isClosed: false,
                        isBest: false
                    })
                }
            }
        }
        // Choose bestSoFar path end node.
        var target = bestSoFar
        var chosen = toCoord(target.gx, target.gy)
        var newCoord = Pos.QtPositioning.coordinate(chosen.latitude, chosen.longitude, orig.altitude)
        
        // 记录最佳节点和最终路径
        debugTree.bestNode = {
            coord: { lat: chosen.latitude, lon: chosen.longitude },
            gx: target.gx, gy: target.gy,
            f: target.f, g: target.g, h: target.h,
            dev: target.dev, sig: target.sig
        }
        
        // 回溯最终路径
        var pathNode = target
        while (pathNode) {
            var pathCoord = toCoord(pathNode.gx, pathNode.gy)
            debugTree.finalPath.unshift({
                coord: { lat: pathCoord.latitude, lon: pathCoord.longitude },
                gx: pathNode.gx, gy: pathNode.gy,
                f: pathNode.f, g: pathNode.g, h: pathNode.h
            })
            pathNode = pathNode.parent
        }
        
        // 标记最佳节点
        for (var ni = 0; ni < debugTree.nodes.length; ni++) {
            if (debugTree.nodes[ni].gx === target.gx && debugTree.nodes[ni].gy === target.gy) {
                debugTree.nodes[ni].isBest = true
                break
            }
        }
        // 【加强】间距检查 - 防止waypoint聚集
        var revert = false
        var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
        console.log('[TowerOptimize] JS A* new coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
        console.log('[TowerOptimize] JS A* new distance to next:', dNext.toFixed(2), 'm (was', origDistToNext.toFixed(2), 'm)')
        
        // 硬性约束：最小间距
        if (dNext < minSeparation) {
            console.warn('[TowerOptimize] Revert: too close to next', dNext.toFixed(2), 'm < minSeparation', minSeparation)
            revert = true
        }
        
        // 软约束：保持原始间距的合理比例（40%-250%）- 平衡信号优化与路径合理性
        var distRatio = dNext / origDistToNext
        console.log('[TowerOptimize] JS A* distance ratio to next:', distRatio.toFixed(2), '(range: [0.4, 2.5])')
        if (distRatio < 0.4 || distRatio > 2.5) {
            console.warn('[TowerOptimize] Revert: distance ratio', distRatio.toFixed(2), 'out of range [0.4, 2.5]')
            revert = true
        }
        
        // 安全间距检查
        if (dNext < safeSeparation) {
            console.warn('[TowerOptimize] Revert: too close to next', dNext.toFixed(2), 'm < safeSeparation', safeSeparation)
            revert = true
        }
        
        if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
            var prevC = prevItem.coordinate
            var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
            var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
            console.log('[TowerOptimize] JS A* new distance to prev:', dPrev.toFixed(2), 'm (was', origDistToPrev.toFixed(2), 'm)')
            
            if (dPrev < minSeparation) {
                console.warn('[TowerOptimize] Revert: too close to prev', dPrev.toFixed(2), 'm')
                revert = true
            }
            if (dPrev < safeSeparation) {
                console.warn('[TowerOptimize] Revert: too close to prev (safe)', dPrev.toFixed(2), 'm')
                revert = true
            }
            
            // 检查前后间距比例
            var prevRatio = dPrev / origDistToPrev
            console.log('[TowerOptimize] JS A* distance ratio to prev:', prevRatio.toFixed(2), '(range: [0.4, 2.5])')
            if (prevRatio < 0.4 || prevRatio > 2.5) {
                console.warn('[TowerOptimize] Revert: prev distance ratio', prevRatio.toFixed(2), 'out of range [0.4, 2.5]')
                revert = true
            }
        }
        if (!revert) {
            console.log('[TowerOptimize] ✓ JS A* optimization APPLIED for waypoint', index)
            console.log('[TowerOptimize] Final coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
            debugTree.applied = true
            debugTree.finalCoord = { lat: newCoord.latitude, lon: newCoord.longitude }
        } else {
            // Keep original (no move)
            console.warn('[TowerOptimize] Revert idx', index, 'to original due to spacing violation', dNext.toFixed(2), 'm')
            debugTree.applied = false
            debugTree.revertReason = 'spacing_violation'
        }
        
        // 保存debug数据
        console.info('[TowerOptimize] Saving debug tree for waypoint', index, 'with', debugTree.nodes.length, 'nodes')
        debugSearchTrees.push(debugTree)
    }

    console.info('[TowerOptimize] A* processing', visualItems.count - 2, 'waypoints for debug data')
    for (var i=1; i<visualItems.count-1; i++) { // skip first and last
        var item = visualItems.get(i)
        var nextItem = visualItems.get(i+1)
        var prevItem = visualItems.get(i-1)
        if (!item || !nextItem) continue
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate || !item.isSimpleItem || item.isTakeoffItem || item.isLandCommand) {
            console.info('[TowerOptimize] Skipping waypoint', i, 'due to constraints')
            continue
        }
        console.info('[TowerOptimize] Adjusting waypoint', i)
        adjustWaypoint(item, nextItem, prevItem, i)
    }
    console.info('[TowerOptimize] Collected', debugSearchTrees.length, 'debug trees')
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
                    console.warn('[TowerOptimize] Reverted idx', vi, 'due to close separation', sep.toFixed(2),'m')
                    break
                }
            }
        }
    }
    // Post-condition: ensure count unchanged
    if (visualItems.count !== originalCoords.length) {
        console.error('[TowerOptimize] Waypoint count changed unexpectedly. Reverting coordinates.')
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
    
    // 合并过近的waypoint（距离<80m），但跳过特殊点（launch、takeoff、land等）
    var toRemove = []
    for (var mi=1; mi<visualItems.count-1; mi++) {
        var currItem = visualItems.get(mi)
        var nextItem = visualItems.get(mi+1)
        if (!currItem || !nextItem) continue
        if (!currItem.coordinate || !nextItem.coordinate) continue
        
        // 跳过特殊waypoint类型
        if (!currItem.specifiesCoordinate || currItem.isStandaloneCoordinate || 
            !currItem.isSimpleItem || currItem.isTakeoffItem || currItem.isLandCommand) {
            continue
        }
        if (!nextItem.specifiesCoordinate || nextItem.isStandaloneCoordinate || 
            !nextItem.isSimpleItem || nextItem.isTakeoffItem || nextItem.isLandCommand) {
            continue
        }
        
        // 跳过避障移动过的waypoint - 这些点是为了安全必须保留的
        if (currItem._collisionMoved || nextItem._collisionMoved) {
            console.log('[TowerOptimize] Skipping merge check for waypoint', mi, '- collision-moved waypoint must be preserved')
            continue
        }
        
        var dist = distanceMeters(currItem.coordinate.latitude, currItem.coordinate.longitude, 
                                   nextItem.coordinate.latitude, nextItem.coordinate.longitude)
        if (dist < 80) {
            console.warn('[TowerOptimize] Waypoint', mi, 'to', mi+1, 'distance', dist.toFixed(2), 'm < 80m, marking for removal')
            toRemove.push(mi)
        }
    }
    
    // 从后往前删除，避免索引错乱
    for (var di=toRemove.length-1; di>=0; di--) {
        var removeIdx = toRemove[di]
        console.info('[TowerOptimize] Removing waypoint', removeIdx)
        missionController.removeVisualItem(removeIdx)
    }
    
    if (toRemove.length > 0) {
        console.info('[TowerOptimize] Removed', toRemove.length, 'waypoints due to proximity')
    }
    
    // 检查并修复路径段碰撞（在所有优化完成后执行）
    console.log('[TowerOptimize] Before checkAndFixPathSegments, originalPathWaypoints length:', originalPathWaypoints.length)
    console.log('[TowerOptimize] originalPathWaypoints content:', originalPathWaypoints)
    checkAndFixPathSegments(missionController)
    console.log('[TowerOptimize] After checkAndFixPathSegments, originalPathWaypoints length:', originalPathWaypoints.length)
    console.log('[TowerOptimize] originalPathWaypoints content after checkAndFixPathSegments:', originalPathWaypoints)
    
    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMissionAStar A* applied')
    console.log('[TowerOptimize] Final originalPathWaypoints length:', originalPathWaypoints.length)
    console.log('[TowerOptimize] Final originalPathWaypoints content:', originalPathWaypoints)
    
    // 验证 originalPathWaypoints 是否仍然有效
    if (originalPathWaypoints.length === 0) {
        console.error('[TowerOptimize] ERROR: originalPathWaypoints is empty after optimization!')
    } else {
        console.log('[TowerOptimize] ✓ originalPathWaypoints preserved with', originalPathWaypoints.length, 'waypoints')
    }
}

// ...existing code...

function optimizeMissionRRT(missionController, planMasterController, options) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 3) return
    
    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, abort RRT optimize')
        return
    }

    // 兼容传入数字的老调用方式（例如 0.2）
    options = (typeof options === 'object' && options) ? options : {}
    
    // 记录优化前的原始路径点，用于对比显示
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
            console.log('[TowerOptimize] Saved original waypoint', origIdx, 'at', origItem.coordinate.latitude.toFixed(6), origItem.coordinate.longitude.toFixed(6))
        } else {
            console.warn('[TowerOptimize] Skipping invalid waypoint', origIdx, 'isValid:', origItem && origItem.coordinate ? origItem.coordinate.isValid : 'no coordinate')
        }
    }
    console.log('[TowerOptimize] Saved', originalPathWaypoints.length, 'original waypoints for comparison (RRT)')

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


    // 快照坐标，必要时回滚
    var originalCoords = []
    for (var _si=0; _si<visualItems.count; _si++) {
        var _it = visualItems.get(_si)
        if (_it && _it.coordinate && _it.coordinate.isValid) {
            originalCoords.push({ index:_si, coord:_it.coordinate })
        }
    }

    // 计算航线平均间距，用于动态调整折扣阈值
    var totalDistanceRRT = 0
    var segmentCountRRT = 0
    for (var _di=0; _di<visualItems.count-1; _di++) {
        var _curr = visualItems.get(_di)
        var _next = visualItems.get(_di+1)
        if (_curr && _next && _curr.coordinate && _next.coordinate && _curr.coordinate.isValid && _next.coordinate.isValid) {
            totalDistanceRRT += distanceMeters(_curr.coordinate.latitude, _curr.coordinate.longitude,
                                           _next.coordinate.latitude, _next.coordinate.longitude)
            segmentCountRRT++
        }
    }
    var averageSegmentDistanceRRT = segmentCountRRT > 0 ? totalDistanceRRT / segmentCountRRT : 100
    console.info('[TowerOptimize][RRT] Mission average segment distance:', averageSegmentDistanceRRT.toFixed(2), 'm')
    var dynamicDeviationThresholdRRT = Math.max(averageSegmentDistanceRRT * 0.8, 50)
    console.info('[TowerOptimize][RRT] Dynamic deviation threshold:', dynamicDeviationThresholdRRT.toFixed(2), 'm')

    function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

    function adjustWaypointRRT(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return
        
        // 计算原始距离用于调试
        var origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
        console.log('[TowerOptimize] ========== RRT Waypoint', index, '==========')
        console.log('[TowerOptimize] Original coord:', orig.latitude.toFixed(6), orig.longitude.toFixed(6), 'alt:', orig.altitude.toFixed(2))
        console.log('[TowerOptimize] Next coord:', next.latitude.toFixed(6), next.longitude.toFixed(6))
        console.log('[TowerOptimize] Original distance to next:', origDistToNext.toFixed(2), 'm')
        
        // 保护机制：原始waypoint间距太小时，减少优化强度
        if (origDistToNext < 60) {
            console.warn('[TowerOptimize] RRT: Original distance', origDistToNext.toFixed(2), 'm < 60m, skipping optimization to avoid over-clustering')
            return
        }
        
        if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
            var prevC = prevItem.coordinate
            var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
            console.log('[TowerOptimize] Prev coord:', prevC.latitude.toFixed(6), prevC.longitude.toFixed(6))
            console.log('[TowerOptimize] Original distance to prev:', origDistToPrev.toFixed(2), 'm')
        }
        
        // 尝试使用C++实现
        if (pathOptManager) {
            try {
                // 优化前检查碰撞，如有碰撞则先移出禁飞区
                var checkedCoord = checkAndMoveOutOfCollision(orig)
                if (checkedCoord.latitude !== orig.latitude || checkedCoord.longitude !== orig.longitude) {
                    var movedDist = distanceMeters(orig.latitude, orig.longitude, checkedCoord.latitude, checkedCoord.longitude)
                    console.warn('[TowerOptimize] ⚠ RRT: Waypoint', index, 'moved out of collision zone, distance', movedDist.toFixed(2), 'm')
                    console.log('[TowerOptimize] Was:', orig.latitude.toFixed(6), orig.longitude.toFixed(6))
                    console.log('[TowerOptimize] Now:', checkedCoord.latitude.toFixed(6), checkedCoord.longitude.toFixed(6))
                    orig = checkedCoord
                    item.coordinate = checkedCoord  // 立即更新waypoint坐标
                    if (item.dirty !== undefined) item.dirty = true
                    origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
                    console.log('[TowerOptimize] Updated distance to next:', origDistToNext.toFixed(2), 'm')
                    console.log('[TowerOptimize] Item coordinate updated to avoid collision')
                }
                
                console.info('[TowerOptimize] Using C++ RRT for waypoint', index, 'from', orig.latitude.toFixed(6), orig.longitude.toFixed(6))
                
                // 获取prev坐标（如果存在）
                var prev = (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) 
                    ? prevItem.coordinate 
                    : Pos.QtPositioning.coordinate()  // 无效坐标
                
                // 调用C++ RRT优化（传递正确的4个参数）
                var optimized = pathOptManager.towerOptimizer.optimizeSingleWaypointRRT(
                    orig, next, prev, orig.altitude
                )
                
                // 应用优化结果
                var newCoord = Pos.QtPositioning.coordinate(
                    optimized.latitude, 
                    optimized.longitude, 
                    orig.altitude
                )
                
                console.log('[TowerOptimize] C++ RRT optimized coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
                
                // 计算偏离原始位置的距离
                var deviationFromOrig = distanceMeters(newCoord.latitude, newCoord.longitude, orig.latitude, orig.longitude)
                console.log('[TowerOptimize] RRT Deviation from original:', deviationFromOrig.toFixed(2), 'm')
                
                // 自适应折扣：使用动态阈值
                var maxDeviation = Math.max(dynamicDeviationThresholdRRT, origDistToNext * 0.6)
                if (deviationFromOrig > maxDeviation) {
                    var discountLinear = maxDeviation / deviationFromOrig
                    var discount = discountLinear * discountLinear  // 平方衰减
                    console.warn('[TowerOptimize] RRT Deviation', deviationFromOrig.toFixed(2), 'm exceeds', maxDeviation.toFixed(2), 'm, applying squared discount', discount.toFixed(3))
                    
                    var adjustedLat = orig.latitude + (newCoord.latitude - orig.latitude) * discount
                    var adjustedLon = orig.longitude + (newCoord.longitude - orig.longitude) * discount
                    newCoord = Pos.QtPositioning.coordinate(adjustedLat, adjustedLon, orig.altitude)
                    console.log('[TowerOptimize] RRT Discounted coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
                }
                
                // 间距检查（保留JavaScript的检查逻辑）
                var revert = false
                var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
                console.log('[TowerOptimize] RRT new distance to next:', dNext.toFixed(2), 'm (was', origDistToNext.toFixed(2), 'm)')
                
                // 硬性约束：最小间距
                if (dNext < minSeparation) {
                    console.warn('[TowerOptimize] C++ RRT result: too close to next', dNext.toFixed(2), 'm')
                    revert = true
                }
                
                // 软约束：保持原始间距的合理比例（40%-250%）
                var distRatio = dNext / origDistToNext
                console.log('[TowerOptimize] RRT distance ratio to next:', distRatio.toFixed(2), '(range: [0.4, 2.5])')
                if (distRatio < 0.4 || distRatio > 2.5) {
                    console.warn('[TowerOptimize] C++ RRT result: distance ratio', distRatio.toFixed(2), 'out of range [0.4, 2.5]')
                    revert = true
                }
                
                if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
                    var prevC = prevItem.coordinate
                    var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
                    var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
                    console.log('[TowerOptimize] RRT new distance to prev:', dPrev.toFixed(2), 'm (was', origDistToPrev.toFixed(2), 'm)')
                    
                    if (dPrev < minSeparation) {
                        console.warn('[TowerOptimize] C++ RRT result: too close to prev', dPrev.toFixed(2), 'm')
                        revert = true
                    }
                    
                    var prevDistRatio = dPrev / origDistToPrev
                    console.log('[TowerOptimize] RRT distance ratio to prev:', prevDistRatio.toFixed(2), '(range: [0.4, 2.5])')
                    if (prevDistRatio < 0.4 || prevDistRatio > 2.5) {
                        console.warn('[TowerOptimize] C++ RRT result: prev distance ratio', prevDistRatio.toFixed(2), 'out of range [0.4, 2.5]')
                        revert = true
                    }
                }
                
                if (!revert) {
                    console.log('[TowerOptimize] ✓ C++ RRT optimization APPLIED for waypoint', index)
                    console.log('[TowerOptimize] Final coord:', newCoord.latitude.toFixed(6), newCoord.longitude.toFixed(6))
                    item.coordinate = newCoord
                    if (item.dirty !== undefined) item.dirty = true
                    return  // 成功，提前返回
                } else {
                    console.warn('[TowerOptimize] C++ RRT result reverted due to spacing constraints')
                }
                
            } catch(e) {
                console.error('[TowerOptimize] C++ RRT failed, falling back to JavaScript:', e.toString())
            }
        }
        
        // JavaScript实现（回退或C++不可用时）
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
        var newCoord = Pos.QtPositioning.coordinate(chosenLL.latitude, chosenLL.longitude, orig.altitude)

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
            item.coordinate = newCoord
            if (item.dirty !== undefined) item.dirty = true
        } else {
            console.warn('[TowerOptimize] Revert idx', index, 'to original due to spacing violation', dNext.toFixed(2), 'm')
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
                    console.warn('[TowerOptimize][RRT] Reverted idx', vi, 'due to close separation', sep.toFixed(2),'m')
                    break
                }
            }
        }
    }

    // 数量检查（理论不会变化）
    if (visualItems.count !== originalCoords.length) {
        console.error('[TowerOptimize][RRT] Waypoint count changed unexpectedly. Reverting coordinates.')
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

    // 合并过近的waypoint（距离<80m），但跳过特殊点（launch、takeoff、land等）
    var toRemove = []
    for (var mi=1; mi<visualItems.count-1; mi++) {
        var currItem = visualItems.get(mi)
        var nextItem = visualItems.get(mi+1)
        if (!currItem || !nextItem) continue
        if (!currItem.coordinate || !nextItem.coordinate) continue
        
        // 跳过特殊waypoint类型
        if (!currItem.specifiesCoordinate || currItem.isStandaloneCoordinate || 
            !currItem.isSimpleItem || currItem.isTakeoffItem || currItem.isLandCommand) {
            continue
        }
        if (!nextItem.specifiesCoordinate || nextItem.isStandaloneCoordinate || 
            !nextItem.isSimpleItem || nextItem.isTakeoffItem || nextItem.isLandCommand) {
            continue
        }
        
        var dist = distanceMeters(currItem.coordinate.latitude, currItem.coordinate.longitude, 
                                   nextItem.coordinate.latitude, nextItem.coordinate.longitude)
        if (dist < 80) {
            console.warn('[TowerOptimize][RRT] Waypoint', mi, 'to', mi+1, 'distance', dist.toFixed(2), 'm < 80m, marking for removal')
            toRemove.push(mi)
        }
    }
    
    // 从后往前删除，避免索引错乱
    for (var di=toRemove.length-1; di>=0; di--) {
        var removeIdx = toRemove[di]
        console.info('[TowerOptimize][RRT] Removing waypoint', removeIdx)
        missionController.removeVisualItem(removeIdx)
    }
    
    if (toRemove.length > 0) {
        console.info('[TowerOptimize][RRT] Removed', toRemove.length, 'waypoints due to proximity')
    }

    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMissionRRT applied')
}

// ============ 碰撞检测函数 ============

// Haversine距离计算（米）- Replaced with QtPositioning for consistency
function distanceMeters(lat1, lon1, lat2, lon2) {
    var c1 = Pos.QtPositioning.coordinate(lat1, lon1)
    var c2 = Pos.QtPositioning.coordinate(lat2, lon2)
    return c1.distanceTo(c2)
}

// 检查点是否在天气禁飞区内
function checkWeatherCollision(lat, lon) {
    if (!getConfig('collision', 'weatherCollisionCheck', true)) {
        return false
    }
    
    var bufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)
    
    for (var i = 0; i < weatherSensors.length; i++) {
        var sensor = weatherSensors[i]
        var dist = distanceMeters(lat, lon, sensor.lat, sensor.lon)
        
        // 检查是否在禁飞区半径+缓冲区内
        if (dist < (sensor.radius + bufferMeters)) {
            console.warn('[TowerOptimize] Weather collision:', sensor.name, 'dist:', dist.toFixed(2), 'm')
            return true
        }
    }
    return false
}

// 简化的地形碰撞检测（基于最小高度约束）
// TODO: 实际应用中应该接入QGC的TerrainQuery
function checkTerrainCollision(lat, lon, altitudeAMSL) {
    if (!getConfig('collision', 'enableCollisionCheck', true)) {
        return false
    }
    
    var minAltitudeAGL = getConfig('collision', 'minAltitudeAGL', 30.0)
    var terrainClearance = getConfig('collision', 'terrainClearance', 10.0)
    
    // 简化版本：假设地面高度为0（海平面）
    // 实际使用时应该查询真实地形高度
    var estimatedGroundLevel = 0  // TODO: 接入TerrainQuery
    var agl = altitudeAMSL - estimatedGroundLevel
    
    if (agl < minAltitudeAGL + terrainClearance) {
        console.warn('[TowerOptimize] Low clearance: AGL', agl.toFixed(2), 'm')
        return true
    }
    
    return false
}

// 通用碰撞检测
function checkCollision(lat, lon, altitudeAMSL) {
    // 检查天气禁飞区
    if (checkWeatherCollision(lat, lon)) {
        return true
    }
    
    // 检查地形碰撞
    if (altitudeAMSL !== undefined && checkTerrainCollision(lat, lon, altitudeAMSL)) {
        return true
    }
    
    return false
}

// A* New optimization - 50m fixed step path planning
function optimizeMissionAStarNew(missionController, planMasterController, options) {
    if (!missionController || !missionController.visualItems) return
    var visualItems = missionController.visualItems
    if (visualItems.count < 3) return
    
    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, abort A* New optimize')
        return
    }
    
    console.log('[TowerOptimize] ===== Starting A* New Optimization =====')
    
    // 获取所有有效的路径点
    var waypoints = []
    for (var i = 1; i < visualItems.count; i++) {
        var item = visualItems.get(i)
        if (item && item.coordinate && item.coordinate.isValid) {
            waypoints.push({
                index: i,
                coordinate: item.coordinate,
                item: item
            })
        }
    }
    
    if (waypoints.length < 2) {
        console.warn('[TowerOptimize] Not enough waypoints for A* New optimization')
        return
    }
    
    // 记录优化前的原始路径点，用于对比显示
    originalPathWaypoints = []
    console.log('[TowerOptimize] Saving original waypoints (A* New), waypoints.length:', waypoints.length)
    for (var origIdx = 0; origIdx < waypoints.length; origIdx++) {
        var origWp = waypoints[origIdx]
        if (origWp && origWp.coordinate && origWp.coordinate.isValid) {
            var coord = Pos.QtPositioning.coordinate(
                origWp.coordinate.latitude,
                origWp.coordinate.longitude,
                origWp.coordinate.altitude
            )
            originalPathWaypoints.push(coord)
            console.log('[TowerOptimize] Saved original waypoint', origIdx, 'at', origWp.coordinate.latitude.toFixed(6), origWp.coordinate.longitude.toFixed(6))
        } else {
            console.warn('[TowerOptimize] Skipping invalid waypoint', origIdx, 'isValid:', origWp && origWp.coordinate ? origWp.coordinate.isValid : 'no coordinate')
        }
    }
    console.log('[TowerOptimize] Saved', originalPathWaypoints.length, 'original waypoints for comparison (A* New)')
    
    console.log('[TowerOptimize] Found', waypoints.length, 'waypoints for A* New optimization')
    for (var i = 0; i < waypoints.length; i++) {
        var wp = waypoints[i]
        var coord = wp.coordinate
        if (coord) {
            console.log(
                '[TowerOptimize] Waypoint', i,
                'lat:', typeof coord.latitude === 'function' ? coord.latitude().toFixed(8) : coord.latitude,
                'lon:', typeof coord.longitude === 'function' ? coord.longitude().toFixed(8) : coord.longitude,
                'alt:', typeof coord.altitude === 'function' ? coord.altitude().toFixed(2) : coord.altitude
            )
        } else {
            console.log('[TowerOptimize] Waypoint', i, 'invalid coordinate')
        }
    }
    
    // 使用C++ A* New算法
    if (pathOptManager) {
        try {
            // 构建原始路径坐标数组
            var originalPath = []
            for (var j = 0; j < waypoints.length; j++) {
                originalPath.push(waypoints[j].coordinate)
            }
            
            // 获取有效高度
            var avgAltitude = 0
            var validAltitudes = 0
            for (var k = 0; k < originalPath.length; k++) {
                var alt = originalPath[k].altitude
                if (!isNaN(alt) && alt > 0) {
                    avgAltitude += alt
                    validAltitudes++
                }
            }
            if (validAltitudes > 0) {
                avgAltitude = avgAltitude / validAltitudes
            } else {
                avgAltitude = 100.0 // 默认高度
            }
            
            console.log('[TowerOptimize] Calling C++ A* New optimization with', originalPath.length, 'waypoints, altitude:', avgAltitude)
            
            // 调用C++ A* New算法
            var optimizedPath = pathOptManager.towerOptimizer.optimizePathAStarNew(originalPath, avgAltitude)
            // if (optimizedPath && optimizedPath.length > 0) {
            //     optimizedPath.pop()
            // }
            console.log('[TowerOptimize] C++ A* New returned', optimizedPath.length, 'optimized waypoints')
            
            if (optimizedPath.length > 0) {
                // 应用优化结果 - 正确处理A* New生成的完整路径
                console.log('[TowerOptimize] Applying A* New optimization results')
                
                // 更新现有路径点
                var minLength = Math.min(waypoints.length, optimizedPath.length)
                console.log('[TowerOptimize] Updating', minLength, 'existing waypoints from', optimizedPath.length, 'optimized points')
                
                for (var j = 0; j < minLength; j++) {
                    var item = waypoints[j].item
                    if (item && item.coordinate) {
                        var newCoord = Pos.QtPositioning.coordinate(
                            optimizedPath[j].latitude,
                            optimizedPath[j].longitude,
                            optimizedPath[j].altitude
                        )
                        item.coordinate = newCoord
                        if (item.dirty !== undefined) item.dirty = true
                        console.log('[TowerOptimize] Updated waypoint', j, 'to', optimizedPath[j].latitude.toFixed(6), optimizedPath[j].longitude.toFixed(6))
                    }
                }
                
                // 如果优化路径有更多点，添加新的路径点
                if (optimizedPath.length > waypoints.length) {
                    console.log('[TowerOptimize] Adding', optimizedPath.length - waypoints.length, 'new waypoints')
                    
                    for (var k = waypoints.length+1; k < optimizedPath.length; k++) {
                        var newCoord = Pos.QtPositioning.coordinate(
                            optimizedPath[k].latitude,
                            optimizedPath[k].longitude,
                            optimizedPath[k].altitude
                        )
                        
                        // 在最后一个现有路径点之后插入新的路径点
                        var insertIndex = waypoints.length + (k - waypoints.length)
                        missionController.insertSimpleMissionItem(newCoord, insertIndex, false /* makeCurrentItem */)
                        console.log('[TowerOptimize] Added new waypoint', k, 'at', optimizedPath[k].latitude.toFixed(6), optimizedPath[k].longitude.toFixed(6))
                    }
                }
                
                console.log('[TowerOptimize] A* New optimization completed successfully')
            } else {
                console.error('[TowerOptimize] C++ A* New returned empty path')
            }
            
        } catch (error) {
            console.error('[TowerOptimize] Error in C++ A* New optimization:', error)
        }
    } else {
        console.error('[TowerOptimize] PathOptimizationManager not available for A* New optimization')
    }
    
    console.log('[TowerOptimize] A* New optimization finished')
}
// 检查并修复路径段碰撞
function checkAndFixPathSegments(missionController) {
    if (!getConfig('collision', 'weatherCollisionCheck', true)) return
    
    var visualItems = missionController.visualItems
    var bufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)
    var fixedCount = 0
    
    console.info('[TowerOptimize] Checking path segments for collision...')
    
    // 使用while循环，因为visualItems.count可能会变化
    var i = 0
    // 限制最大迭代次数防止死循环
    var maxChecks = 1000
    var checks = 0
    
    while (i < visualItems.count - 1 && checks < maxChecks) {
        checks++
        var item1 = visualItems.get(i)
        
        // If item1 is not spatial, skip it
        if (!item1 || !item1.specifiesCoordinate) {
            // console.log('[TowerOptimize] Skipping non-spatial item', i, item1 ? item1.commandName : 'null')
            i++
            continue
        }

        // Find next spatial item
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

        // If no next spatial item, we are done
        if (!item2) {
            break
        }
        
        var p1 = item1.coordinate
        var p2 = item2.coordinate
        
        console.log('[TowerOptimize] Checking segment', i, '->', j, 'Coords:', p1.latitude.toFixed(6), p1.longitude.toFixed(6), '->', p2.latitude.toFixed(6), p2.longitude.toFixed(6))
        
        if (!p1.isValid || !p2.isValid) {
            console.warn('[TowerOptimize] Invalid coordinates for segment', i, '->', j)
            i = j // Move to next spatial item
            continue
        }
        
        // 检查段碰撞
        var collision = findSegmentCollision(p1, p2, bufferMeters)
        
        if (collision) {
            console.warn('[TowerOptimize] Segment collision detected between', i, 'and', j, 'Sensor:', collision.sensor.name)
            
            var sensor = collision.sensor
            var sensorCoord = Pos.QtPositioning.coordinate(sensor.lat, sensor.lon)

            // --- Move endpoints 15m away from sensor (ONCE) ---
            // Move p1
            var p1Coord = Pos.QtPositioning.coordinate(p1.latitude, p1.longitude)
            var bearing1 = sensorCoord.azimuthTo(p1Coord)
            var dist1 = sensorCoord.distanceTo(p1Coord)
            var newP1 = sensorCoord.atDistanceAndAzimuth(dist1 + 15, bearing1)
            newP1.altitude = p1.altitude
            item1.coordinate = newP1
            p1 = newP1 // Update local variable for midpoint calculation
            if (item1.dirty !== undefined) item1.dirty = true
            console.log('[TowerOptimize] Moved endpoint 1 (idx', i, ') 15m away from sensor to', newP1.latitude.toFixed(6), newP1.longitude.toFixed(6))

            // Move p2
            var p2Coord = Pos.QtPositioning.coordinate(p2.latitude, p2.longitude)
            var bearing2 = sensorCoord.azimuthTo(p2Coord)
            var dist2 = sensorCoord.distanceTo(p2Coord)
            var newP2 = sensorCoord.atDistanceAndAzimuth(dist2 + 15, bearing2)
            newP2.altitude = p2.altitude
            item2.coordinate = newP2
            p2 = newP2 // Update local variable
            if (item2.dirty !== undefined) item2.dirty = true
            console.log('[TowerOptimize] Moved endpoint 2 (idx', j, ') 15m away from sensor to', newP2.latitude.toFixed(6), newP2.longitude.toFixed(6))
            // --------------------------------------------------
            
            // Strategy: Use midpoint of segment, push away from sensor center until safe
            var midLat = (p1.latitude + p2.latitude) / 2
            var midLon = (p1.longitude + p2.longitude) / 2
            
            // Use QtPositioning for accurate bearing and destination
            // sensorCoord is already defined above
            var midCoord = Pos.QtPositioning.coordinate(midLat, midLon)
            var bearing = sensorCoord.azimuthTo(midCoord)
            
            if (isNaN(bearing)) {
                bearing = 0
            }

            var safe = false
            var attempts = 0
            var maxAttempts = 10 // Limit to ~50m (10 * 5m)
            var currentBuffer = bufferMeters
            var avoidPoint = null
            var sensorRadius = (sensor.radius || 100)
            
            // Calculate distances of endpoints to sensor center
            var distP1 = distanceMeters(sensor.lat, sensor.lon, p1.latitude, p1.longitude)
            var distP2 = distanceMeters(sensor.lat, sensor.lon, p2.latitude, p2.longitude)
            var requiredClearance = sensorRadius + bufferMeters

            while (!safe && attempts < maxAttempts) {
                // Calculate candidate point
                // Add 2.0m extra safety margin to ensure we are clearly outside the buffer
                var pushDist = sensorRadius + currentBuffer + 2.0
                
                var candCoord = sensorCoord.atDistanceAndAzimuth(pushDist, bearing)
                var candLat = candCoord.latitude
                var candLon = candCoord.longitude
                
                // Check if this point resolves the collision
                // We check if the new segments (p1->cand) and (cand->p2) are clear of the sensor
                // The required clearance is sensorRadius + bufferMeters
                // However, if p1 or p2 are already inside the clearance zone, we can't fix that here.
                // So we accept the segment if it doesn't get *closer* than the endpoint (with a small tolerance).
                
                var d1 = distToSegment(sensor.lat, sensor.lon, p1.latitude, p1.longitude, candLat, candLon)
                var d2 = distToSegment(sensor.lat, sensor.lon, candLat, candLon, p2.latitude, p2.longitude)
                
                var safe1 = d1 >= requiredClearance || (distP1 < requiredClearance && d1 >= distP1 - 0.1)
                var safe2 = d2 >= requiredClearance || (distP2 < requiredClearance && d2 >= distP2 - 0.1)

                if (safe1 && safe2) {
                    safe = true
                    avoidPoint = Pos.QtPositioning.coordinate(candLat, candLon, p1.altitude)
                } else {
                    currentBuffer += 5 // Increase push distance by 5m
                    attempts++
                }
            }
            
            if (!safe || !avoidPoint) {
                 console.warn('[TowerOptimize] Could not find completely safe point. Using last attempt.')
                 // Fallback to last calculated point
                 var pushDist = sensorRadius + currentBuffer + 2.0
                 var candCoord = sensorCoord.atDistanceAndAzimuth(pushDist, bearing)
                 avoidPoint = Pos.QtPositioning.coordinate(candCoord.latitude, candCoord.longitude, p1.altitude)
            } else {
                 console.info('[TowerOptimize] Found safe avoidance point after', attempts, 'attempts. Buffer:', currentBuffer)
            }
            
            // 在j处插入新点 (before item2)
            console.info('[TowerOptimize] Inserting avoidance waypoint at', avoidPoint.latitude.toFixed(6), avoidPoint.longitude.toFixed(6), 'index:', j)
            var countBefore = visualItems.count
            missionController.insertSimpleMissionItem(avoidPoint, j, false)
            var countAfter = visualItems.count
            console.info('[TowerOptimize] VisualItems count:', countBefore, '->', countAfter)
            
            // 标记为避障移动点
            // Note: If insertion happened, the new item is at j.
            // If insertion failed, j is still item2.
            if (countAfter > countBefore) {
                var newItem = visualItems.get(j)
                if (newItem) {
                    newItem._collisionMoved = true
                    newItem.dirty = true
                }
            } else {
                console.error('[TowerOptimize] Insertion failed!')
            }
            
            fixedCount++
            // Do not increment i, so we re-check the first half of the split segment (p1 -> new)
            // The second half (new -> p2) will be checked in subsequent iterations
            // Infinite loop protection is now handled by findSegmentCollision ignoring endpoint-only collisions
        } else {
            // No collision, move to next segment
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
        
        // 检查传感器中心到线段的距离
        var dist = distToSegment(sensor.lat, sensor.lon, p1.latitude, p1.longitude, p2.latitude, p2.longitude)
        
        if (dist < radius) {
            // Check if collision is just due to endpoints being inside
            var d1 = distanceMeters(sensor.lat, sensor.lon, p1.latitude, p1.longitude)
            var d2 = distanceMeters(sensor.lat, sensor.lon, p2.latitude, p2.longitude)
            var minDistEndpoints = Math.min(d1, d2)
            
            // Only ignore if endpoints are inside the violation zone (radius includes buffer)
            if (minDistEndpoints < radius) {
                // If the segment distance is essentially the same as the endpoint distance,
                // it means the segment doesn't go "deeper" into the zone than the endpoints.
                // We can't fix endpoint violations by splitting, so we ignore them.
                if (dist >= minDistEndpoints - 0.1) { // 0.1m tolerance for sampling error
                    console.log('[TowerOptimize] Ignoring collision: segment inside buffer but not deeper than endpoints')
                    continue
                }
            }

            return { sensor: sensor, dist: dist }
        }
    }
    return null
}

function distToSegment(px, py, x1, y1, x2, y2) {
    // 使用采样法近似计算距离
    var l2 = distanceMeters(x1, y1, x2, y2)
    if (l2 < 1) return distanceMeters(px, py, x1, y1)
    
    // Increase sampling resolution to 5m to avoid missing grazing collisions
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
    // 找到线段上离传感器最近的点
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
    
    // 向外推
    // 计算从传感器中心指向最近点的方位角
    var closestCoord = Pos.QtPositioning.coordinate(closestLat, closestLon)
    var bearing = sensorCoord.azimuthTo(closestCoord)
    
    // 安全距离：半径 + 缓冲 + 额外余量
    var safeDist = (sensor.radius || 100) + buffer + 2.0 
    
    return sensorCoord.atDistanceAndAzimuth(safeDist, bearing)
}
