// TowerOptimize.js
// Helper for loading tower locations and optimizing mission waypoints toward nearest tower.
// (Note: .pragma library omitted due to tooling parse issue; QML engine still treats this as a shared JS module.)

.import QGroundControl 1.0 as QGC
.import QtPositioning 5.2 as Pos

var towers = []
var config = null
var debugSearchTrees = [] // 存储A*搜索树用于可视化
var weatherSensors = []   // 存储天气区域（suitable/warning/no_fly）
var pathOptManager = null // C++ PathOptimizationManager 实例

// Mirrors QGroundControlQmlGlobal::AltMode values.
var ALTITUDE_MODE_MIXED = 0
var ALTITUDE_MODE_RELATIVE = 1
var ALTITUDE_MODE_ABSOLUTE = 2
var ALTITUDE_MODE_CALC_ABOVE_TERRAIN = 3
var ALTITUDE_MODE_TERRAIN_FRAME = 4
var ALTITUDE_MODE_NONE = 5

// JavaScript日志函数 - 统一通过C++处理
function writeTowerOptimizeLog(message) {
    console.log("[TowerOptimize]", message);
}

function normalizeWeatherType(rawType, radius) {
    var t = (rawType || '').toString().trim().toLowerCase()
    if (t === 'suitable' || t === 'safe' || t === 'fit' || t === '适飞') return 'suitable'
    if (t === 'warning' || t === 'alert' || t === '警戒') return 'warning'
    if (t === 'no_fly' || t === 'nofly' || t === 'no-fly' || t === 'forbidden' || t === '禁飞') return 'no_fly'
    return (radius && radius > 0) ? 'no_fly' : 'suitable'
}

function isNoFlySensor(sensor) {
    return sensor && sensor.weatherType === 'no_fly'
}

function isWarningSensor(sensor) {
    return sensor && sensor.weatherType === 'warning'
}

function isSuitableSensor(sensor) {
    return sensor && sensor.weatherType === 'suitable'
}

function warningRadius(sensor) {
    if (!sensor) return 0
    if (sensor.influenceRadius && sensor.influenceRadius > 0) return sensor.influenceRadius
    return Math.max(120, (sensor.radius || 0) + 200)
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

function _averageAltitudeForCoordinates(coords) {
    var altitudeSum = 0
    var altitudeCount = 0
    for (var i = 0; i < coords.length; i++) {
        var coord = coords[i]
        if (!coord) continue
        var alt = Number(coord.altitude)
        if (isFinite(alt) && alt > 0) {
            altitudeSum += alt
            altitudeCount++
        }
    }
    return altitudeCount > 0 ? (altitudeSum / altitudeCount) : 100.0
}

function _buildCoordinateFromCpp(cppCoord, fallbackAltitude) {
    return Pos.QtPositioning.coordinate(
        cppCoord.latitude,
        cppCoord.longitude,
        (!isNaN(cppCoord.altitude) && cppCoord.altitude > 0) ? cppCoord.altitude : fallbackAltitude
    )
}

function _applyInsertedWaypointAltitude(item, altitude) {
    if (!item || !isFinite(altitude)) {
        return
    }
    if (item.altitude && item.altitude.rawValue !== undefined) {
        item.altitude.rawValue = altitude
    }
    if (item.dirty !== undefined) item.dirty = true
}

function _moveDetourEndpointOutOfHardConstraints(item, prevCoord, nextCoord, weatherBufferMeters, reasonTag) {
    if (!item || !item.coordinate || !item.coordinate.isValid) {
        return null
    }

    var coord = item.coordinate
    var moved = false
    var locked = _isLockedMissionEndpoint(item)

    if (_hasWeatherCollisionAt(coord)) {
        if (locked) {
            console.warn('[TowerOptimize] Locked endpoint stays inside weather no-fly zone during', reasonTag, 'detour')
            return null
        }

        var escapedWeatherCoord = _findWaypointEscapeFromWeather(coord, prevCoord, nextCoord, weatherBufferMeters)
        if (!escapedWeatherCoord) {
            console.warn('[TowerOptimize] Could not derive weather-safe detour anchor for', reasonTag)
            return null
        }
        coord = escapedWeatherCoord
        moved = true
    }

    if (_hasWeatherCollisionAt(coord)) {
        console.warn('[TowerOptimize] Detour anchor for', reasonTag, 'is still inside hard constraints')
        return null
    }

    if (moved) {
        item.coordinate = coord
        if (item.dirty !== undefined) item.dirty = true
        item._collisionMoved = true
        console.info('[TowerOptimize] Re-anchored', reasonTag, 'detour endpoint to',
                     coord.latitude.toFixed(6), coord.longitude.toFixed(6))
    }

    return coord
}

function _tryInsertCppOptimizedSegmentDetour(missionController, item1, item2, insertIndex, reasonTag) {
    if (!missionController || !pathOptManager || !pathOptManager.towerOptimizer || !item1 || !item2) {
        return false
    }

    var weatherBufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)
    var startCoord2d = _moveDetourEndpointOutOfHardConstraints(item1, null, item2.coordinate, weatherBufferMeters, reasonTag)
    if (!startCoord2d) {
        return false
    }

    var endCoord2d = _moveDetourEndpointOutOfHardConstraints(item2, item1.coordinate, null, weatherBufferMeters, reasonTag)
    if (!endCoord2d) {
        return false
    }

    var homeAltitude = _plannedHomeAltitude(missionController)
    var startAmslAltitude = _amslAltitudeFromItem(item1, homeAltitude)
    var endAmslAltitude = _amslAltitudeFromItem(item2, homeAltitude)
    if (!isFinite(startAmslAltitude)) {
        startAmslAltitude = Number(item1.coordinate.altitude)
    }
    if (!isFinite(endAmslAltitude)) {
        endAmslAltitude = Number(item2.coordinate.altitude)
    }

    var startCoord = _coordinateWithAltitude(item1.coordinate, startAmslAltitude)
    var endCoord = _coordinateWithAltitude(item2.coordinate, endAmslAltitude)
    if (!startCoord.isValid || !endCoord.isValid) {
        return false
    }

    try {
        var originalPath = [startCoord, endCoord]
        var avgAltitude = _interpolateFiniteValue(startAmslAltitude, endAmslAltitude, 0.5, _averageAltitudeForCoordinates(originalPath))
        var optimizedPath = pathOptManager.towerOptimizer.optimizePathAStarNew(originalPath, avgAltitude)
        if (!optimizedPath || optimizedPath.length < 3) {
            console.warn('[TowerOptimize] C++ detour for', reasonTag, 'segment returned', optimizedPath ? optimizedPath.length : 0, 'points')
            return false
        }

        for (var segIdx = 0; segIdx < optimizedPath.length - 1; segIdx++) {
            var segStart = _buildCoordinateFromCpp(optimizedPath[segIdx], avgAltitude)
            var segEnd = _buildCoordinateFromCpp(optimizedPath[segIdx + 1], avgAltitude)
            if (_hasWeatherCollisionAt(segStart) || _hasWeatherCollisionAt(segEnd)) {
                console.warn('[TowerOptimize] C++ detour for', reasonTag, 'contains colliding waypoint; reject')
                return false
            }
            if (findSegmentCollision(segStart, segEnd, weatherBufferMeters)) {
                console.warn('[TowerOptimize] C++ detour for', reasonTag, 'still collides on a sub-segment; reject')
                return false
            }
        }

        for (var mid = optimizedPath.length - 2; mid >= 1; mid--) {
            var ratio = mid / (optimizedPath.length - 1)
            var rawAltitude = _rawAltitudeAtRatio(item1, item2, ratio)
            var fallbackAltitude = _interpolateFiniteValue(startAmslAltitude, endAmslAltitude, ratio, avgAltitude)
            var midCoord = _buildCoordinateFromCpp(optimizedPath[mid], isFinite(rawAltitude) ? rawAltitude : fallbackAltitude)
            var insertedItem = missionController.insertSimpleMissionItem(midCoord, insertIndex, false)
            _applyInsertedWaypointAltitude(insertedItem, isFinite(rawAltitude) ? rawAltitude : fallbackAltitude)
            if (insertedItem) {
                insertedItem._collisionMoved = true
                insertedItem.dirty = true
            }
        }

        console.info('[TowerOptimize] Inserted C++', reasonTag, 'detour with', optimizedPath.length - 2, 'intermediate waypoint(s)')
        return true
    } catch (cppDetourError) {
        console.error('[TowerOptimize] C++ detour for', reasonTag, 'segment failed:', cppDetourError)
        return false
    }
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
                            var parsedRadius = Number(item.no_fly_radius)
                            if (!isFinite(parsedRadius)) parsedRadius = 600
                            var parsedWeatherType = normalizeWeatherType(item.weather_type, parsedRadius)
                            var parsedWarningLevel = Number(item.warning_level)
                            if (!isFinite(parsedWarningLevel)) parsedWarningLevel = (parsedWeatherType === 'warning' ? 1 : 0)
                            var parsedAvoidWeight = Number(item.avoid_weight)
                            if (!isFinite(parsedAvoidWeight)) parsedAvoidWeight = (parsedWeatherType === 'warning' ? 0.6 : 1.0)
                            var parsedInfluenceRadius = Number(item.influence_radius)
                            if (!isFinite(parsedInfluenceRadius)) parsedInfluenceRadius = 0

                            if (parsedWeatherType === 'suitable') {
                                parsedRadius = 0
                                parsedWarningLevel = 0
                                parsedAvoidWeight = 0
                            } else if (parsedWeatherType === 'warning') {
                                parsedWarningLevel = Math.max(1, Math.min(5, parsedWarningLevel))
                                parsedAvoidWeight = Math.max(0, Math.min(3, parsedAvoidWeight))
                                if (parsedInfluenceRadius <= 0) parsedInfluenceRadius = Math.max(120, parsedRadius + 200)
                            } else {
                                parsedWeatherType = 'no_fly'
                                parsedWarningLevel = Math.max(1, Math.min(5, parsedWarningLevel || 3))
                                parsedAvoidWeight = Math.max(1, parsedAvoidWeight || 1)
                                if (parsedRadius <= 0) parsedRadius = Math.max(100, parsedInfluenceRadius || 100)
                                if (parsedInfluenceRadius <= 0) parsedInfluenceRadius = parsedRadius
                            }

                            weatherSensors.push({
                                lat: item.latitude || item.lat,
                                lon: item.longitude || item.lon,
                                name: item.name || '',
                                radius: parsedRadius,
                                direction: item.direction || 'up',
                                weatherType: parsedWeatherType,
                                warningLevel: parsedWarningLevel,
                                avoidWeight: parsedAvoidWeight,
                                influenceRadius: parsedInfluenceRadius
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
    if (visualItems.count < 2) return
    
    if (!towers.length) {
        console.warn('[TowerOptimize] No towers loaded, abort A* optimize')
        return
    }
    
    // 清除之前的debug数据
    clearDebugSearchTrees()
    options = (typeof options === 'object' && options) ? options : {}
    
    // 从配置文件读取A*参数
    var cellSize = options.cellSizeMeters || getConfig('astar', 'cellSizeMeters', 30)
    var radiusCells = options.radiusCells || getConfig('astar', 'radiusCells', 10)
    var wDev = options.weightDeviation || getConfig('astar', 'weightDeviation', 0.25)
    var wSig = options.weightSignal || getConfig('astar', 'weightSignal', 18000)
    var maxIterations = options.maxIterations || getConfig('astar', 'maxIterations', 8000)
    var corridorBaseMeters = getConfig('astar', 'corridor.baseMeters', 25.0)
    var corridorSegmentRatio = getConfig('astar', 'corridor.segmentRatio', 0.18)
    var corridorMaxMeters = getConfig('astar', 'corridor.maxMeters', 80.0)
    var collisionRelaxMultiplier = getConfig('astar', 'corridor.collisionRelaxMultiplier', 3.0)
    var densifyTargetSpacingMeters = isFinite(options.bridgeTargetSpacingMeters) ? options.bridgeTargetSpacingMeters : 320.0
    var densifyMinSegmentLengthMeters = isFinite(options.bridgeMinSegmentLengthMeters) ? options.bridgeMinSegmentLengthMeters : 260.0
    var densifyMaxInsertPerSegment = isFinite(options.bridgeMaxInsertPerSegment) ? Math.max(1, Math.round(options.bridgeMaxInsertPerSegment)) : 2

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

    function isPathWaypointItem(item) {
        return !!item
            && !!item.coordinate
            && item.coordinate.isValid
            && item.specifiesCoordinate
            && !item.isStandaloneCoordinate
    }

    function isOptimizableMissionItem(item) {
        return isPathWaypointItem(item)
            && item.isSimpleItem
            && !item.isTakeoffItem
            && !item.isLandCommand
    }

    function describeMissionItem(item) {
        if (!item) {
            return 'null-item'
        }
        return 'simple=' + item.isSimpleItem
            + ' takeoff=' + item.isTakeoffItem
            + ' land=' + item.isLandCommand
            + ' standalone=' + item.isStandaloneCoordinate
            + ' specifiesCoord=' + item.specifiesCoordinate
            + ' validCoord=' + (!!item.coordinate && item.coordinate.isValid)
    }

    function collectPathWaypoints() {
        var out = []
        // visualItems[0] is the mission settings/home item, not a user waypoint.
        for (var i = 1; i < visualItems.count; i++) {
            var item = visualItems.get(i)
            if (!isPathWaypointItem(item)) continue
            out.push({
                visualIndex: i,
                item: item,
                adjustable: isOptimizableMissionItem(item)
            })
        }
        return out
    }

    function interpolateCoordinate(a, b, t) {
        var altA = (!isNaN(a.altitude) && a.altitude !== undefined) ? a.altitude : 0
        var altB = (!isNaN(b.altitude) && b.altitude !== undefined) ? b.altitude : altA
        return Pos.QtPositioning.coordinate(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
            altA + (altB - altA) * t
        )
    }

    function averageAltitudeForCoordinates(coords) {
        var altitudeSum = 0
        var altitudeCount = 0
        for (var i = 0; i < coords.length; i++) {
            var coord = coords[i]
            if (!coord) continue
            var alt = coord.altitude
            if (!isNaN(alt) && alt > 0) {
                altitudeSum += alt
                altitudeCount++
            }
        }
        return altitudeCount > 0 ? (altitudeSum / altitudeCount) : 100.0
    }

    function buildCoordinateFromCpp(cppCoord, fallbackAltitude) {
        return Pos.QtPositioning.coordinate(
            cppCoord.latitude,
            cppCoord.longitude,
            (!isNaN(cppCoord.altitude) && cppCoord.altitude > 0) ? cppCoord.altitude : fallbackAltitude
        )
    }

    function altitudeAtRatio(startCoord, endCoord, ratio) {
        var startAlt = (!isNaN(startCoord.altitude) && startCoord.altitude !== undefined) ? startCoord.altitude : 0
        var endAlt = (!isNaN(endCoord.altitude) && endCoord.altitude !== undefined) ? endCoord.altitude : startAlt
        return startAlt + (endAlt - startAlt) * ratio
    }

    function applyInsertedWaypointAltitude(item, altitude) {
        if (!item || !isFinite(altitude)) {
            return
        }
        if (item.altitude && item.altitude.rawValue !== undefined) {
            item.altitude.rawValue = altitude
        }
        if (item.dirty !== undefined) item.dirty = true
    }

    function tryInsertCppOptimizedSegmentDetour(item1, item2, insertIndex, reasonTag) {
        if (!pathOptManager || !pathOptManager.towerOptimizer || !item1 || !item2) {
            return false
        }

        var homeAltitude = _plannedHomeAltitude(missionController)
        var startAmslAltitude = _amslAltitudeFromItem(item1, homeAltitude)
        var endAmslAltitude = _amslAltitudeFromItem(item2, homeAltitude)
        var startCoord = _coordinateWithAltitude(item1.coordinate, startAmslAltitude)
        var endCoord = _coordinateWithAltitude(item2.coordinate, endAmslAltitude)

        if (!startCoord.isValid || !endCoord.isValid) {
            return false
        }

        try {
            var originalPath = [startCoord, endCoord]
            var avgAltitude = _interpolateFiniteValue(startAmslAltitude, endAmslAltitude, 0.5, averageAltitudeForCoordinates(originalPath))
            var optimizedPath = pathOptManager.towerOptimizer.optimizePathAStarNew(originalPath, avgAltitude)
            if (!optimizedPath || optimizedPath.length < 3) {
                console.warn('[TowerOptimize] C++ detour for', reasonTag, 'segment returned', optimizedPath ? optimizedPath.length : 0, 'points')
                return false
            }

            for (var segIdx = 0; segIdx < optimizedPath.length - 1; segIdx++) {
                var segStart = buildCoordinateFromCpp(optimizedPath[segIdx], avgAltitude)
                var segEnd = buildCoordinateFromCpp(optimizedPath[segIdx + 1], avgAltitude)
                if (_hasWeatherCollisionAt(segStart) || _hasWeatherCollisionAt(segEnd)) {
                    console.warn('[TowerOptimize] C++ detour for', reasonTag, 'contains colliding waypoint; reject')
                    return false
                }
                if (findSegmentCollision(segStart, segEnd, getConfig('collision', 'weatherBufferMeters', 5.0))) {
                    console.warn('[TowerOptimize] C++ detour for', reasonTag, 'still collides on a sub-segment; reject')
                    return false
                }
            }

            for (var mid = optimizedPath.length - 2; mid >= 1; mid--) {
                var ratio = mid / (optimizedPath.length - 1)
                var rawAltitude = _rawAltitudeAtRatio(item1, item2, ratio)
                var midCoord = buildCoordinateFromCpp(optimizedPath[mid], rawAltitude)
                var insertedItem = missionController.insertSimpleMissionItem(midCoord, insertIndex, false)
                applyInsertedWaypointAltitude(insertedItem, rawAltitude)
                if (insertedItem) {
                    insertedItem._collisionMoved = true
                    insertedItem.dirty = true
                }
            }

            console.info('[TowerOptimize] Inserted C++', reasonTag, 'detour with', optimizedPath.length - 2, 'intermediate waypoint(s)')
            return true
        } catch (cppDetourError) {
            console.error('[TowerOptimize] C++ detour for', reasonTag, 'segment failed:', cppDetourError)
            return false
        }
    }

    function computeDeviationBudget(origDistToNext, origDistToPrev, allowRelaxedDeviation) {
        var localSegment = origDistToNext
        if (!isNaN(origDistToPrev) && origDistToPrev > 0) {
            localSegment = Math.min(localSegment, origDistToPrev)
        }

        var corridorLimit = Math.max(corridorBaseMeters, localSegment * corridorSegmentRatio)
        corridorLimit = Math.min(corridorLimit, corridorMaxMeters)

        if (allowRelaxedDeviation) {
            return Math.max(corridorLimit, Math.min(dynamicDeviationThreshold, corridorMaxMeters * collisionRelaxMultiplier))
        }

        return corridorLimit
    }

    function tryOptimizeTwoPointSegmentWithCppPathAStar(waypoints) {
        if (waypoints.length !== 2 || !pathOptManager || !pathOptManager.towerOptimizer) {
            return false
        }

        var startItem = waypoints[0].item
        var endItem = waypoints[1].item
        if (!startItem || !endItem || !startItem.coordinate || !endItem.coordinate) {
            return false
        }

        var homeAltitude = _plannedHomeAltitude(missionController)
        var startAmslAltitude = _amslAltitudeFromItem(startItem, homeAltitude)
        var endAmslAltitude = _amslAltitudeFromItem(endItem, homeAltitude)
        var startCoord = _coordinateWithAltitude(startItem.coordinate, startAmslAltitude)
        var endCoord = _coordinateWithAltitude(endItem.coordinate, endAmslAltitude)
        var segmentDistance = distanceMeters(startCoord.latitude, startCoord.longitude, endCoord.latitude, endCoord.longitude)
        if (segmentDistance < 140) {
            return false
        }

        try {
            var originalPath = [startCoord, endCoord]
            var avgAltitude = _interpolateFiniteValue(startAmslAltitude, endAmslAltitude, 0.5, averageAltitudeForCoordinates(originalPath))
            console.info('[TowerOptimize] Two-point segment detected, running C++ path A* with distance', segmentDistance.toFixed(2), 'm')

            var optimizedPath = pathOptManager.towerOptimizer.optimizePathAStarNew(originalPath, avgAltitude)
            if (!optimizedPath || optimizedPath.length < 3) {
                console.info('[TowerOptimize] Two-point path A* returned', optimizedPath ? optimizedPath.length : 0, 'points; falling back to bridge-waypoint mode')
                return false
            }

            for (var mid = optimizedPath.length - 2; mid >= 1; mid--) {
                var ratio = mid / (optimizedPath.length - 1)
                var midAltitude = _rawAltitudeAtRatio(startItem, endItem, ratio)
                var midCoord = buildCoordinateFromCpp(optimizedPath[mid], midAltitude)
                var insertedItem = missionController.insertSimpleMissionItem(midCoord, waypoints[1].visualIndex, false)
                applyInsertedWaypointAltitude(insertedItem, midAltitude)
            }

            var weatherEscapes = fixWaypointsInsideWeather(missionController)
            if (weatherEscapes > 0) {
                console.info('[TowerOptimize] Two-point path A* moved', weatherEscapes, 'waypoint(s) out of weather no-fly zones')
            }

            checkAndFixPathSegments(missionController)
            if (planMasterController) planMasterController.dirty = true
            console.info('[TowerOptimize] Two-point path A* inserted', optimizedPath.length - 2, 'intermediate waypoint(s)')
            return true
        } catch (segmentError) {
            console.error('[TowerOptimize] Two-point path A* failed:', segmentError)
            return false
        }
    }

    function ensureBridgeWaypointsForSimpleSegment(waypoints) {
        if (!waypoints || waypoints.length < 2) {
            return waypoints
        }
        var insertedTotal = 0
        var twoPointMission = waypoints.length === 2
        var targetSpacingMeters = twoPointMission ? Math.max(densifyTargetSpacingMeters, 380.0) : densifyTargetSpacingMeters
        var minSegmentLengthMeters = twoPointMission ? Math.max(densifyMinSegmentLengthMeters, 220.0) : densifyMinSegmentLengthMeters
        var maxInsertPerSegment = twoPointMission ? 2 : densifyMaxInsertPerSegment

        for (var seg = waypoints.length - 2; seg >= 0; seg--) {
            var startEntry = waypoints[seg]
            var endEntry = waypoints[seg + 1]
            if (!startEntry || !endEntry || !startEntry.item || !endEntry.item) {
                continue
            }

            var startCoord = startEntry.item.coordinate
            var endCoord = endEntry.item.coordinate
            if (!startCoord || !endCoord || !startCoord.isValid || !endCoord.isValid) {
                continue
            }

            var segmentDistance = distanceMeters(startCoord.latitude, startCoord.longitude, endCoord.latitude, endCoord.longitude)
            if (segmentDistance < minSegmentLengthMeters) {
                continue
            }

            var insertCount = Math.ceil(segmentDistance / targetSpacingMeters) - 1
            if (twoPointMission) {
                insertCount = segmentDistance >= minSegmentLengthMeters ? 2 : 0
            }
            insertCount = Math.max(0, Math.min(maxInsertPerSegment, insertCount))
            if (insertCount < 1) {
                continue
            }

            console.info('[TowerOptimize] Densifying segment', startEntry.visualIndex, '->', endEntry.visualIndex,
                         'distance', segmentDistance.toFixed(2), 'm with', insertCount, 'bridge waypoint(s)')

            var insertIndex = endEntry.visualIndex
            var startRawAltitude = _rawAltitudeFromItem(startEntry.item)
            var endRawAltitude = _rawAltitudeFromItem(endEntry.item)
            var startCoord3d = _coordinateWithAltitude(startCoord, startRawAltitude)
            var endCoord3d = _coordinateWithAltitude(endCoord, endRawAltitude)
            for (var n = insertCount; n >= 1; n--) {
                var t = n / (insertCount + 1)
                var bridgeCoord = interpolateCoordinate(startCoord3d, endCoord3d, t)
                var bridgeItem = missionController.insertSimpleMissionItem(bridgeCoord, insertIndex, false)
                applyInsertedWaypointAltitude(bridgeItem, _interpolateFiniteValue(startRawAltitude, endRawAltitude, t, bridgeCoord.altitude))
                if (bridgeItem) {
                    bridgeItem.dirty = true
                }
            }
            insertedTotal += insertCount
        }

        if (insertedTotal > 0) {
            console.info('[TowerOptimize] Inserted', insertedTotal, 'bridge waypoint(s) across long segment(s)')
            return collectPathWaypoints()
        }

        return waypoints
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

    _markOptimizationFixedEndpoints(missionController)
    var pathWaypoints = collectPathWaypoints()
    console.info('[TowerOptimize] A* collected', pathWaypoints.length, 'path waypoint(s)')
    if (pathWaypoints.length === 2) {
        console.info('[TowerOptimize] Two-point segment detected, using fast segment mode')
        pathWaypoints = ensureBridgeWaypointsForSimpleSegment(pathWaypoints)

        if (pathWaypoints.length === 2) {
            checkAndFixPathSegments(missionController)
            pathWaypoints = collectPathWaypoints()
        }
    } else {
        pathWaypoints = ensureBridgeWaypointsForSimpleSegment(pathWaypoints)
    }

    if (pathWaypoints.length < 2) {
        console.warn('[TowerOptimize] Not enough eligible waypoint items for A* optimize')
        for (var dumpIndex = 0; dumpIndex < visualItems.count; dumpIndex++) {
            var dumpItem = visualItems.get(dumpIndex)
            console.warn('[TowerOptimize] visualItem[' + dumpIndex + '] ' + describeMissionItem(dumpItem))
        }
        return
    }

    if (pathWaypoints.length < 3) {
        console.warn('[TowerOptimize] A* keeps segment endpoints fixed; no interior waypoint available to optimize')
        return
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

    function coordinateForEntry(entry) {
        if (!entry || !entry.item) {
            return Pos.QtPositioning.coordinate()
        }
        return entry.pendingCoordinate || entry.item.coordinate
    }

    function applyPendingCoordinateUpdates(entries) {
        if (!entries) {
            return
        }

        for (var ei = 0; ei < entries.length; ei++) {
            var entry = entries[ei]
            if (!entry || !entry.item || !entry.pendingCoordinate || !entry.pendingCoordinate.isValid) {
                continue
            }

            var currentCoord = entry.item.coordinate
            if (currentCoord
                    && currentCoord.isValid
                    && Math.abs(currentCoord.latitude - entry.pendingCoordinate.latitude) < 1e-10
                    && Math.abs(currentCoord.longitude - entry.pendingCoordinate.longitude) < 1e-10
                    && Math.abs((currentCoord.altitude || 0) - (entry.pendingCoordinate.altitude || 0)) < 1e-6) {
                continue
            }

            entry.item.coordinate = entry.pendingCoordinate
            if (entry.item.dirty !== undefined) entry.item.dirty = true
        }
    }

    // 碰撞检测和移动函数
    function checkAndMoveOutOfCollision(coord) {
        // 使用JavaScript本地的weatherSensors数据
        if (!weatherSensors || weatherSensors.length === 0) {
            return coord
        }

        var bufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)
        
        // 找到最近的碰撞sensor
        var minDist = Infinity
        var nearestSensor = null
        
        for (var i = 0; i < weatherSensors.length; i++) {
            var sensor = weatherSensors[i]
            if (!isNoFlySensor(sensor)) {
                continue
            }
            var dist = distanceMeters(coord.latitude, coord.longitude, sensor.lat, sensor.lon)
            // weatherSensors使用radius字段
            var sensorRadius = sensor.radius || 100
            // 碰撞检测阈值：noFlyRadius + buffer
            var collisionRadius = sensorRadius + bufferMeters
            
            if (dist < collisionRadius && dist < minDist) {
                minDist = dist
                nearestSensor = sensor
                nearestSensor.effectiveRadius = sensorRadius  // 保存实际使用的半径
            }
        }

        if (!nearestSensor) {
            return coord  // 无碰撞
        }
        
        console.warn('[TowerOptimize] Collision detected! Distance=' + minDist.toFixed(2) + 
                     'm, threshold=' + (nearestSensor.effectiveRadius + bufferMeters).toFixed(2) + 'm')
        
        // 计算从sensor到当前点的方向
        var latDiff = coord.latitude - nearestSensor.lat
        var lonDiff = coord.longitude - nearestSensor.lon
        var bearing = Math.atan2(latDiff, lonDiff)
        
        // 移动到安全距离：noFlyRadius + buffer + 10m
        var safeDistance = nearestSensor.effectiveRadius + bufferMeters + 10
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

    function adjustWaypoint(entry, nextEntry, prevEntry, index) {
        if (!entry || !entry.item || !nextEntry || !nextEntry.item) return

        var item = entry.item
        var orig = coordinateForEntry(entry)
        var next = coordinateForEntry(nextEntry)
        if (!orig.isValid || !next.isValid) return
        var origWeatherCollision = checkWeatherCollision(orig.latitude, orig.longitude)
        var origDistToPrev = NaN
        
        var origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)

        // 保护机制：原始waypoint间距太小时，减少优化强度
        if (origDistToNext < 60) {
            console.warn('[TowerOptimize] Original distance', origDistToNext.toFixed(2), 'm < 60m, skipping optimization to avoid over-clustering')
            return
        }
        
        if (prevEntry) {
            var prevC = coordinateForEntry(prevEntry)
            origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
        }

        var checkedCoord = checkAndMoveOutOfCollision(orig)
        if (checkedCoord.latitude !== orig.latitude || checkedCoord.longitude !== orig.longitude) {
            console.warn('[TowerOptimize] Waypoint', index, 'moved out of collision zone')
            orig = checkedCoord
            entry.pendingCoordinate = checkedCoord
            item._collisionMoved = true  // 标记为避障移动，防止被合并删除
            origDistToNext = distanceMeters(orig.latitude, orig.longitude, next.latitude, next.longitude)
        }
        
        // 尝试使用C++实现
        if (pathOptManager) {
            try {
                // 获取prev坐标（如果存在）
                var prev = (prevEntry && coordinateForEntry(prevEntry).isValid)
                    ? coordinateForEntry(prevEntry)
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
                
                // 计算偏离原始位置的距离
                var deviationFromOrig = distanceMeters(newCoord.latitude, newCoord.longitude, orig.latitude, orig.longitude)

                // 硬约束：常规任务严格限制在原航线附近，只有天气/禁飞等硬碰撞才放宽。
                var maxDeviation = computeDeviationBudget(origDistToNext, origDistToPrev, item._collisionMoved || origWeatherCollision)
                if (deviationFromOrig > maxDeviation) {
                    var discountLinear = maxDeviation / deviationFromOrig
                    var discount = discountLinear * discountLinear  // 平方衰减
                    console.warn('[TowerOptimize] Deviation', deviationFromOrig.toFixed(2), 'm exceeds', maxDeviation.toFixed(2), 'm, applying squared discount', discount.toFixed(3))
                    
                    var adjustedLat = orig.latitude + (newCoord.latitude - orig.latitude) * discount
                    var adjustedLon = orig.longitude + (newCoord.longitude - orig.longitude) * discount
                    newCoord = Pos.QtPositioning.coordinate(adjustedLat, adjustedLon, orig.altitude)
                }
                
                // 间距检查（保留JavaScript的检查逻辑）
                var revert = false
                var dNext = distanceMeters(newCoord.latitude, newCoord.longitude, next.latitude, next.longitude)
                
                // 硬性约束：最小间距
                if (dNext < minSeparation) {
                    console.warn('[TowerOptimize] C++ result: too close to next', dNext.toFixed(2), 'm')
                    revert = true
                }
                
                // 软约束：保持原始间距的合理比例（40%-250%）
                var distRatio = dNext / origDistToNext
                if (distRatio < 0.4 || distRatio > 2.5) {
                    console.warn('[TowerOptimize] C++ result: distance ratio', distRatio.toFixed(2), 'out of range [0.4, 2.5]')
                    revert = true
                }
                
                if (prevEntry) {
                    var prevC = coordinateForEntry(prevEntry)
                    var dPrev = distanceMeters(newCoord.latitude, newCoord.longitude, prevC.latitude, prevC.longitude)
                    var origDistToPrev = distanceMeters(orig.latitude, orig.longitude, prevC.latitude, prevC.longitude)
                    
                    if (dPrev < minSeparation) {
                        console.warn('[TowerOptimize] C++ result: too close to prev', dPrev.toFixed(2), 'm')
                        revert = true
                    }
                    
                    var prevDistRatio = dPrev / origDistToPrev
                    if (prevDistRatio < 0.4 || prevDistRatio > 2.5) {
                        console.warn('[TowerOptimize] C++ result: prev distance ratio', prevDistRatio.toFixed(2), 'out of range [0.4, 2.5]')
                        revert = true
                    }
                }
                
                if (!revert) {
                    entry.pendingCoordinate = newCoord
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
        var weatherPenaltyCache = {}

        function weatherPenaltyAt(lat, lon) {
            if (!getConfig('collision', 'weatherCollisionCheck', true)) return 0
            var penalty = 0
            var bufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)
            for (var si = 0; si < weatherSensors.length; si++) {
                var sensor = weatherSensors[si]
                if (isSuitableSensor(sensor)) continue

                var dist = distanceMeters(lat, lon, sensor.lat, sensor.lon)
                if (isNoFlySensor(sensor)) {
                    var hardRadius = (sensor.radius || 0) + bufferMeters
                    if (hardRadius > 0 && dist < hardRadius) {
                        return Infinity
                    }
                    if (hardRadius > 0 && dist < hardRadius * 1.5) {
                        var noFlyWeightRaw = (sensor.avoidWeight !== undefined) ? sensor.avoidWeight : 1.0
                        var noFlyWeight = Math.max(1.0, noFlyWeightRaw)
                        var nearFactor = (hardRadius * 1.5 - dist) / (hardRadius * 0.5)
                        penalty += nearFactor * noFlyWeight * 1000.0
                    }
                } else if (isWarningSensor(sensor)) {
                    var influence = warningRadius(sensor)
                    if (influence > 0 && dist < influence) {
                        var avoidWeightRaw = (sensor.avoidWeight !== undefined) ? sensor.avoidWeight : 0.6
                        var warningLevelRaw = (sensor.warningLevel !== undefined) ? sensor.warningLevel : 1
                        var avoidWeight = Math.max(0, Math.min(3, avoidWeightRaw))
                        var warningLevel = Math.max(1, Math.min(5, warningLevelRaw))
                        var normalize = (influence - dist) / Math.max(influence, 1)
                        penalty += normalize * avoidWeight * warningLevel * 800.0
                    }
                }
            }
            return penalty
        }

        function weatherPenaltyValue(gx, gy) {
            var key = gx + ',' + gy
            if (weatherPenaltyCache[key] !== undefined) return weatherPenaltyCache[key]
            var c = toCoord(gx, gy)
            var result = weatherPenaltyAt(c.latitude, c.longitude)
            weatherPenaltyCache[key] = result
            return result
        }
        
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
        var startWeatherPenalty = weatherPenaltyValue(0, 0)
        if (!isFinite(startWeatherPenalty)) startWeatherPenalty = 1e9
        start.f = start.g + wDev*start.dev + start.h - wSig*start.sig + startWeatherPenalty
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
                var childCoord = toCoord(ngx, ngy)
                var weatherPenalty = weatherPenaltyValue(ngx, ngy)
                if (!isFinite(weatherPenalty)) continue
                var stepCost = (dx===0 || dy===0) ? cellSize : cellSize * 1.41421356
                var g = current.g + stepCost
                var dev = deviationCost(ngx, ngy)
                var sig = signalValue(ngx, ngy)
                var h = heuristic(ngx, ngy)
                var f = g + wDev*dev + h - wSig*sig + weatherPenalty
                var existing = open[key]
                
                // 记录边连接
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
        var deviationFromOrigJs = distanceMeters(newCoord.latitude, newCoord.longitude, orig.latitude, orig.longitude)
        var maxDeviationJs = computeDeviationBudget(origDistToNext, origDistToPrev, item._collisionMoved || origWeatherCollision)
        if (deviationFromOrigJs > maxDeviationJs) {
            console.warn('[TowerOptimize] Revert: deviation', deviationFromOrigJs.toFixed(2), 'm exceeds hard corridor', maxDeviationJs.toFixed(2), 'm')
            revert = true
        }
        
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
        
        if (prevEntry) {
            var prevC = coordinateForEntry(prevEntry)
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
            entry.pendingCoordinate = newCoord
            debugTree.applied = true
            debugTree.finalCoord = { lat: newCoord.latitude, lon: newCoord.longitude }
        } else {
            // Keep original (no move)
            console.warn('[TowerOptimize] Revert idx', index, 'to original due to spacing violation', dNext.toFixed(2), 'm')
            debugTree.applied = false
            debugTree.revertReason = 'spacing_violation'
        }
        
        // 保存debug数据
        debugSearchTrees.push(debugTree)
    }

    console.info('[TowerOptimize] A* processing', pathWaypoints.length - 2, 'interior waypoint(s)')
    for (var wi = 1; wi < pathWaypoints.length - 1; wi++) {
        var currentWp = pathWaypoints[wi]
        var prevWp = pathWaypoints[wi - 1]
        var nextWp = pathWaypoints[wi + 1]
        if (!currentWp || !currentWp.item || !nextWp || !nextWp.item) continue
        if (!currentWp.adjustable) {
            console.info('[TowerOptimize] Skipping non-adjustable interior waypoint', currentWp.visualIndex)
            continue
        }
        adjustWaypoint(currentWp, nextWp, prevWp, currentWp.visualIndex)
    }
    applyPendingCoordinateUpdates(pathWaypoints)
    // Additional spacing validation pass; compare only actual path waypoints.
    var validatedPathWaypoints = collectPathWaypoints()
    for (var vi = 1; vi < validatedPathWaypoints.length; vi++) {
        var currEntry = validatedPathWaypoints[vi]
        var prevEntry = validatedPathWaypoints[vi - 1]
        if (!currEntry || !prevEntry || !currEntry.item || !prevEntry.item) continue
        var curr = currEntry.item
        var prev = prevEntry.item
        if (!curr.coordinate || !prev.coordinate) continue
        var sep = distanceMeters(curr.coordinate.latitude, curr.coordinate.longitude, prev.coordinate.latitude, prev.coordinate.longitude)
        if (sep < safeSeparation) {
            // revert current to original snapshot
            for (var oi=0; oi<originalCoords.length; oi++) {
                if (originalCoords[oi].index === currEntry.visualIndex) {
                    var recO = originalCoords[oi]
                    curr.coordinate = recO.coord
                    if (curr.dirty !== undefined) curr.dirty = true
                    console.warn('[TowerOptimize] Reverted idx', currEntry.visualIndex, 'due to close separation', sep.toFixed(2),'m')
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
    
    var movedOutOfWeather = fixWaypointsInsideWeather(missionController)
    if (movedOutOfWeather > 0) {
        console.info('[TowerOptimize] Moved', movedOutOfWeather, 'waypoint(s) out of weather no-fly zones before building/path fixing')
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
    checkAndFixPathSegments(missionController)
    
    if (planMasterController) planMasterController.dirty = true
    console.info('[TowerOptimize] optimizeMissionAStar A* applied')
}

function _collectMissionPathWaypoints(missionController) {
    var out = []
    if (!missionController || !missionController.visualItems) {
        return out
    }

    var visualItems = missionController.visualItems
    for (var i = 1; i < visualItems.count; i++) {
        var item = visualItems.get(i)
        if (!item || !item.coordinate || !item.coordinate.isValid) continue
        if (!item.specifiesCoordinate || item.isStandaloneCoordinate) continue
        out.push({
            visualIndex: i,
            item: item
        })
    }

    return out
}

function _isEndpointCandidate(item) {
    return !!item
        && !!item.coordinate
        && item.coordinate.isValid
        && item.specifiesCoordinate
        && !item.isStandaloneCoordinate
        && item.isSimpleItem
        && !item.isTakeoffItem
        && !item.isLandCommand
}

function _clearOptimizationFixedEndpoints(missionController) {
    if (!missionController || !missionController.visualItems) {
        return
    }

    var visualItems = missionController.visualItems
    for (var i = 0; i < visualItems.count; i++) {
        var item = visualItems.get(i)
        if (!item) continue
        item._optimizerFixedEndpoint = false
    }
}

function _markOptimizationFixedEndpoints(missionController) {
    _clearOptimizationFixedEndpoints(missionController)

    var pathWaypoints = _collectMissionPathWaypoints(missionController)
    if (pathWaypoints.length < 1) {
        return
    }

    var firstEntry = pathWaypoints[0]
    var lastEntry = pathWaypoints[pathWaypoints.length - 1]

    if (firstEntry && firstEntry.item) {
        firstEntry.item._optimizerFixedEndpoint = true
    }
    if (lastEntry && lastEntry.item) {
        lastEntry.item._optimizerFixedEndpoint = true
    }

    console.info('[TowerOptimize] Fixed mission endpoints:',
                 firstEntry ? firstEntry.visualIndex : -1,
                 lastEntry ? lastEntry.visualIndex : -1)
}

function _isLockedMissionEndpoint(item) {
    return !!(item && item._optimizerFixedEndpoint)
}

function _plannedHomeAltitude(missionController) {
    if (missionController && missionController.plannedHomePosition && missionController.plannedHomePosition.isValid) {
        var homeAltitude = Number(missionController.plannedHomePosition.altitude)
        if (isFinite(homeAltitude)) {
            return homeAltitude
        }
    }

    if (missionController && missionController.visualItems && missionController.visualItems.count > 0) {
        var homeItem = missionController.visualItems.get(0)
        var homeTerrainAltitude = _terrainAltitudeFromItem(homeItem)
        if (isFinite(homeTerrainAltitude)) {
            return homeTerrainAltitude
        }

        var homeAmslAltitude = Number(homeItem ? homeItem.amslEntryAlt : NaN)
        if (isFinite(homeAmslAltitude)) {
            return homeAmslAltitude
        }
    }

    var pathWaypoints = _collectMissionPathWaypoints(missionController)
    if (pathWaypoints.length > 0) {
        var firstItem = pathWaypoints[0].item
        var firstTerrainAltitude = _terrainAltitudeFromItem(firstItem)
        if (isFinite(firstTerrainAltitude)) {
            return firstTerrainAltitude
        }

        var firstAmslAltitude = Number(firstItem ? firstItem.amslEntryAlt : NaN)
        var firstRawAltitude = _rawAltitudeFromItem(firstItem)
        if (isFinite(firstAmslAltitude) && isFinite(firstRawAltitude)) {
            return firstAmslAltitude - firstRawAltitude
        }
    }

    if (missionController && missionController.simpleFlightPathSegments
            && missionController.simpleFlightPathSegments.count > 0) {
        var firstSegment = missionController.simpleFlightPathSegments.get(0)
        if (firstSegment) {
            if (firstSegment.amslTerrainHeights && firstSegment.amslTerrainHeights.length) {
                for (var i = 0; i < firstSegment.amslTerrainHeights.length; i++) {
                    var segmentTerrainAltitude = Number(firstSegment.amslTerrainHeights[i])
                    if (isFinite(segmentTerrainAltitude)) {
                        console.info('[TowerOptimize] Using first segment terrain as home altitude fallback:',
                                     segmentTerrainAltitude.toFixed(2))
                        return segmentTerrainAltitude
                    }
                }
            }

            if (pathWaypoints.length > 0) {
                var segmentAmslAltitude = Number(firstSegment.coord1AMSLAlt)
                var segmentRawAltitude = _rawAltitudeFromItem(pathWaypoints[0].item)
                if (isFinite(segmentAmslAltitude) && isFinite(segmentRawAltitude)) {
                    return segmentAmslAltitude - segmentRawAltitude
                }
            }
        }
    }

    return NaN
}

function _coordinateWithAltitude(coord, altitude) {
    if (!coord || !coord.isValid) {
        return Pos.QtPositioning.coordinate()
    }
    return Pos.QtPositioning.coordinate(coord.latitude, coord.longitude, altitude)
}

function _interpolateFiniteValue(startValue, endValue, ratio, fallbackValue) {
    var hasStart = isFinite(startValue)
    var hasEnd = isFinite(endValue)
    if (hasStart && hasEnd) {
        return startValue + (endValue - startValue) * ratio
    }
    if (hasStart) {
        return startValue
    }
    if (hasEnd) {
        return endValue
    }
    return fallbackValue
}

function _altitudeModeFromItem(item) {
    if (!item || item.altitudeMode === undefined) {
        return ALTITUDE_MODE_RELATIVE
    }

    var altitudeMode = Number(item.altitudeMode)
    return isFinite(altitudeMode) ? altitudeMode : ALTITUDE_MODE_RELATIVE
}

function _terrainAltitudeFromItem(item) {
    if (!item) {
        return NaN
    }

    var terrainAltitude = Number(item.terrainAltitude)
    return isFinite(terrainAltitude) ? terrainAltitude : NaN
}

function _rawAltitudeFromItem(item) {
    if (!item) return NaN
    if (item.altitude && item.altitude.rawValue !== undefined) {
        var rawAlt = Number(item.altitude.rawValue)
        if (isFinite(rawAlt)) {
            return rawAlt
        }
    }
    return NaN
}

function _amslAltitudeFromItem(item, homeAltitude) {
    if (!item) return NaN
    var amslAlt = Number(item.amslEntryAlt)
    if (isFinite(amslAlt)) {
        return amslAlt
    }

    var rawAlt = _rawAltitudeFromItem(item)
    if (!isFinite(rawAlt)) {
        return NaN
    }

    var altitudeMode = _altitudeModeFromItem(item)
    if (altitudeMode === ALTITUDE_MODE_RELATIVE) {
        return isFinite(homeAltitude) ? (rawAlt + homeAltitude) : NaN
    }
    if (altitudeMode === ALTITUDE_MODE_ABSOLUTE) {
        return rawAlt
    }
    if (altitudeMode === ALTITUDE_MODE_CALC_ABOVE_TERRAIN || altitudeMode === ALTITUDE_MODE_TERRAIN_FRAME) {
        var terrainAltitude = _terrainAltitudeFromItem(item)
        return isFinite(terrainAltitude) ? (rawAlt + terrainAltitude) : NaN
    }

    return isFinite(homeAltitude) ? (rawAlt + homeAltitude) : rawAlt
}

function _rawAltitudeAtRatio(startItem, endItem, ratio) {
    return _interpolateFiniteValue(
        _rawAltitudeFromItem(startItem),
        _rawAltitudeFromItem(endItem),
        ratio,
        NaN
    )
}

function _rawAltitudeForTargetAmsl(item, targetAmsl, homeAltitude, fallbackTerrainAltitude) {
    if (!item || !isFinite(targetAmsl)) {
        return NaN
    }

    var altitudeMode = _altitudeModeFromItem(item)
    if (altitudeMode === ALTITUDE_MODE_RELATIVE) {
        if (isFinite(homeAltitude)) {
            return targetAmsl - homeAltitude
        }

        var currentRelativeRaw = _rawAltitudeFromItem(item)
        var currentRelativeAmsl = Number(item ? item.amslEntryAlt : NaN)
        if (isFinite(currentRelativeRaw) && isFinite(currentRelativeAmsl)) {
            return currentRelativeRaw + (targetAmsl - currentRelativeAmsl)
        }

        var localTerrainAltitude = _terrainAltitudeFromItem(item)
        if (!isFinite(localTerrainAltitude)) {
            localTerrainAltitude = fallbackTerrainAltitude
        }
        if (isFinite(localTerrainAltitude)) {
            // When planned home AMSL is missing, fall back to the local terrain reference.
            // This keeps the clearance adjustment conservative and prevents a silent no-op.
            return targetAmsl - localTerrainAltitude
        }

        return NaN
    }
    if (altitudeMode === ALTITUDE_MODE_ABSOLUTE) {
        return targetAmsl
    }
    if (altitudeMode === ALTITUDE_MODE_CALC_ABOVE_TERRAIN || altitudeMode === ALTITUDE_MODE_TERRAIN_FRAME) {
        var terrainAltitude = _terrainAltitudeFromItem(item)
        if (!isFinite(terrainAltitude)) {
            terrainAltitude = fallbackTerrainAltitude
        }
        return isFinite(terrainAltitude) ? (targetAmsl - terrainAltitude) : NaN
    }

    var currentRaw = _rawAltitudeFromItem(item)
    var currentAmsl = _amslAltitudeFromItem(item, homeAltitude)
    if (isFinite(currentRaw) && isFinite(currentAmsl)) {
        return currentRaw + (targetAmsl - currentAmsl)
    }

    return NaN
}

function _minimumSafeTargetAmsl(item, minTerrainClearanceMeters, fallbackTerrainAltitude) {
    var terrainAltitude = _terrainAltitudeFromItem(item)
    if (!isFinite(terrainAltitude)) {
        terrainAltitude = fallbackTerrainAltitude
    }
    if (!isFinite(terrainAltitude)) {
        return NaN
    }

    return terrainAltitude + minTerrainClearanceMeters
}

function _prepareBuildingCorridor(pathWaypoints, paddingMeters) {
    if (!pathWaypoints || pathWaypoints.length < 2 || !pathOptManager || !pathOptManager.towerOptimizer) {
        return
    }

    var anchors = []
    for (var i = 0; i < pathWaypoints.length; i++) {
        var entry = pathWaypoints[i]
        if (!entry || !entry.item || !entry.item.coordinate || !entry.item.coordinate.isValid) continue
        anchors.push(entry.item.coordinate)
    }

    if (anchors.length < 2) {
        return
    }

    try {
        pathOptManager.towerOptimizer.setFeatureCorridor(anchors, paddingMeters)
    } catch (error) {
        console.warn('[TowerOptimize] Failed to prepare building corridor:', error)
    }
}

function _hasAnyBuildingHeightData() {
    if (!pathOptManager || !pathOptManager.towerOptimizer || !pathOptManager.towerOptimizer.buildingHeightFeatureCount) {
        return false
    }

    try {
        return Number(pathOptManager.towerOptimizer.buildingHeightFeatureCount()) > 0
    } catch (error) {
        console.warn('[TowerOptimize] Failed to query building height feature count:', error)
        return false
    }
}

function _buildingHeightAtCoord(coord) {
    if (!coord || !coord.isValid || !pathOptManager || !pathOptManager.towerOptimizer) {
        return 0
    }

    try {
        var heightMeters = Number(pathOptManager.towerOptimizer.buildingHeightAt(coord))
        return (isFinite(heightMeters) && heightMeters > 0) ? heightMeters : 0
    } catch (error) {
        console.warn('[TowerOptimize] Building height probe failed:', error)
        return 0
    }
}

function _maxBuildingHeightFromSegment(segment, sampleSpacingMeters) {
    if (!segment || !segment.coordinate1 || !segment.coordinate2
            || !segment.coordinate1.isValid || !segment.coordinate2.isValid
            || !pathOptManager || !pathOptManager.towerOptimizer) {
        return 0
    }

    try {
        var heightMeters = Number(pathOptManager.towerOptimizer.maxBuildingHeightAlongSegment(
            segment.coordinate1,
            segment.coordinate2,
            sampleSpacingMeters))
        return (isFinite(heightMeters) && heightMeters > 0) ? heightMeters : 0
    } catch (error) {
        console.warn('[TowerOptimize] Segment building-height probe failed:', error)
        return 0
    }
}

function _raiseItemAltitudeToAmsl(item, targetAmsl, homeAltitude, reason, fallbackTerrainAltitude) {
    if (!item || !isFinite(targetAmsl)) {
        return false
    }

    var currentRaw = _rawAltitudeFromItem(item)
    if (!isFinite(currentRaw)) {
        return false
    }

    var currentAmsl = _amslAltitudeFromItem(item, homeAltitude)
    var minTerrainClearanceMeters = getConfig('collision', 'minWaypointTerrainClearanceMeters', 20.0)
    var effectiveTargetAmsl = targetAmsl
    var localSafetyFloor = _minimumSafeTargetAmsl(item, minTerrainClearanceMeters, fallbackTerrainAltitude)
    if (isFinite(localSafetyFloor)) {
        effectiveTargetAmsl = Math.max(effectiveTargetAmsl, localSafetyFloor)
    }

    var newRawAltitude = _rawAltitudeForTargetAmsl(item, effectiveTargetAmsl, homeAltitude, fallbackTerrainAltitude)
    if (!isFinite(newRawAltitude)) {
        return false
    }

    newRawAltitude = Math.max(newRawAltitude, currentRaw)
    if (newRawAltitude <= currentRaw + 0.05) {
        return false
    }

    if (item.altitude && item.altitude.rawValue !== undefined) {
        item.altitude.rawValue = newRawAltitude
    }

    if (item.dirty !== undefined) item.dirty = true
    return true
}

function _maxTerrainHeightFromSegment(segment) {
    if (!segment || !segment.amslTerrainHeights || !segment.amslTerrainHeights.length) {
        return NaN
    }

    var maxHeight = NaN
    for (var i = 0; i < segment.amslTerrainHeights.length; i++) {
        var height = Number(segment.amslTerrainHeights[i])
        if (!isFinite(height)) continue
        if (!isFinite(maxHeight) || height > maxHeight) {
            maxHeight = height
        }
    }

    return maxHeight
}

function _matchWaypointIndexForSegmentCoord(pathWaypoints, coord, hintIndex) {
    if (!pathWaypoints || !coord || !coord.isValid) {
        return -1
    }

    var bestIndex = -1
    var bestDistance = Infinity
    var startIndex = (hintIndex !== undefined && hintIndex >= 0) ? hintIndex : 0

    function scanRange(begin, end) {
        for (var i = begin; i < end; i++) {
            var wp = pathWaypoints[i]
            if (!wp || !wp.item || !wp.item.coordinate || !wp.item.coordinate.isValid) continue
            var wpCoord = wp.item.coordinate
            var dist = distanceMeters(coord.latitude, coord.longitude, wpCoord.latitude, wpCoord.longitude)
            if (dist < bestDistance) {
                bestDistance = dist
                bestIndex = i
                if (dist < 1.0) {
                    return true
                }
            }
        }
        return false
    }

    if (!scanRange(startIndex, pathWaypoints.length)) {
        scanRange(0, startIndex)
    }

    return bestDistance <= 25.0 ? bestIndex : -1
}

function applyTerrainClearancePass(missionController, planMasterController, options) {
    options = (typeof options === 'object' && options) ? options : {}

    var result = {
        adjustedCount: 0,
        collidingCount: 0,
        pendingTerrainCount: 0,
        floorAdjustedCount: 0,
        buildingAdjustedCount: 0,
        buildingSegmentCount: 0,
        missingHomeAltitude: false
    }

    if (!missionController || !missionController.simpleFlightPathSegments) {
        return result
    }

    var pathWaypoints = _collectMissionPathWaypoints(missionController)
    if (pathWaypoints.length < 2) {
        return result
    }

    var segmentModel = missionController.simpleFlightPathSegments
    var homeAltitude = _plannedHomeAltitude(missionController)
    var minTerrainClearanceMeters = getConfig('collision', 'minWaypointTerrainClearanceMeters', 20.0)
    var buildingClearanceMeters = Math.max(
        getConfig('collision', 'buildingClearance', 5.0),
        getConfig('collision', 'minWaypointBuildingClearanceMeters', 8.0)
    )
    var buildingSampleSpacingMeters = getConfig('collision', 'buildingSampleSpacingMeters', 25.0)
    var buildingCorridorPaddingMeters = getConfig('collision', 'buildingCorridorPaddingMeters', 180.0)
    var requiredAboveTerrain = Math.max(
        minTerrainClearanceMeters,
        getConfig('collision', 'minAltitudeAGL', 5.0) + getConfig('collision', 'terrainClearance', 2.0)
    )
    var lastMatchedIndex = 0
    var hasBuildingHeightData = _hasAnyBuildingHeightData()
    result.missingHomeAltitude = !isFinite(homeAltitude)

    console.info('[TowerOptimize] Clearance inputs:',
                 'homeAltitude=', isFinite(homeAltitude) ? homeAltitude.toFixed(2) : 'NaN',
                 'terrainFloor=', requiredAboveTerrain.toFixed(2),
                 'buildingClearance=', buildingClearanceMeters.toFixed(2),
                 'hasBuildingHeightData=', hasBuildingHeightData)

    if (hasBuildingHeightData) {
        _prepareBuildingCorridor(pathWaypoints, buildingCorridorPaddingMeters)
        hasBuildingHeightData = _hasAnyBuildingHeightData()
    }

    for (var wpIndex = 0; wpIndex < pathWaypoints.length; wpIndex++) {
        var pathWaypoint = pathWaypoints[wpIndex]
        if (!pathWaypoint || !pathWaypoint.item) {
            continue
        }

        var minWaypointAmsl = _minimumSafeTargetAmsl(pathWaypoint.item, minTerrainClearanceMeters, NaN)
        if (_raiseItemAltitudeToAmsl(
                pathWaypoint.item,
                minWaypointAmsl,
                homeAltitude,
                'local terrain safety floor waypoint ' + pathWaypoint.visualIndex,
                NaN)) {
            result.adjustedCount++
            result.floorAdjustedCount++
        }

        var buildingHeightMeters = hasBuildingHeightData ? _buildingHeightAtCoord(pathWaypoint.item.coordinate) : 0
        var waypointTerrainAltitude = _terrainAltitudeFromItem(pathWaypoint.item)
        if (buildingHeightMeters > 0 && isFinite(waypointTerrainAltitude)) {
            var buildingWaypointTargetAmsl = waypointTerrainAltitude + buildingHeightMeters + buildingClearanceMeters
            if (_raiseItemAltitudeToAmsl(
                    pathWaypoint.item,
                    buildingWaypointTargetAmsl,
                    homeAltitude,
                    'local building safety floor waypoint ' + pathWaypoint.visualIndex,
                    waypointTerrainAltitude)) {
                result.adjustedCount++
                result.buildingAdjustedCount++
            }
        }
    }

    for (var segIndex = 0; segIndex < segmentModel.count; segIndex++) {
        var segment = segmentModel.get(segIndex)
        if (!segment || !segment.coordinate1 || !segment.coordinate2) {
            continue
        }

        var maxTerrainHeight = _maxTerrainHeightFromSegment(segment)
        var maxBuildingHeight = hasBuildingHeightData ? _maxBuildingHeightFromSegment(segment, buildingSampleSpacingMeters) : 0
        var hasBuildingConstraint = maxBuildingHeight > 0
        if (!segment.terrainCollision && !hasBuildingConstraint) {
            continue
        }
        if (segment.terrainCollision) {
            result.collidingCount++
        }
        if (hasBuildingConstraint) {
            result.buildingSegmentCount++
        }

        var leftIndex = _matchWaypointIndexForSegmentCoord(pathWaypoints, segment.coordinate1, lastMatchedIndex)
        var rightIndex = _matchWaypointIndexForSegmentCoord(pathWaypoints, segment.coordinate2, leftIndex >= 0 ? leftIndex : lastMatchedIndex)
        if (leftIndex < 0 || rightIndex < 0 || rightIndex < leftIndex) {
            console.warn('[TowerOptimize] Terrain clearance could not map segment', segIndex, 'to mission waypoints')
            continue
        }

        lastMatchedIndex = leftIndex

        var leftWaypoint = pathWaypoints[leftIndex]
        var rightWaypoint = pathWaypoints[rightIndex]
        var fallbackTerrainHeight = maxTerrainHeight
        if (!isFinite(fallbackTerrainHeight) && leftWaypoint && rightWaypoint) {
            var leftTerrainHeight = _terrainAltitudeFromItem(leftWaypoint.item)
            var rightTerrainHeight = _terrainAltitudeFromItem(rightWaypoint.item)
            if (isFinite(leftTerrainHeight) || isFinite(rightTerrainHeight)) {
                fallbackTerrainHeight = Math.max(
                    isFinite(leftTerrainHeight) ? leftTerrainHeight : -Infinity,
                    isFinite(rightTerrainHeight) ? rightTerrainHeight : -Infinity
                )
            }
        }

        var targetAmsl = NaN
        if (segment.terrainCollision && isFinite(fallbackTerrainHeight)) {
            targetAmsl = fallbackTerrainHeight + requiredAboveTerrain
        }
        if (hasBuildingConstraint && isFinite(fallbackTerrainHeight)) {
            var buildingTargetAmsl = fallbackTerrainHeight + maxBuildingHeight + buildingClearanceMeters
            targetAmsl = isFinite(targetAmsl) ? Math.max(targetAmsl, buildingTargetAmsl) : buildingTargetAmsl
        }
        if (!isFinite(targetAmsl)) {
            result.pendingTerrainCount++
            continue
        }

        var touched = {}
        var raiseIndices = [leftIndex, rightIndex]

        for (var raisePos = 0; raisePos < raiseIndices.length; raisePos++) {
            var pathIndex = raiseIndices[raisePos]
            if (pathIndex < 0 || pathIndex >= pathWaypoints.length || touched[pathIndex]) continue
            touched[pathIndex] = true

            var waypoint = pathWaypoints[pathIndex]
            if (!waypoint || !waypoint.item) continue

            if (_raiseItemAltitudeToAmsl(
                    waypoint.item,
                    targetAmsl,
                    homeAltitude,
                    'terrain segment ' + segIndex + ' waypoint ' + waypoint.visualIndex,
                    fallbackTerrainHeight)) {
                result.adjustedCount++
                if (hasBuildingConstraint) {
                    result.buildingAdjustedCount++
                }
            }
        }
    }

    if (result.adjustedCount > 0 && planMasterController) {
        planMasterController.dirty = true
    }

    console.info('[TowerOptimize] Terrain clearance pass:',
                 'adjusted=', result.adjustedCount,
                 'floorAdjusted=', result.floorAdjustedCount,
                 'buildingAdjusted=', result.buildingAdjustedCount,
                 'buildingSegments=', result.buildingSegmentCount,
                 'colliding=', result.collidingCount,
                 'pendingTerrain=', result.pendingTerrainCount,
                 'missingHomeAltitude=', result.missingHomeAltitude)

    return result
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

    _markOptimizationFixedEndpoints(missionController)

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
        if (!isNoFlySensor(sensor)) {
            continue
        }
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

    _markOptimizationFixedEndpoints(missionController)
    
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

function _hasBuildingCollisionAt(coord) {
    return false
}

function _hasWeatherCollisionAt(coord) {
    if (!coord || !coord.isValid || !pathOptManager || !pathOptManager.towerOptimizer) {
        return false
    }

    try {
        return pathOptManager.towerOptimizer.checkWeatherCollision(coord)
    } catch (error) {
        console.warn('[TowerOptimize] Weather collision probe failed:', error)
        return false
    }
}

function _weatherCollisionSensorAt(coord, weatherBufferMeters) {
    if (!coord || !coord.isValid || !weatherSensors) {
        return null
    }

    var buffer = isFinite(weatherBufferMeters) ? weatherBufferMeters : getConfig('collision', 'weatherBufferMeters', 5.0)

    for (var i = 0; i < weatherSensors.length; i++) {
        var sensor = weatherSensors[i]
        if (!isNoFlySensor(sensor)) {
            continue
        }

        var radius = (sensor.radius || 100) + buffer
        var dist = distanceMeters(coord.latitude, coord.longitude, sensor.lat, sensor.lon)
        if (dist < radius) {
            return sensor
        }
    }

    return null
}

function _interpolateSegmentCoordinate(p1, p2, t) {
    var alt1 = (!isNaN(p1.altitude) && p1.altitude !== undefined) ? p1.altitude : 0
    var alt2 = (!isNaN(p2.altitude) && p2.altitude !== undefined) ? p2.altitude : alt1
    return Pos.QtPositioning.coordinate(
        p1.latitude + (p2.latitude - p1.latitude) * t,
        p1.longitude + (p2.longitude - p1.longitude) * t,
        alt1 + (alt2 - alt1) * t
    )
}

function _findBuildingSegmentCollision(p1, p2) {
    return null
}

function _isBuildingSegmentClear(p1, p2) {
    return _findBuildingSegmentCollision(p1, p2) === null
}

function _findBuildingAvoidancePoint(p1, p2, collisionInfo, weatherBufferMeters) {
    if (!collisionInfo || !collisionInfo.coord) {
        return null
    }

    var anchor = collisionInfo.coord
    var segmentBearing = p1.azimuthTo(p2)
    if (!isFinite(segmentBearing)) {
        segmentBearing = 0
    }

    var headingOffsets = [90, -90, 60, -60, 120, -120, 45, -45, 135, -135, 0, 180]
    var minRadius = 18
    var maxRadius = 420
    var radiusStep = 12

    for (var radius = minRadius; radius <= maxRadius; radius += radiusStep) {
        for (var hi = 0; hi < headingOffsets.length; hi++) {
            var heading = segmentBearing + headingOffsets[hi]
            var candidate = anchor.atDistanceAndAzimuth(radius, heading)
            candidate.altitude = anchor.altitude

            if (_hasBuildingCollisionAt(candidate)) {
                continue
            }
            if (!_isBuildingSegmentClear(p1, candidate) || !_isBuildingSegmentClear(candidate, p2)) {
                continue
            }
            if (findSegmentCollision(p1, candidate, weatherBufferMeters) || findSegmentCollision(candidate, p2, weatherBufferMeters)) {
                continue
            }

            return candidate
        }
    }

    return null
}

function _weatherCandidateBearing(p1, p2, sensorCoord) {
    var totalDistance = distanceMeters(p1.latitude, p1.longitude, p2.latitude, p2.longitude)
    var steps = Math.max(12, Math.ceil(totalDistance / 8))
    var bestCoord = p1
    var bestDistance = Infinity

    for (var k = 0; k <= steps; k++) {
        var t = k / steps
        var sample = _interpolateSegmentCoordinate(p1, p2, t)
        var dist = sensorCoord.distanceTo(sample)
        if (dist < bestDistance) {
            bestDistance = dist
            bestCoord = sample
        }
    }

    var bearing = sensorCoord.azimuthTo(bestCoord)
    return isFinite(bearing) ? bearing : 0
}

function _findWeatherAvoidancePoint(p1, p2, sensor, weatherBufferMeters) {
    if (!sensor) {
        return null
    }

    var sensorCoord = Pos.QtPositioning.coordinate(sensor.lat, sensor.lon)
    var baseBearing = _weatherCandidateBearing(p1, p2, sensorCoord)
    var clearanceMeters = Math.max(3, Math.min(6, weatherBufferMeters + 1))
    var baseRadius = Math.max(18, (sensor.radius || 100) + weatherBufferMeters + clearanceMeters)
    var headingOffsets = [90, -90, 75, -75, 105, -105, 60, -60, 120, -120, 45, -45, 135, -135, 0, 180]

    for (var radius = baseRadius; radius <= baseRadius + 140; radius += 8) {
        for (var hi = 0; hi < headingOffsets.length; hi++) {
            var candidate = sensorCoord.atDistanceAndAzimuth(radius, baseBearing + headingOffsets[hi])
            candidate.altitude = p1.altitude

            if (_hasWeatherCollisionAt(candidate) || _hasBuildingCollisionAt(candidate)) {
                continue
            }
            if (findSegmentCollision(p1, candidate, weatherBufferMeters) || findSegmentCollision(candidate, p2, weatherBufferMeters)) {
                continue
            }
            if (!_isBuildingSegmentClear(p1, candidate) || !_isBuildingSegmentClear(candidate, p2)) {
                continue
            }

            return candidate
        }
    }

    return null
}

function _candidateWaypointHeadings(prevCoord, currCoord, nextCoord) {
    var headings = []

    function pushHeading(value) {
        if (!isFinite(value)) {
            return
        }
        var normalized = value % 360
        if (normalized < 0) normalized += 360
        for (var i = 0; i < headings.length; i++) {
            if (Math.abs(headings[i] - normalized) < 0.1) {
                return
            }
        }
        headings.push(normalized)
    }

    if (prevCoord && prevCoord.isValid && nextCoord && nextCoord.isValid) {
        var corridorBearing = prevCoord.azimuthTo(nextCoord)
        pushHeading(corridorBearing + 90)
        pushHeading(corridorBearing - 90)
        pushHeading(corridorBearing + 60)
        pushHeading(corridorBearing - 60)
        pushHeading(corridorBearing + 120)
        pushHeading(corridorBearing - 120)
    }

    if (prevCoord && prevCoord.isValid && currCoord && currCoord.isValid) {
        var fromPrev = prevCoord.azimuthTo(currCoord)
        pushHeading(fromPrev + 90)
        pushHeading(fromPrev - 90)
    }

    if (currCoord && currCoord.isValid && nextCoord && nextCoord.isValid) {
        var toNext = currCoord.azimuthTo(nextCoord)
        pushHeading(toNext + 90)
        pushHeading(toNext - 90)
    }

    for (var angle = 0; angle < 360; angle += 22.5) {
        pushHeading(angle)
    }

    return headings
}

function _findWaypointEscapeFromBuilding(currCoord, prevCoord, nextCoord, weatherBufferMeters) {
    if (!currCoord || !currCoord.isValid) {
        return null
    }

    var headings = _candidateWaypointHeadings(prevCoord, currCoord, nextCoord)
    var best = null
    var origPrevDistance = (prevCoord && prevCoord.isValid) ? distanceMeters(currCoord.latitude, currCoord.longitude, prevCoord.latitude, prevCoord.longitude) : NaN
    var origNextDistance = (nextCoord && nextCoord.isValid) ? distanceMeters(currCoord.latitude, currCoord.longitude, nextCoord.latitude, nextCoord.longitude) : NaN

    for (var radius = 8; radius <= 320; radius += 8) {
        for (var hi = 0; hi < headings.length; hi++) {
            var candidate = currCoord.atDistanceAndAzimuth(radius, headings[hi])
            candidate.altitude = currCoord.altitude

            if (_hasBuildingCollisionAt(candidate) || _hasWeatherCollisionAt(candidate)) {
                continue
            }
            if (prevCoord && prevCoord.isValid) {
                if (!_isBuildingSegmentClear(prevCoord, candidate) || findSegmentCollision(prevCoord, candidate, weatherBufferMeters)) {
                    continue
                }
            }
            if (nextCoord && nextCoord.isValid) {
                if (!_isBuildingSegmentClear(candidate, nextCoord) || findSegmentCollision(candidate, nextCoord, weatherBufferMeters)) {
                    continue
                }
            }

            var score = radius
            if (isFinite(origPrevDistance) && prevCoord && prevCoord.isValid) {
                score += Math.abs(distanceMeters(candidate.latitude, candidate.longitude, prevCoord.latitude, prevCoord.longitude) - origPrevDistance) * 0.15
            }
            if (isFinite(origNextDistance) && nextCoord && nextCoord.isValid) {
                score += Math.abs(distanceMeters(candidate.latitude, candidate.longitude, nextCoord.latitude, nextCoord.longitude) - origNextDistance) * 0.15
            }

            if (!best || score < best.score) {
                best = {
                    coord: candidate,
                    score: score
                }
            }
        }
    }

    return best ? best.coord : null
}

function _findWaypointEscapeFromWeather(currCoord, prevCoord, nextCoord, weatherBufferMeters) {
    if (!currCoord || !currCoord.isValid) {
        return null
    }

    var sensor = _weatherCollisionSensorAt(currCoord, weatherBufferMeters)
    if (!sensor) {
        return null
    }

    var sensorCoord = Pos.QtPositioning.coordinate(sensor.lat, sensor.lon)
    var baseBearing = sensorCoord.azimuthTo(currCoord)
    if (!isFinite(baseBearing)) {
        baseBearing = 0
    }

    var headings = _candidateWaypointHeadings(prevCoord, currCoord, nextCoord)
    var baseRadius = Math.max(18, (sensor.radius || 100) + weatherBufferMeters + 10)
    var best = null
    var origPrevDistance = (prevCoord && prevCoord.isValid) ? distanceMeters(currCoord.latitude, currCoord.longitude, prevCoord.latitude, prevCoord.longitude) : NaN
    var origNextDistance = (nextCoord && nextCoord.isValid) ? distanceMeters(currCoord.latitude, currCoord.longitude, nextCoord.latitude, nextCoord.longitude) : NaN

    function considerCandidate(candidate, scoreBase) {
        if (!candidate || !candidate.isValid) {
            return
        }
        candidate.altitude = currCoord.altitude

        if (_hasWeatherCollisionAt(candidate) || _hasBuildingCollisionAt(candidate)) {
            return
        }
        if (prevCoord && prevCoord.isValid) {
            if (findSegmentCollision(prevCoord, candidate, weatherBufferMeters) || !_isBuildingSegmentClear(prevCoord, candidate)) {
                return
            }
        }
        if (nextCoord && nextCoord.isValid) {
            if (findSegmentCollision(candidate, nextCoord, weatherBufferMeters) || !_isBuildingSegmentClear(candidate, nextCoord)) {
                return
            }
        }

        var score = scoreBase
        if (isFinite(origPrevDistance) && prevCoord && prevCoord.isValid) {
            score += Math.abs(distanceMeters(candidate.latitude, candidate.longitude, prevCoord.latitude, prevCoord.longitude) - origPrevDistance) * 0.15
        }
        if (isFinite(origNextDistance) && nextCoord && nextCoord.isValid) {
            score += Math.abs(distanceMeters(candidate.latitude, candidate.longitude, nextCoord.latitude, nextCoord.longitude) - origNextDistance) * 0.15
        }

        if (!best || score < best.score) {
            best = { coord: candidate, score: score }
        }
    }

    for (var radius = baseRadius; radius <= baseRadius + 220; radius += 10) {
        var weatherHeadings = [baseBearing, baseBearing + 25, baseBearing - 25, baseBearing + 45, baseBearing - 45]
        for (var wh = 0; wh < weatherHeadings.length; wh++) {
            considerCandidate(sensorCoord.atDistanceAndAzimuth(radius, weatherHeadings[wh]), radius)
        }

        var localRadius = Math.max(10, radius - baseRadius + 10)
        for (var hi = 0; hi < headings.length; hi++) {
            considerCandidate(currCoord.atDistanceAndAzimuth(localRadius, headings[hi]), localRadius)
        }
    }

    return best ? best.coord : null
}

function fixWaypointsInsideBuildings(missionController) {
    return 0
}

function fixWaypointsInsideWeather(missionController) {
    if (!missionController) {
        return 0
    }

    var pathWaypoints = _collectMissionPathWaypoints(missionController)
    if (pathWaypoints.length < 1) {
        return 0
    }

    var movedCount = 0
    var weatherBufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)

    for (var i = 0; i < pathWaypoints.length; i++) {
        var entry = pathWaypoints[i]
        var item = entry.item
        if (!item || !item.coordinate || !item.coordinate.isValid) {
            continue
        }
        if (!_hasWeatherCollisionAt(item.coordinate)) {
            continue
        }

        var isBoundaryWaypoint = _isLockedMissionEndpoint(item)
        if (isBoundaryWaypoint) {
            console.warn('[TowerOptimize] Boundary waypoint', entry.visualIndex, 'is inside weather no-fly zone; keeping endpoint fixed')
            continue
        }

        var prevEntry = pathWaypoints[i - 1]
        var nextEntry = pathWaypoints[i + 1]
        var prevCoord = prevEntry && prevEntry.item ? prevEntry.item.coordinate : null
        var nextCoord = nextEntry && nextEntry.item ? nextEntry.item.coordinate : null
        var escapedCoord = _findWaypointEscapeFromWeather(item.coordinate, prevCoord, nextCoord, weatherBufferMeters)

        if (!escapedCoord) {
            console.warn('[TowerOptimize] Could not move waypoint', entry.visualIndex, 'out of weather no-fly zone')
            continue
        }

        item.coordinate = escapedCoord
        if (item.dirty !== undefined) item.dirty = true
        item._collisionMoved = true
        movedCount++
        console.info('[TowerOptimize] Moved waypoint', entry.visualIndex, 'out of weather no-fly zone to',
                     escapedCoord.latitude.toFixed(6), escapedCoord.longitude.toFixed(6))
    }

    return movedCount
}

// 检查并修复路径段碰撞
function checkAndFixPathSegments(missionController) {
    var visualItems = missionController.visualItems
    var bufferMeters = getConfig('collision', 'weatherBufferMeters', 5.0)
    var weatherCollisionEnabled = getConfig('collision', 'weatherCollisionCheck', true)
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
        
        if (!p1.isValid || !p2.isValid) {
            console.warn('[TowerOptimize] Invalid coordinates for segment', i, '->', j)
            i = j // Move to next spatial item
            continue
        }
        
        // 检查段碰撞
        var collision = weatherCollisionEnabled ? findSegmentCollision(p1, p2, bufferMeters) : null
        
            if (collision) {
                console.warn('[TowerOptimize] Segment collision detected between', i, 'and', j, 'Sensor:', collision.sensor.name)
            
            var sensor = collision.sensor
            var startInsideWeather = _hasWeatherCollisionAt(p1)
            var endInsideWeather = _hasWeatherCollisionAt(p2)
            if (startInsideWeather || endInsideWeather) {
                var weatherRecovered = fixWaypointsInsideWeather(missionController)
                if (weatherRecovered > 0) {
                    console.info('[TowerOptimize] Recovered', weatherRecovered, 'weather-colliding waypoint(s) before retrying segment', i, '->', j)
                    fixedCount += weatherRecovered
                    continue
                }

                startInsideWeather = _hasWeatherCollisionAt(item1.coordinate)
                endInsideWeather = _hasWeatherCollisionAt(item2.coordinate)
                var lockedWeatherStart = startInsideWeather && _isLockedMissionEndpoint(item1)
                var lockedWeatherEnd = endInsideWeather && _isLockedMissionEndpoint(item2)

                if (lockedWeatherStart || lockedWeatherEnd) {
                    console.warn('[TowerOptimize] Weather collision detected on segment', i, '->', j, 'but a locked endpoint is inside no-fly zone; keeping locked endpoints fixed')
                    i = j
                    continue
                }

            }

            if (startInsideWeather || endInsideWeather) {
                console.warn('[TowerOptimize] Weather collision detected on segment', i, '->', j, 'and an unlocked endpoint is still inside no-fly zone after recovery')
                i = j
                continue
            }

            var avoidPoint = _findWeatherAvoidancePoint(p1, p2, sensor, bufferMeters)
            if (!avoidPoint) {
                console.warn('[TowerOptimize] Could not find weather avoidance waypoint for segment', i, '->', j)
                i = j
                continue
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
            continue
        }

        // No collision, move to next segment
        i = j
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
        if (!isNoFlySensor(sensor)) {
            continue
        }
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
