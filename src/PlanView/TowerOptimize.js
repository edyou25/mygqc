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
        console.warn('[TowerOptimize] No towers loaded, abort A* optimize')
        return
    }
    
    // 清除之前的debug数据
    clearDebugSearchTrees()
    options = options || {}
    
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


    function adjustWaypoint(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return
        
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
                
                // 间距检查（保留JavaScript的检查逻辑）
                var revert = false
                var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
                var origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
                
                // 硬性约束：最小间距
                if (dNext < minSeparation) {
                    console.warn('[TowerOptimize] C++ result: too close to next', dNext.toFixed(2), 'm')
                    revert = true
                }
                
                // 软约束：保持原始间距的合理比例（60%-140%）
                var distRatio = dNext / origDistToNext
                if (distRatio < 0.6 || distRatio > 1.4) {
                    console.warn('[TowerOptimize] C++ result: distance ratio', distRatio.toFixed(2), 'out of range')
                    revert = true
                }
                
                if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
                    var prevC = prevItem.coordinate
                    var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
                    var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
                    
                    if (dPrev < minSeparation) {
                        console.warn('[TowerOptimize] C++ result: too close to prev', dPrev.toFixed(2), 'm')
                        revert = true
                    }
                    
                    var prevDistRatio = dPrev / origDistToPrev
                    if (prevDistRatio < 0.6 || prevDistRatio > 1.4) {
                        console.warn('[TowerOptimize] C++ result: prev distance ratio', prevDistRatio.toFixed(2), 'out of range')
                        revert = true
                    }
                }
                
                if (!revert) {
                    item.coordinate = newCoord
                    if (item.dirty !== undefined) item.dirty = true
                    console.info('[TowerOptimize] C++ A* applied for waypoint', index)
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
        var origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
        
        // 硬性约束：最小间距
        if (dNext < minSeparation) {
            console.warn('[TowerOptimize] Revert: too close to next', dNext.toFixed(2), 'm < minSeparation', minSeparation)
            revert = true
        }
        
        // 软约束：保持原始间距的合理比例（60%-140%）
        var distRatio = dNext / origDistToNext
        if (distRatio < 0.6 || distRatio > 1.4) {
            console.warn('[TowerOptimize] Revert: distance ratio', distRatio.toFixed(2), 'out of range [0.6, 1.4]')
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
            if (prevRatio < 0.6 || prevRatio > 1.4) {
                console.warn('[TowerOptimize] Revert: prev distance ratio', prevRatio.toFixed(2), 'out of range')
                revert = true
            }
        }
        if (!revert) {
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
    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMissionAStar A* applied')
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

    function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

    function adjustWaypointRRT(item, nextItem, prevItem, index) {
        var orig = item.coordinate
        var next = nextItem.coordinate
        if (!orig.isValid || !next.isValid) return
        
        // 尝试使用C++实现
        if (pathOptManager) {
            try {
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
                
                // 间距检查（保留JavaScript的检查逻辑）
                var revert = false
                var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
                var origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
                
                // 硬性约束：最小间距
                if (dNext < minSeparation) {
                    console.warn('[TowerOptimize] C++ RRT result: too close to next', dNext.toFixed(2), 'm')
                    revert = true
                }
                
                // 软约束：保持原始间距的合理比例（60%-140%）
                var distRatio = dNext / origDistToNext
                if (distRatio < 0.6 || distRatio > 1.4) {
                    console.warn('[TowerOptimize] C++ RRT result: distance ratio', distRatio.toFixed(2), 'out of range')
                    revert = true
                }
                
                if (prevItem && prevItem.coordinate && prevItem.coordinate.isValid) {
                    var prevC = prevItem.coordinate
                    var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
                    var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
                    
                    if (dPrev < minSeparation) {
                        console.warn('[TowerOptimize] C++ RRT result: too close to prev', dPrev.toFixed(2), 'm')
                        revert = true
                    }
                    
                    var prevDistRatio = dPrev / origDistToPrev
                    if (prevDistRatio < 0.6 || prevDistRatio > 1.4) {
                        console.warn('[TowerOptimize] C++ RRT result: prev distance ratio', prevDistRatio.toFixed(2), 'out of range')
                        revert = true
                    }
                }
                
                if (!revert) {
                    item.coordinate = newCoord
                    if (item.dirty !== undefined) item.dirty = true
                    console.info('[TowerOptimize] C++ RRT applied for waypoint', index)
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

    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMissionRRT applied')
}

// ============ 碰撞检测函数 ============

// Haversine距离计算（米）
function distanceMeters(lat1, lon1, lat2, lon2) {
    var R = 6371000
    var dLat = (lat2 - lat1) * Math.PI / 180
    var dLon = (lon2 - lon1) * Math.PI / 180
    var a = Math.sin(dLat/2) * Math.sin(dLat/2) + 
            Math.cos(lat1 * Math.PI/180) * Math.cos(lat2 * Math.PI/180) * 
            Math.sin(dLon/2) * Math.sin(dLon/2)
    var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
    return R * c
}

// 检查点是否在天气禁飞区内
function checkWeatherCollision(lat, lon) {
    if (!getConfig('collision', 'weatherCollisionCheck', true)) {
        return false
    }
    
    var bufferMeters = getConfig('collision', 'weatherBufferMeters', 50.0)
    
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
            
            console.log('[TowerOptimize] C++ A* New returned', optimizedPath.length, 'optimized waypoints')
            
            if (optimizedPath.length > 0) {
                // 应用优化结果 - 正确处理A* New生成的完整路径
                console.log('[TowerOptimize] Applying A* New optimization results')
                
                // 更新所有路径点，确保数量匹配
                var minLength = Math.min(waypoints.length, optimizedPath.length)
                console.log('[TowerOptimize] Updating', minLength, 'waypoints from', optimizedPath.length, 'optimized points')
                
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
                
                // 如果优化路径有更多点，但原始路径点不够，记录警告
                if (optimizedPath.length > waypoints.length) {
                    console.log('[TowerOptimize] Warning: Optimized path has', optimizedPath.length, 'points but only', waypoints.length, 'waypoints available')
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