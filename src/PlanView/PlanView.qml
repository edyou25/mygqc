/****************************************************************************
 *
 * (c) 2009-2020 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/
// MARK_FROM_VSCODE_2026_01_13
// DEBUG_MARKER_20260113_ABC123

import QtQuick          2.3
import QtQuick.Controls 1.2
import QtQuick.Dialogs  1.2
import QtLocation       5.3
import QtPositioning    5.3
import QtQuick.Layouts  1.2
import QtQuick.Window   2.2
import QtQuick 2.15
import QtQuick.Layouts 1.3
import QtQuick.Controls 1.4
import QGroundControl.Greenland 1.0
import QGroundControl.Water 1.0
import QGroundControl.Building 1.0
import QGroundControl                   1.0
import QGroundControl.FlightMap         1.0
import QGroundControl.ScreenTools       1.0
import QGroundControl.Controls          1.0
import QGroundControl.FactSystem        1.0
import QGroundControl.FactControls      1.0
import QGroundControl.Palette           1.0
import QGroundControl.Controllers       1.0
import QGroundControl.ShapeFileHelper   1.0
import "./TowerOptimize.js" as TowerOpt

Item {
    id: _root
    readonly property string _greenlandDataUrl: "qrc:/data/greenlands.json"
    readonly property string _waterDataUrl: "qrc:/data/waters.json"
    readonly property string _buildingDenseDataUrl: "qrc:/data/buildings_dense.json"
    property var _lastSyncedBuildingAreasForCppRef: null
    property var _cachedBuildingAreasForCppSourceRef: null
    property var _cachedBuildingAreasForCpp: []
    property bool _greenlandPersistenceDisabledLogged: false
    property bool _waterPersistenceDisabledLogged: false
    property bool _buildingPersistenceDisabledLogged: false
    property int _terrainRecoveryPassesRemaining: 0

    function _scheduleTerrainRecoveryPasses(passCount) {
        _terrainRecoveryPassesRemaining = Math.max(0, passCount || 0)
        if (_terrainRecoveryPassesRemaining > 0) {
            _terrainRecoveryTimer.restart()
        }
    }

    function _serializePathPoints(path) {
        var out = []
        if (!path) return out

        for (var i = 0; i < path.length; i++) {
            var c = path[i]
            if (!c || isNaN(c.latitude) || isNaN(c.longitude)) continue
            out.push({ lat: c.latitude, lon: c.longitude, alt: isNaN(c.altitude) ? 0 : c.altitude })
        }
        return out
    }

    function _serializeAreasForCpp(areas, idKey) {
        var out = []
        if (!areas) return out

        for (var i = 0; i < areas.length; i++) {
            var area = areas[i]
            if (!area || !area.path || area.path.length < 3) continue
            var serialized = {
                id: area[idKey],
                path: _serializePathPoints(area.path)
            }

            if (area.heightMeters !== undefined && isFinite(Number(area.heightMeters)) && Number(area.heightMeters) > 0) {
                serialized.heightMeters = Number(area.heightMeters)
            }
            if (area.minHeightMeters !== undefined && isFinite(Number(area.minHeightMeters)) && Number(area.minHeightMeters) > 0) {
                serialized.minHeightMeters = Number(area.minHeightMeters)
            }
            if (area.levels !== undefined && isFinite(Number(area.levels)) && Number(area.levels) > 0) {
                serialized.levels = Number(area.levels)
            }

            out.push(serialized)
        }
        return out
    }

    function _serializeRoadsForCpp() {
        var out = []
        if (!editorMap.roads) return out

        for (var i = 0; i < editorMap.roads.length; i++) {
            var road = editorMap.roads[i]
            if (!road || !road.path || road.path.length < 2) continue
            out.push({
                id: road.id || (i + 1),
                name: road.name || "",
                path: _serializePathPoints(road.path)
            })
        }
        return out
    }

    function _syncPathOptimizationWeightsToCpp() {
        if (typeof PathOptimizationManager === "undefined") return
        if (typeof weightPanel === "undefined" || !weightPanel) return

        PathOptimizationManager.distanceWeight = weightPanel.distanceWeightLocal
        PathOptimizationManager.signalWeight = weightPanel.signalWeightLocal
        PathOptimizationManager.weatherWeight = weightPanel.weatherWeightLocal
        PathOptimizationManager.greenlandWeight = weightPanel.greenlandWeightLocal
        PathOptimizationManager.buildingWeight = weightPanel.buildingWeightLocal
        PathOptimizationManager.waterWeight = weightPanel.waterWeightLocal
        PathOptimizationManager.roadWeight = weightPanel.roadsWeightLocal
    }

    function _syncPathOptimizationFeaturesToCpp() {
        if (typeof PathOptimizationManager === "undefined") return
        if (!PathOptimizationManager.towerOptimizer) return

        if (_cachedBuildingAreasForCppSourceRef !== editorMap.buildingsDense) {
            _cachedBuildingAreasForCpp = _serializeAreasForCpp(editorMap.buildingsDense, "bdid")
            _cachedBuildingAreasForCppSourceRef = editorMap.buildingsDense
        }
        var buildingAreasForCpp = _cachedBuildingAreasForCpp

        PathOptimizationManager.towerOptimizer.setGreenlandAreas(_serializeAreasForCpp(editorMap.greenlands, "gid"))
        PathOptimizationManager.towerOptimizer.setWaterAreas(_serializeAreasForCpp(editorMap.waters, "wid"))
        if (_lastSyncedBuildingAreasForCppRef !== buildingAreasForCpp) {
            PathOptimizationManager.towerOptimizer.setBuildingAreas(buildingAreasForCpp)
            _lastSyncedBuildingAreasForCppRef = buildingAreasForCpp
        }
        PathOptimizationManager.towerOptimizer.setRoads(_serializeRoadsForCpp())

        console.log("[PathOpt] synced features:",
                    "greenland=", editorMap.greenlands ? editorMap.greenlands.length : 0,
                    "water=", editorMap.waters ? editorMap.waters.length : 0,
                    "buildingDisplay=", editorMap.buildingsDense ? editorMap.buildingsDense.length : 0,
                    "buildingCpp=", buildingAreasForCpp.length,
                    "roads=", editorMap.roads ? editorMap.roads.length : 0)
    }

    function _syncPathOptimizationStateToCpp() {
        _syncPathOptimizationWeightsToCpp()
        _syncPathOptimizationFeaturesToCpp()
    }

    Timer {
        id: _terrainRecoveryTimer
        interval: 1000
        repeat: false
        onTriggered: {
            if (_terrainRecoveryPassesRemaining <= 0) {
                return
            }

            var passResult = TowerOpt.applyTerrainClearancePass(_missionController, _planMasterController, {})
            _terrainRecoveryPassesRemaining--

            if (_terrainRecoveryPassesRemaining > 0
                    && (passResult.pendingTerrainCount > 0
                        || passResult.collidingCount > 0
                        || passResult.adjustedCount > 0
                        || passResult.missingHomeAltitude)) {
                _terrainRecoveryTimer.restart()
            }
        }
    }

    function _serializeWaters() {
        var out = []
        if (!editorMap.waters) return "[]"

        for (var i = 0; i < editorMap.waters.length; i++) {
            var a = editorMap.waters[i]
            if (!a || !a.path || a.path.length < 3) continue

            var path = []
            for (var k = 0; k < a.path.length; k++) {
                var c = a.path[k]
                if (!c || isNaN(c.latitude) || isNaN(c.longitude)) continue
                path.push([c.latitude, c.longitude])
            }

            out.push({ wid: a.wid, path: path })
        }
        return JSON.stringify(out)
    }

    function _restoreWatersFromJson(jsonText) {
        var arr
        try {
            arr = JSON.parse(jsonText || "[]")
        } catch (e) {
            console.warn("[Water] JSON parse failed:", e)
            arr = []
        }

        editorMap.waters = []
        editorMap.selectedWaterId = -1
        editorMap.waterEditMode = false

        var maxId = 0
        var restoredAreas = []

        for (var i = 0; i < arr.length; i++) {
            var o = arr[i]
            if (!o || !o.path || o.path.length < 3) continue

            var area = Qt.createQmlObject(
                'import QGroundControl.Water 1.0; WaterArea {}',
                editorMap,
                'WaterAreaPersist' + i
            )

            area.wid = o.wid || 0

            var pathCoords = []
            for (var k = 0; k < o.path.length; k++) {
                var pt = o.path[k]
                if (!pt || pt.length < 2) continue
                pathCoords.push(QtPositioning.coordinate(pt[0], pt[1]))
            }
            area.path = pathCoords

            if (area.wid > maxId) maxId = area.wid
            restoredAreas.push(area)
        }

        editorMap.waters = restoredAreas

        editorMap.waterNextId = Math.max(maxId + 1, 1)

        if (editorMap.waters.length) {
            editorMap.selectedWaterId = editorMap.waters[editorMap.waters.length - 1].wid
        }

        console.log("[Water] restored count=", editorMap.waters.length, "nextId=", editorMap.waterNextId)
    }

    function saveWatersGlobal() {
        editorMap._scheduleRegionVisibleAreasRefresh()
        _syncPathOptimizationStateToCpp()
        if (!_waterPersistenceDisabledLogged) {
            console.log("[Water] persistence disabled; using", _waterDataUrl)
            _waterPersistenceDisabledLogged = true
        }
    }

    function loadWatersGlobal() {
        console.log("[Water] restoring from resource", _waterDataUrl)
        loadWatersFromResource(_waterDataUrl)
    }

    function loadWatersFromResource(url) {
        var dataUrl = url || _waterDataUrl
        var xhr = new XMLHttpRequest()
        xhr.open("GET", dataUrl)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status !== 200 && xhr.status !== 0) {
                console.warn("[Water] Failed to load", dataUrl, "status=", xhr.status)
                _restoreWatersFromJson("[]")
                _syncPathOptimizationStateToCpp()
                return
            }
            _restoreWatersFromJson(xhr.responseText)
            _syncPathOptimizationStateToCpp()
        }
        xhr.send()
    }

    function _pushRegionAttractorsToCpp() {
        _syncPathOptimizationStateToCpp()
    }

    function _serializeGreenlands() {
        var out = []
        if (!editorMap.greenlands) return "[]"

        for (var i = 0; i < editorMap.greenlands.length; i++) {
            var a = editorMap.greenlands[i]
            if (!a || !a.path || a.path.length < 3) continue

            var path = []
            for (var k = 0; k < a.path.length; k++) {
                var c = a.path[k]
                if (!c || isNaN(c.latitude) || isNaN(c.longitude)) continue
                path.push([c.latitude, c.longitude])
            }

            out.push({ gid: a.gid, path: path })
        }
        return JSON.stringify(out)
    }

    function _restoreGreenlandsFromJson(jsonText) {
        var arr
        try {
            arr = JSON.parse(jsonText || "[]")
        } catch (e) {
            console.warn("[Greenland] JSON parse failed:", e)
            arr = []
        }

        // clear current
        editorMap.greenlands = []
        editorMap.selectedGreenlandId = -1
        editorMap.greenlandEditMode = false

        var maxId = 0
        var restoredAreas = []

        for (var i = 0; i < arr.length; i++) {
            var o = arr[i]
            if (!o || !o.path || o.path.length < 3) continue

            var area = Qt.createQmlObject(
                'import QGroundControl.Greenland 1.0; GreenlandArea {}',
                editorMap,
                'GreenlandAreaPersist' + i
            )

            area.gid = o.gid || 0

            var pathCoords = []
            for (var k = 0; k < o.path.length; k++) {
                var pt = o.path[k]
                if (!pt || pt.length < 2) continue
                pathCoords.push(QtPositioning.coordinate(pt[0], pt[1]))
            }
            area.path = pathCoords

            if (area.gid > maxId) maxId = area.gid
            restoredAreas.push(area)
        }

        editorMap.greenlands = restoredAreas

        editorMap.greenlandNextId = Math.max(maxId + 1, 1)

        if (editorMap.greenlands.length) {
            editorMap.selectedGreenlandId = editorMap.greenlands[editorMap.greenlands.length - 1].gid
        }

        console.log("[Greenland] restored count=", editorMap.greenlands.length, "nextId=", editorMap.greenlandNextId)
    }

    function saveGreenlandsGlobal() {
        editorMap._scheduleRegionVisibleAreasRefresh()
        _pushRegionAttractorsToCpp()
        if (!_greenlandPersistenceDisabledLogged) {
            console.log("[Greenland] persistence disabled; using", _greenlandDataUrl)
            _greenlandPersistenceDisabledLogged = true
        }
    }

    function loadGreenlandsGlobal() {
        console.log("[Greenland] restoring from resource", _greenlandDataUrl)
        loadGreenlandsFromResource(_greenlandDataUrl)
    }

    function loadGreenlandsFromResource(url) {
        var dataUrl = url || _greenlandDataUrl
        var xhr = new XMLHttpRequest()
        xhr.open("GET", dataUrl)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status !== 200 && xhr.status !== 0) {
                console.warn("[Greenland] Failed to load", dataUrl, "status=", xhr.status)
                _restoreGreenlandsFromJson("[]")
                _pushRegionAttractorsToCpp()
                return
            }
            _restoreGreenlandsFromJson(xhr.responseText)
            _pushRegionAttractorsToCpp()
        }
        xhr.send()
    }

    // =======================
    // BuildingDense resource loading
    // =======================
    // Building restore state for chunked startup loading
    property var _buildingRestoreArr: []
    property int _buildingRestoreCount: 0
    property int _buildingRestoreCursor: 0
    property int _buildingRestoreMaxId: 0
    property int _buildingRestoreTotalInSettings: 0
    readonly property int _buildingRestoreBatchSize: 24

    function _createBuildingDenseObject(o, objectIndex) {
        if (!o || !o.path || o.path.length < 3) {
            return null
        }

        var area = Qt.createQmlObject(
            "import QGroundControl.Building 1.0; BuildingDense {}",
            editorMap,
            "BuildingDensePersist" + objectIndex
        )

        area.bdid = o.bdid || 0
        if (o.heightMeters !== undefined && isFinite(Number(o.heightMeters))) {
            area.heightMeters = Number(o.heightMeters)
        } else if (o.height !== undefined && isFinite(Number(o.height))) {
            area.heightMeters = Number(o.height)
        }
        if (o.minHeightMeters !== undefined && isFinite(Number(o.minHeightMeters))) {
            area.minHeightMeters = Number(o.minHeightMeters)
        } else if (o.min_height !== undefined && isFinite(Number(o.min_height))) {
            area.minHeightMeters = Number(o.min_height)
        }
        if (o.levels !== undefined && isFinite(Number(o.levels))) {
            area.levels = Number(o.levels)
        } else if (o["building:levels"] !== undefined && isFinite(Number(o["building:levels"]))) {
            area.levels = Number(o["building:levels"])
        }

        var pathCoords = []
        for (var k = 0; k < o.path.length; k++) {
            var pt = o.path[k]
            if (!pt || pt.length < 2) continue
            pathCoords.push(QtPositioning.coordinate(pt[0], pt[1]))
        }
        area.path = pathCoords
        return area
    }

    function _finalizeBuildingsDenseRestore(totalInSettings) {
        editorMap.buildingDenseNextId = Math.max(
            _buildingRestoreMaxId + 1,
            editorMap.buildingDenseNextId || 1
        )
        editorMap.buildingRestoreLoadedCount = editorMap.buildingRestoreTargetCount
        editorMap.buildingRestoreLoading = false
        buildingRestoreDoneToast.restart()

        if (editorMap.buildingsDense.length) {
            editorMap.selectedBuildingDenseId =
                editorMap.buildingsDense[editorMap.buildingsDense.length - 1].bdid
        }

        console.log("[BuildingDense] restored count=", editorMap.buildingsDense.length,
                    "nextId=", editorMap.buildingDenseNextId, "totalInSettings=", totalInSettings)
        _syncPathOptimizationStateToCpp()
    }

    function _serializeBuildingsDense() {
        var out = []
        if (!editorMap.buildingsDense) return "[]"

        for (var i = 0; i < editorMap.buildingsDense.length; i++) {
            var a = editorMap.buildingsDense[i]
            if (!a || !a.path || a.path.length < 3) continue

            var path = []
            for (var k = 0; k < a.path.length; k++) {
                var c = a.path[k]
                if (!c || isNaN(c.latitude) || isNaN(c.longitude)) continue
                path.push([c.latitude, c.longitude])
            }

            var record = { bdid: a.bdid, path: path }
            if (a.heightMeters !== undefined && isFinite(Number(a.heightMeters)) && Number(a.heightMeters) > 0) {
                record.heightMeters = Number(a.heightMeters)
            }
            if (a.minHeightMeters !== undefined && isFinite(Number(a.minHeightMeters)) && Number(a.minHeightMeters) > 0) {
                record.minHeightMeters = Number(a.minHeightMeters)
            }
            if (a.levels !== undefined && isFinite(Number(a.levels)) && Number(a.levels) > 0) {
                record.levels = Number(a.levels)
            }

            out.push(record)
        }
        return JSON.stringify(out)
    }

    function _restoreBuildingsDenseFromJson(jsonText) {
        var arr
        try {
            arr = JSON.parse(jsonText || "[]")
        } catch (e) {
            console.warn("[BuildingDense] JSON parse failed:", e)
            arr = []
        }

        editorMap.buildingsDense = []
        editorMap.selectedBuildingDenseId = -1
        editorMap.buildingDenseEditMode = false
        // Ensure loaded buildings are visible even if user previously toggled the layer off.
        editorMap.showBuildingLayer = true
        editorMap.buildingDenseNextId = 1
        editorMap.buildingRestoreLoading = false
        editorMap.buildingRestoreLoadedCount = 0
        editorMap.buildingRestoreTargetCount = 0
        if (buildingRestoreTimer.running) {
            buildingRestoreTimer.stop()
        }

        var maxId = 0
        for (var ai = 0; ai < arr.length; ai++) {
            if (arr[ai] && arr[ai].bdid && arr[ai].bdid > maxId) {
                maxId = arr[ai].bdid
            }
        }
        _buildingRestoreMaxId = maxId

        // Restore all buildings by default; keep a very high hard cap only for extreme datasets.
        // Startup responsiveness is handled by chunked creation below.
        var loadLimit = 20000
        var restoreCount = Math.min(arr.length, loadLimit)
        if (arr.length > restoreCount) {
            console.warn("[BuildingDense] dataset too large:", arr.length,
                         "loading first", restoreCount, "(hard cap)")
        }
        _buildingRestoreTotalInSettings = arr.length
        editorMap.buildingRestoreTargetCount = restoreCount

        if (restoreCount <= 0) {
            _finalizeBuildingsDenseRestore(arr.length)
            return
        }

        // Small datasets can be restored synchronously.
        if (restoreCount <= 120) {
            var restoredAreas = []
            editorMap.buildingRestoreLoading = true
            for (var i = 0; i < restoreCount; i++) {
                var syncArea = _createBuildingDenseObject(arr[i], i)
                if (syncArea) restoredAreas.push(syncArea)
            }
            editorMap.buildingsDense = editorMap.buildingsDense.concat(restoredAreas)
            editorMap.buildingRestoreLoadedCount = restoreCount
            _finalizeBuildingsDenseRestore(arr.length)
            return
        }

        // Large datasets are restored in batches to avoid blocking first render.
        _buildingRestoreArr = arr
        _buildingRestoreCount = restoreCount
        _buildingRestoreCursor = 0
        editorMap.buildingRestoreLoading = true
        editorMap.buildingRestoreLoadedCount = 0
        buildingRestoreTimer.start()
    }

    function saveBuildingsDenseGlobal() {
        editorMap._scheduleRegionVisibleAreasRefresh()
        _cachedBuildingAreasForCppSourceRef = null
        _syncPathOptimizationStateToCpp()
        if (!_buildingPersistenceDisabledLogged) {
            console.log("[BuildingDense] persistence disabled; using", _buildingDenseDataUrl)
            _buildingPersistenceDisabledLogged = true
        }
    }

    function loadBuildingsDenseGlobal() {
        console.log("[BuildingDense] restoring from resource", _buildingDenseDataUrl)
        loadBuildingsDenseFromResource(_buildingDenseDataUrl)
    }

    function loadBuildingsDenseFromResource(url) {
        var dataUrl = url || _buildingDenseDataUrl
        var xhr = new XMLHttpRequest()
        xhr.open("GET", dataUrl)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status !== 200 && xhr.status !== 0) {
                console.warn("[BuildingDense] Failed to load", dataUrl, "status=", xhr.status)
                _restoreBuildingsDenseFromJson("[]")
                return
            }
            _restoreBuildingsDenseFromJson(xhr.responseText)
        }
        xhr.send()
    }

    // =======================
    // Roads (GeoJSON) loader
    // =======================
    function _parseRoadsFromGeoJSONText(jsonText) {
        var geo
        try {
            geo = JSON.parse(jsonText)
        } catch (e) {
            console.warn("[RoadLayer] GeoJSON parse failed:", e)
            return []
        }

        if (!geo || geo.type !== "FeatureCollection" || !geo.features) {
            console.warn("[RoadLayer] Not a FeatureCollection")
            return []
        }

        var out = []
        var minLat =  90, minLon = 180, maxLat = -90, maxLon = -180
        var nextId = 1

        for (var i = 0; i < geo.features.length; i++) {
            var f = geo.features[i]
            if (!f || !f.geometry) continue
            if (f.geometry.type !== "LineString") continue

            var coords = f.geometry.coordinates
            if (!coords || coords.length < 2) continue

            var path = []
            for (var k = 0; k < coords.length; k++) {
                var pt = coords[k]
                // GeoJSON: [lon, lat]
                if (!pt || pt.length < 2) continue

                var lon = pt[0]
                var lat = pt[1]
                if (isNaN(lat) || isNaN(lon)) continue

                // bbox update
                if (lat < minLat) minLat = lat
                if (lat > maxLat) maxLat = lat
                if (lon < minLon) minLon = lon
                if (lon > maxLon) maxLon = lon

                path.push(QtPositioning.coordinate(lat, lon))
            }
            if (path.length < 2) continue

            var props = f.properties || {}
            var name = props.name || props["name:zh"] || props.ref || props["@id"] || ("Road " + nextId)

            out.push({ id: nextId++, name: name, tags: props, path: path })
        }

        console.log("[RoadLayer] parsed roads:", out.length)
        return out
    }
    function loadRoadsFromResource(url, showAfterLoad) {
        if (editorMap.roadsLoaded) {
            editorMap.showRoadLayer = !!showAfterLoad
            return
        }

        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return

            // status==0 常见于 qrc/本地读取
            if (xhr.status !== 200 && xhr.status !== 0) {
                console.warn("[RoadLayer] Failed to load", url, "status=", xhr.status)
                return
            }

            editorMap.roads = _parseRoadsFromGeoJSONText(xhr.responseText)
            editorMap.roadsLoaded = true
            editorMap.showRoadLayer = !!showAfterLoad
            _syncPathOptimizationStateToCpp()
        }
        xhr.send()
    }
    Timer {
        id: buildingRestoreTimer
        interval: 4
        repeat: true
        running: false
        onTriggered: {
            var batchSize = _buildingRestoreBatchSize
            var end = Math.min(_buildingRestoreCursor + batchSize, _buildingRestoreCount)
            var batchAreas = []
            for (var i = _buildingRestoreCursor; i < end; i++) {
                var area = _createBuildingDenseObject(_buildingRestoreArr[i], i)
                if (area) batchAreas.push(area)
            }
            if (batchAreas.length > 0) {
                editorMap.buildingsDense = editorMap.buildingsDense.concat(batchAreas)
            }
            _buildingRestoreCursor = end
            editorMap.buildingRestoreLoadedCount = _buildingRestoreCursor
            if (_buildingRestoreCursor >= _buildingRestoreCount) {
                stop()
                _buildingRestoreArr = []
                _finalizeBuildingsDenseRestore(_buildingRestoreTotalInSettings)
            }
        }
    }
    Timer {
        id: buildingRestoreDoneToast
        interval: 2200
        repeat: false
    }
    property bool planControlColapsed: false
    property var originalPathForDisplay: []
    property var signalPathForDisplay: []
    property var lengthPathForDisplay: []
    property var smoothPathForDisplay: []
    readonly property int   _decimalPlaces:             8
    readonly property real  _margin:                    ScreenTools.defaultFontPixelHeight * 0.5
    readonly property real  _toolsMargin:               ScreenTools.defaultFontPixelWidth * 0.75
    readonly property real  _radius:                    ScreenTools.defaultFontPixelWidth  * 0.5
    readonly property real  _rightPanelWidth:           Math.min(parent.width / 3, ScreenTools.defaultFontPixelWidth * 30)
    readonly property var   _defaultVehicleCoordinate:  QtPositioning.coordinate(22.71041, 114.40716)
    readonly property bool  _waypointsOnlyMode:         QGroundControl.corePlugin.options.missionWaypointsOnly

    property var    _planMasterController:              planMasterController
    property var    _missionController:                 _planMasterController.missionController
    property var    _geoFenceController:                _planMasterController.geoFenceController
    property var    _rallyPointController:              _planMasterController.rallyPointController
    property var    _visualItems:                       _missionController.visualItems
    property bool   _lightWidgetBorders:                editorMap.isSatelliteMap
    property bool   _addROIOnClick:                     false
    property bool   _singleComplexItem:                 _missionController.complexMissionItemNames.length === 1
    property int    _editingLayer:                      layerTabBar.currentIndex ? _layers[layerTabBar.currentIndex] : _layerMission
    property int    _toolStripBottom:                   toolStrip.height + toolStrip.y
    property var    _appSettings:                       QGroundControl.settingsManager.appSettings
    property var    _planViewSettings:                  QGroundControl.settingsManager.planViewSettings
    property bool   _promptForPlanUsageShowing:         false

    readonly property var       _layers:                [_layerMission, _layerGeoFence, _layerRallyPoints]

    readonly property int       _layerMission:              1
    readonly property int       _layerGeoFence:             2
    readonly property int       _layerRallyPoints:          3
    readonly property string    _armedVehicleUploadPrompt:  qsTr("Vehicle is currently armed. Do you want to upload the mission to the vehicle?")

    function mapCenter() {
        var coordinate = editorMap.center
        coordinate.latitude  = coordinate.latitude.toFixed(_decimalPlaces)
        coordinate.longitude = coordinate.longitude.toFixed(_decimalPlaces)
        coordinate.altitude  = coordinate.altitude.toFixed(_decimalPlaces)
        return coordinate
    }

    property bool _firstMissionLoadComplete:    false
    property bool _firstFenceLoadComplete:      false
    property bool _firstRallyLoadComplete:      false
    property bool _firstLoadComplete:           false

    MapFitFunctions {
        id:                         mapFitFunctions  // The name for this id cannot be changed without breaking references outside of this code. Beware!
        map:                        editorMap
        usePlannedHomePosition:     true
        planMasterController:       _planMasterController
    }

    onVisibleChanged: {
        if(visible) {
            editorMap.zoomLevel = QGroundControl.flightMapZoom
            editorMap.center    = QGroundControl.flightMapPosition
            if (!_planMasterController.containsItems) {
                toolStrip.simulateClick(toolStrip.fileButtonIndex)
            }
        }
    }

    Connections {
        target: _appSettings ? _appSettings.defaultMissionItemAltitude : null
        function onRawValueChanged() {
            if (_visualItems.count > 1) {
                mainWindow.showMessageDialog(qsTr("Apply new altitude"),
                                             qsTr("You have changed the default altitude for mission items. Would you like to apply that altitude to all the items in the current mission?"),
                                             StandardButton.Yes | StandardButton.No,
                                             function() { _missionController.applyDefaultMissionAltitude() })
            }
        }
    }

    Component {
        id: promptForPlanUsageOnVehicleChangePopupComponent
        QGCPopupDialog {
            title:      _planMasterController.managerVehicle.isOfflineEditingVehicle ? qsTr("Plan View - Vehicle Disconnected") : qsTr("Plan View - Vehicle Changed")
            buttons:    StandardButton.NoButton

            ColumnLayout {
                QGCLabel {
                    Layout.maximumWidth:    parent.width
                    wrapMode:               QGCLabel.WordWrap
                    text:                   _planMasterController.managerVehicle.isOfflineEditingVehicle ?
                                                qsTr("The vehicle associated with the plan in the Plan View is no longer available. What would you like to do with that plan?") :
                                                qsTr("The plan being worked on in the Plan View is not from the current vehicle. What would you like to do with that plan?")
                }

                QGCButton {
                    Layout.fillWidth:   true
                    text:               _planMasterController.dirty ?
                                            (_planMasterController.managerVehicle.isOfflineEditingVehicle ?
                                                 qsTr("Discard Unsaved Changes") :
                                                 qsTr("Discard Unsaved Changes, Load New Plan From Vehicle")) :
                                            qsTr("Load New Plan From Vehicle")
                    onClicked: {
                        _planMasterController.showPlanFromManagerVehicle()
                        _promptForPlanUsageShowing = false
                        close();
                    }
                }

                QGCButton {
                    Layout.fillWidth:   true
                    text:               _planMasterController.managerVehicle.isOfflineEditingVehicle ?
                                            qsTr("Keep Current Plan") :
                                            qsTr("Keep Current Plan, Don't Update From Vehicle")
                    onClicked: {
                        if (!_planMasterController.managerVehicle.isOfflineEditingVehicle) {
                            _planMasterController.dirty = true
                        }
                        _promptForPlanUsageShowing = false
                        close()
                    }
                }
            }
        }
    }

    PlanMasterController {
        id:         planMasterController
        flyView:    false

        Component.onCompleted: {
            _planMasterController.start()
            _missionController.setCurrentPlanViewSeqNum(0, true)
            globals.planMasterControllerPlanView = _planMasterController
        }

        onPromptForPlanUsageOnVehicleChange: {
            if (!_promptForPlanUsageShowing) {
                _promptForPlanUsageShowing = true
                promptForPlanUsageOnVehicleChangePopupComponent.createObject(mainWindow).open()
            }
        }

        function waitingOnIncompleteDataMessage(save) {
            var saveOrUpload = save ? qsTr("Save") : qsTr("Upload")
            mainWindow.showMessageDialog(qsTr("Unable to %1").arg(saveOrUpload), qsTr("Plan has incomplete items. Complete all items and %1 again.").arg(saveOrUpload))
        }

        function waitingOnTerrainDataMessage(save) {
            var saveOrUpload = save ? qsTr("Save") : qsTr("Upload")
            mainWindow.showMessageDialog(qsTr("Unable to %1").arg(saveOrUpload), qsTr("Plan is waiting on terrain data from server for correct altitude values."))
        }

        function checkReadyForSaveUpload(save) {
            if (readyForSaveState() == VisualMissionItem.NotReadyForSaveData) {
                waitingOnIncompleteDataMessage(save)
                return false
            } else if (readyForSaveState() == VisualMissionItem.NotReadyForSaveTerrain) {
                waitingOnTerrainDataMessage(save)
                return false
            }
            return true
        }

        function upload() {
            if (!checkReadyForSaveUpload(false /* save */)) {
                return
            }
            switch (_missionController.sendToVehiclePreCheck()) {
                case MissionController.SendToVehiclePreCheckStateOk:
                    sendToVehicle()
                    break
                case MissionController.SendToVehiclePreCheckStateActiveMission:
                    mainWindow.showMessageDialog(qsTr("Send To Vehicle"), qsTr("Current mission must be paused prior to uploading a new Plan"))
                    break
                case MissionController.SendToVehiclePreCheckStateFirwmareVehicleMismatch:
                    mainWindow.showMessageDialog(qsTr("Plan Upload"),
                                                 qsTr("This Plan was created for a different firmware or vehicle type than the firmware/vehicle type of vehicle you are uploading to. " +
                                                      "This can lead to errors or incorrect behavior. " +
                                                      "It is recommended to recreate the Plan for the correct firmware/vehicle type.\n\n" +
                                                      "Click 'Ok' to upload the Plan anyway."),
                                                 StandardButton.Ok | StandardButton.Cancel,
                                                 function() { _planMasterController.sendToVehicle() })
                    break
            }
        }

        function loadFromSelectedFile() {
            fileDialog.title =          qsTr("Select Plan File")
            fileDialog.planFiles =      true
            fileDialog.selectExisting = true
            fileDialog.nameFilters =    _planMasterController.loadNameFilters
            fileDialog.openForLoad()
        }

        function saveToSelectedFile() {
            if (!checkReadyForSaveUpload(true /* save */)) {
                return
            }
            fileDialog.title =          qsTr("Save Plan")
            fileDialog.planFiles =      true
            fileDialog.selectExisting = false
            fileDialog.nameFilters =    _planMasterController.saveNameFilters
            fileDialog.openForSave()
        }

        function fitViewportToItems() {
            mapFitFunctions.fitMapViewportToMissionItems()
        }

        function saveKmlToSelectedFile() {
            if (!checkReadyForSaveUpload(true /* save */)) {
                return
            }
            fileDialog.title =          qsTr("Save KML")
            fileDialog.planFiles =      false
            fileDialog.selectExisting = false
            fileDialog.nameFilters =    ShapeFileHelper.fileDialogKMLFilters
            fileDialog.openForSave()
        }
    }

    Connections {
        target: _missionController

        function onNewItemsFromVehicle() {
            if (_visualItems && _visualItems.count !== 1) {
                mapFitFunctions.fitMapViewportToMissionItems()
            }
            _missionController.setCurrentPlanViewSeqNum(0, true)
        }
    }

    function insertSimpleItemAfterCurrent(coordinate) {
        var nextIndex = _missionController.currentPlanViewVIIndex + 1
        _missionController.insertSimpleMissionItem(coordinate, nextIndex, true /* makeCurrentItem */)
    }

    function insertROIAfterCurrent(coordinate) {
        var nextIndex = _missionController.currentPlanViewVIIndex + 1
        _missionController.insertROIMissionItem(coordinate, nextIndex, true /* makeCurrentItem */)
    }

    function insertCancelROIAfterCurrent() {
        var nextIndex = _missionController.currentPlanViewVIIndex + 1
        _missionController.insertCancelROIMissionItem(nextIndex, true /* makeCurrentItem */)
    }

    function insertComplexItemAfterCurrent(complexItemName) {
        var nextIndex = _missionController.currentPlanViewVIIndex + 1
        _missionController.insertComplexMissionItem(complexItemName, mapCenter(), nextIndex, true /* makeCurrentItem */)
    }

    function insertTakeItemAfterCurrent() {
        var nextIndex = _missionController.currentPlanViewVIIndex + 1
        _missionController.insertTakeoffItem(mapCenter(), nextIndex, true /* makeCurrentItem */)
    }

    function insertLandItemAfterCurrent() {
        var nextIndex = _missionController.currentPlanViewVIIndex + 1
        _missionController.insertLandItem(mapCenter(), nextIndex, true /* makeCurrentItem */)
    }

    function _refreshPathComparisonPanel() {
        if (!comparisonPanelLoader || !comparisonPanelLoader.item) {
            return
        }

        comparisonPanelLoader.item.missionController = _missionController
        comparisonPanelLoader.item.originalPathWaypoints = originalPathForDisplay || []
        comparisonPanelLoader.item.signalPathWaypoints = signalPathForDisplay || []
        comparisonPanelLoader.item.lengthPathWaypoints = lengthPathForDisplay || []
        comparisonPanelLoader.item.smoothPathWaypoints = smoothPathForDisplay || []
        comparisonPanelLoader.item.refresh()
    }

    // Load data once when PlanView root completes
    Component.onCompleted: {
        // JavaScript data load (also initializes C++ backend through TowerOptimize.js).
        TowerOpt.loadTowers()
        // Defer heavy region restore to next event loop tick so UI can render first.
        Qt.callLater(function() {
            // Restore persisted regions. Roads are loaded lazily when user enables road layer.
            loadGreenlandsGlobal()
            loadWatersGlobal()
            loadBuildingsDenseGlobal()
            _pushRegionAttractorsToCpp()
        })
    }


    function selectNextNotReady() {
        var foundCurrent = false
        for (var i=0; i<_missionController.visualItems.count; i++) {
            var vmi = _missionController.visualItems.get(i)
            if (vmi.readyForSaveState === VisualMissionItem.NotReadyForSaveData) {
                _missionController.setCurrentPlanViewSeqNum(vmi.sequenceNumber, true)
                break
            }
        }
    }

    QGCFileDialog {
        id:             fileDialog
        folder:         _appSettings ? _appSettings.missionSavePath : ""

        property bool planFiles: true    ///< true: working with plan files, false: working with kml file

        onAcceptedForSave: {
            if (planFiles) {
                _planMasterController.saveToFile(file)
            } else {
                _planMasterController.saveToKml(file)
            }
            close()
        }

        onAcceptedForLoad: {
            _planMasterController.loadFromFile(file)
            _planMasterController.fitViewportToItems()
            _missionController.setCurrentPlanViewSeqNum(0, true)
            close()
        }
    }

    Item {
        id:             panel
        anchors.fill:   parent

        FlightMap {
            id:                         editorMap
            anchors.fill:               parent
            mapName:                    "MissionEditor"
            allowGCSLocationCenter:     true
            allowVehicleLocationCenter: true
            planView:                   true
            
            property alias astarDebugLayer: astarDebugLayer
            // Weather layer is now handled by FlightMap.qml
            // Road layer state
            // =======================
            property bool showRoadLayer: false
            property bool roadsLoaded: false
            property var roads: []
            zoomLevel:                  QGroundControl.flightMapZoom
            center:                     QGroundControl.flightMapPosition

            // =======================
            // Region layer visibility
            // =======================
            property bool showGreenlandLayer: true
            property bool showWaterLayer: true
            property bool showBuildingLayer: true
            property bool showGreenlandLabels: false
            property bool showWaterLabels: false
            property bool showBuildingLabels: false
            property color greenlandOuterFillColor: "#182E7A24"
            property color greenlandMidFillColor: "#24409A30"
            property color greenlandInnerFillColor: "#365FC544"
            property color greenlandSelectedOuterFillColor: "#203B8F2B"
            property color greenlandSelectedMidFillColor: "#3254B43A"
            property color greenlandSelectedInnerFillColor: "#4878D856"
            property color greenlandBorderGlowColor: "#709CFF7A"
            property color greenlandBorderColor: "#63D94E"
            property color greenlandSelectedBorderColor: "#E9FFD9"
            property color greenlandLabelColor: "#C0104712"
            property color greenlandSelectedLabelColor: "#D7286A2B"
            property color greenlandHandleColor: "#B8FFB0"
            property color greenlandHandleBorderColor: "#286D24"
            property int regionLayerCullPaddingPx: 120
            property bool buildingRestoreLoading: false
            property int buildingRestoreLoadedCount: 0
            property int buildingRestoreTargetCount: 0
            property bool _regionVisibleAreasRefreshQueued: false

            ListModel {
                id: visibleGreenlandsModel
                dynamicRoles: true
            }

            ListModel {
                id: visibleWatersModel
                dynamicRoles: true
            }

            ListModel {
                id: visibleBuildingsDenseModel
                dynamicRoles: true
            }

            function _scheduleRegionVisibleAreasRefresh() {
                _regionVisibleAreasRefreshQueued = true
                _regionVisibleAreasRefreshTimer.restart()
            }

            function _refreshRegionVisibleAreas() {
                _regionVisibleAreasRefreshQueued = false
                _syncVisibleAreaModel(
                    visibleGreenlandsModel,
                    showGreenlandLayer ? greenlands : [],
                    regionLayerCullPaddingPx,
                    selectedGreenlandId,
                    "gid"
                )
                _syncVisibleAreaModel(
                    visibleWatersModel,
                    showWaterLayer ? waters : [],
                    regionLayerCullPaddingPx,
                    selectedWaterId,
                    "wid"
                )
                _syncVisibleAreaModel(
                    visibleBuildingsDenseModel,
                    showBuildingLayer ? buildingsDense : [],
                    regionLayerCullPaddingPx,
                    selectedBuildingDenseId,
                    "bdid"
                )
            }

            Timer {
                id: _regionVisibleAreasRefreshTimer
                interval: 180
                repeat: false
                onTriggered: editorMap._refreshRegionVisibleAreas()
            }

            function toggleAllRegions() {
                var anyOn = showGreenlandLayer || showWaterLayer || showBuildingLayer
                var v = !anyOn
                showGreenlandLayer = v
                showWaterLayer = v
                showBuildingLayer = v
            }

            // This is the center rectangle of the map which is not obscured by tools
            property rect centerViewport:   Qt.rect(_leftToolWidth + _margin,  _margin, editorMap.width - _leftToolWidth - _rightToolWidth - (_margin * 2), (terrainStatus.visible ? terrainStatus.y : height - _margin) - _margin)

            property real _leftToolWidth:       toolStrip.x + toolStrip.width
            property real _rightToolWidth:      rightPanel.width + rightPanel.anchors.rightMargin
            property real _nonInteractiveOpacity:  0.5

            // Initial map position duplicates Fly view position
            Component.onCompleted: {
                editorMap.center = QGroundControl.flightMapPosition
                editorMap._scheduleRegionVisibleAreasRefresh()
                //editorMap._dumpPossibleMapHandles()
            }

            QGCMapPalette { id: mapPal; lightColors: editorMap.isSatelliteMap }
            onZoomLevelChanged: {
                QGroundControl.flightMapZoom = zoomLevel
                _scheduleRegionVisibleAreasRefresh()
            }
            onCenterChanged: {
                QGroundControl.flightMapPosition = center
                _scheduleRegionVisibleAreasRefresh()
            }
            onWidthChanged: _scheduleRegionVisibleAreasRefresh()
            onHeightChanged: _scheduleRegionVisibleAreasRefresh()
            onRegionLayerCullPaddingPxChanged: _scheduleRegionVisibleAreasRefresh()
            onShowGreenlandLayerChanged: _scheduleRegionVisibleAreasRefresh()
            onShowWaterLayerChanged: _scheduleRegionVisibleAreasRefresh()
            onShowBuildingLayerChanged: _scheduleRegionVisibleAreasRefresh()
            onGreenlandsChanged: _scheduleRegionVisibleAreasRefresh()
            onWatersChanged: _scheduleRegionVisibleAreasRefresh()
            onBuildingsDenseChanged: _scheduleRegionVisibleAreasRefresh()
            
            function _vertexModel() {
                var out = []
                if (!greenlands) return out

                for (var gi = 0; gi < greenlands.length; gi++) {
                    var area = greenlands[gi]
                    if (!area || !area.path || area.path.length < 3) continue

                    for (var vi = 0; vi < area.path.length; vi++) {
                        out.push({
                            gid: area.gid,
                            vidx: vi,
                            areaRef: area
                        })
                    }
                }
                return out
            }
            property bool _dragInProgress: false
            property bool _savedMapInteractive: true

            function _setMapInteractiveForGreenlandDrag(enable) {
                // QGC/Qt 版本差异很大，这里做“尽可能”兼容
                // 目标：拖动时让地图别 pan/zoom 来抢 pointer grab

                // 1) 常见：Map.interactive
                try {
                    if (enable) {
                        interactive = _savedMapInteractive
                    } else {
                        _savedMapInteractive = interactive
                        interactive = false
                    }
                    return
                } catch (e) { }

                // 2) 有些版本：Map.gestures.enabled
                try {
                    if (gestures) {
                        gestures.enabled = enable
                        return
                    }
                } catch (e2) { }

                // 3) 再兜底：如果 FlightMap 里暴露了别名（不同QGC可能叫这个）
                try {
                    if (enable) {
                        if (map) map.interactive = true
                    } else {
                        if (map) map.interactive = false
                    }
                } catch (e3) { }
            }
            // Weather layer visibility is now handled by FlightMap.qml

            // Weather layer is now handled by FlightMap.qml WeatherNoFlyLayer
            // Old Repeater removed to avoid conflicts
            MouseArea {
                anchors.fill: parent

                // 关键：编辑模式下彻底禁用这层，避免抢事件
                enabled: !editorMap.greenlandEditMode
                    && !editorMap.waterEditMode
                    && !editorMap.buildingDenseEditMode
                preventStealing: true
                propagateComposedEvents: true

                onPressed: {
                    // 非编辑模式：吃掉事件，由这里处理（加航点/ROI）
                    mouse.accepted = true
                }

                onClicked: {
                    editorMap.focus = true
                    var coordinate = editorMap.toCoordinate(Qt.point(mouse.x, mouse.y), false /* clipToViewPort */)
                    coordinate.latitude = coordinate.latitude.toFixed(_decimalPlaces)
                    coordinate.longitude = coordinate.longitude.toFixed(_decimalPlaces)
                    coordinate.altitude = coordinate.altitude.toFixed(_decimalPlaces)

                    switch (_editingLayer) {
                    case _layerMission:
                        if (addWaypointRallyPointAction.checked) {
                            insertSimpleItemAfterCurrent(coordinate)
                        } else if (_addROIOnClick) {
                            insertROIAfterCurrent(coordinate)
                            _addROIOnClick = false
                        }
                        break
                    case _layerRallyPoints:
                        if (_rallyPointController.supported && addWaypointRallyPointAction.checked) {
                            _rallyPointController.addPoint(coordinate)
                        }
                        break
                    }
                }
            }
            // Add the mission item visuals to the map
            Repeater {
                model: _missionController.visualItems
                delegate: MissionItemMapVisual {
                    map:         editorMap
                    onClicked:   _missionController.setCurrentPlanViewSeqNum(sequenceNumber, false)
                    opacity:     _editingLayer == _layerMission ? 1 : editorMap._nonInteractiveOpacity
                    interactive: _editingLayer == _layerMission
                    vehicle:     _planMasterController.controllerVehicle
                }
            }

            // Add lines between waypoints
            MissionLineView {
                showSpecialVisual:  _missionController.isROIBeginCurrentItem
                model:              _missionController.simpleFlightPathSegments
                opacity:            _editingLayer == _layerMission ? 1 : editorMap._nonInteractiveOpacity
                lineWidth:          9
                lineZ:              QGroundControl.zOrderMapItems + 30
                lineColor:          "#F2FFFFFF"
                collisionLineColor: "#FFFFC9C9"
                specialLineColor:   "#D8FFE8"
            }

            MissionLineView {
                showSpecialVisual:  _missionController.isROIBeginCurrentItem
                model:              _missionController.simpleFlightPathSegments
                opacity:            _editingLayer == _layerMission ? 1 : editorMap._nonInteractiveOpacity
                lineWidth:          4.5
                lineZ:              QGroundControl.zOrderMapItems + 31
                lineColor:          "#156DFF"
                collisionLineColor: "#FF3B30"
                specialLineColor:   "#19C15F"
            }

            MapPolyline {
                id:                 originalPathPolyline
                line.width:         4
                line.color:         '#4569df'
                z:                  QGroundControl.zOrderMapItems + 29
                opacity:            _editingLayer == _layerMission && originalPathForDisplay.length > 0 ? 0.75 : 0
                path:               originalPathForDisplay
            }

            MapPolyline {
                id:                 lengthPathPolyline
                line.width:         3
                line.color:         '#f2a900'
                z:                  QGroundControl.zOrderMapItems + 28
                opacity:            _editingLayer == _layerMission && lengthPathForDisplay.length > 0 ? 0.7 : 0
                path:               lengthPathForDisplay
            }

            MapPolyline {
                id:                 smoothPathPolyline
                line.width:         3
                line.color:         '#2fb66c'
                z:                  QGroundControl.zOrderMapItems + 28
                opacity:            _editingLayer == _layerMission && smoothPathForDisplay.length > 0 ? 0.7 : 0
                path:               smoothPathForDisplay
            }

            // Direction arrows in waypoint lines
            MapItemView {
                model: _editingLayer == _layerMission ? _missionController.directionArrows : undefined

                delegate: MapLineArrow {
                    fromCoord:      object ? object.coordinate1 : undefined
                    toCoord:        object ? object.coordinate2 : undefined
                    arrowPosition:  3
                    z:              QGroundControl.zOrderMapItems + 32
                }
            }

            // Incomplete segment lines
            MapItemView {
                model: _missionController.incompleteComplexItemLines

                delegate: MapPolyline {
                    path:       [ object.coordinate1, object.coordinate2 ]
                    line.width: 1
                    line.color: "red"
                    z:          QGroundControl.zOrderWaypointLines
                    opacity:    _editingLayer == _layerMission ? 1 : editorMap._nonInteractiveOpacity
                }
            }

            // =======================
            // Road layer render (directly on editorMap because editorMap IS a Map)
            // =======================
            MapItemView {
                id: roadLayerView
                visible: editorMap.showRoadLayer
                z: 999999
                model: editorMap.roads

                delegate: MapPolyline {
                    line.width: 6
                    line.color: "magenta"
                    z: 999999
                    path: modelData.path
                }
            }
            // =======================
            // Greenland render + edit handles
            // =======================

            // 1) Polygon (fill + border)

            MapItemView {
                model: visibleGreenlandsModel
                visible: editorMap.showGreenlandLayer
                delegate: MapPolygon {
                    property var area: areaRef
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    path: area && area.path ? area.path : []
                    color: "transparent"
                    border.width: selected ? 9 : 7
                    border.color: editorMap.greenlandBorderGlowColor
                    z: QGroundControl.zOrderWaypointLines + 4
                    opacity: selected ? 0.95 : 0.72
                }
            }

            MapItemView {
                model: visibleGreenlandsModel
                visible: editorMap.showGreenlandLayer
                delegate: MapPolygon {
                    id: poly
                    property var area: areaRef
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    path: area && area.path ? area.path : []

                    color: selected ? editorMap.greenlandSelectedOuterFillColor : editorMap.greenlandOuterFillColor
                    border.width: selected ? 5 : 4
                    border.color: selected ? editorMap.greenlandSelectedBorderColor : editorMap.greenlandBorderColor

                    z: QGroundControl.zOrderWaypointLines + 5
                    opacity: 1

                    // 编辑模式开启时，点击用于选中/插点
                    MouseArea {
                        anchors.fill: parent
                        enabled: editorMap.greenlandEditMode
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (!area) return

                            editorMap.selectedGreenlandId = area.gid

                            // 仅在编辑模式下：点击边缘附近 => 插入顶点
                            if (editorMap.greenlandEditMode) {
                                var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                if (editorMap._insertVertexAtClick(area, mapP)) {
                                    saveGreenlandsGlobal()
                                }
                            }
                        }
                    }
                }
            }
            MapItemView {
                model: visibleGreenlandsModel
                visible: editorMap.showGreenlandLayer
                delegate: MapPolygon {
                    property var area: areaRef
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    visible: area && area.path && area.path.length >= 3
                    path: visible ? editorMap._scalePathTowardCenter(area.path, 0.82) : []
                    color: selected ? editorMap.greenlandSelectedMidFillColor : editorMap.greenlandMidFillColor
                    border.width: 0
                    border.color: "transparent"
                    z: QGroundControl.zOrderWaypointLines + 5.1
                    opacity: 1
                }
            }
            MapItemView {
                model: visibleGreenlandsModel
                visible: editorMap.showGreenlandLayer
                delegate: MapPolygon {
                    property var area: areaRef
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    visible: area && area.path && area.path.length >= 3
                    path: visible ? editorMap._scalePathTowardCenter(area.path, 0.58) : []
                    color: selected ? editorMap.greenlandSelectedInnerFillColor : editorMap.greenlandInnerFillColor
                    border.width: 0
                    border.color: "transparent"
                    z: QGroundControl.zOrderWaypointLines + 5.2
                    opacity: 1
                }
            }
            // 1.5) Label (Greenland 1/2/3...)
            MapItemView {
                model: visibleGreenlandsModel
                visible: editorMap.showGreenlandLayer && editorMap.showGreenlandLabels

                delegate: MapQuickItem {
                    property var area: areaRef
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    visible: area && area.path && area.path.length >= 3
                    z: QGroundControl.zOrderWaypointLines + 6
                    coordinate: visible ? editorMap._pathCenter(area.path) : QtPositioning.coordinate()

                    anchorPoint.x: sourceItem.width / 2
                    anchorPoint.y: sourceItem.height + 6

                    sourceItem: Rectangle {
                        color: selected ? editorMap.greenlandSelectedLabelColor : editorMap.greenlandLabelColor
                        radius: 5
                        border.width: 1
                        border.color: selected ? "#C8F7FFD8" : "#907FD26D"
                        implicitWidth: label.implicitWidth + 12
                        implicitHeight: label.implicitHeight + 8

                        Text {
                            id: label
                            anchors.centerIn: parent
                            text: qsTr("Greenland%1").arg(area ? area.gid : 0)
                            color: "white"
                            font.pixelSize: 12
                            font.bold: true
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: editorMap.greenlandEditMode
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (area) {
                                editorMap.selectedGreenlandId = area.gid
                            }
                        }
                    }
                }
            }
            // 2) Center handle (drag to move whole shape)
            MapItemView {
                model: editorMap.greenlands
                visible: editorMap.showGreenlandLayer

                delegate: MapQuickItem {
                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    visible: editorMap.greenlandEditMode && selected && area && area.path && area.path.length >= 3
                    z: QGroundControl.zOrderWaypointLines + 7

                    coordinate: visible ? editorMap._pathCenter(area.path) : QtPositioning.coordinate()

                    anchorPoint.x: 10
                    anchorPoint.y: 10

                    sourceItem: Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        color: editorMap.greenlandHandleColor
                        border.width: 2
                        border.color: editorMap.greenlandHandleBorderColor

                        Text {
                            anchors.centerIn: parent
                            text: "M"
                            color: "#06363B"
                            font.pixelSize: 12
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent
                            preventStealing: true
                            propagateComposedEvents: false
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                            property var startPath
                            property var refCenterCoord
                            property point pressMouseMapPx
                            property point pressCenterMapPx
                            property point dragOffsetPx

                            onPressed: {
                                mouse.accepted = true

                                // 关键：开始拖中心点时，禁用地图交互，防止1秒后被Map抢走
                                editorMap._dragInProgress = true
                                editorMap._setMapInteractiveForGreenlandDrag(false)

                                // 选中当前绿地（避免选中状态不同步）
                                editorMap.selectedGreenlandId = area.gid
                                editorMap.greenlandEditMode = true

                                startPath = area.path.slice(0)
                                refCenterCoord = editorMap._pathCenter(startPath)

                                // 按下时：记录“鼠标在地图像素坐标”
                                pressMouseMapPx = editorMap.mapFromItem(parent, mouse.x, mouse.y)

                                // 按下时：记录“中心点在地图像素坐标”
                                pressCenterMapPx = editorMap.fromCoordinate(refCenterCoord, false)

                                // offset = 鼠标点 - 中心点（像素）
                                dragOffsetPx = Qt.point(
                                    pressMouseMapPx.x - pressCenterMapPx.x,
                                    pressMouseMapPx.y - pressCenterMapPx.y
                                )
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true
                                if (!startPath || startPath.length < 3) return

                                // 当前鼠标在地图像素坐标
                                var mouseMapPx = editorMap.mapFromItem(parent, mouse.x, mouse.y)

                                // 让中心点跟随鼠标（保持按下时的 offset）
                                var newCenterPx = Qt.point(
                                    mouseMapPx.x - dragOffsetPx.x,
                                    mouseMapPx.y - dragOffsetPx.y
                                )

                                var newCenterCoord = editorMap.toCoordinate(newCenterPx, false)
                                if (!newCenterCoord || isNaN(newCenterCoord.latitude) || isNaN(newCenterCoord.longitude)) return

                                // 平移量 = 新中心 - 旧中心（经纬度差）
                                var dLat = newCenterCoord.latitude - refCenterCoord.latitude
                                var dLon = newCenterCoord.longitude - refCenterCoord.longitude

                                var moved = []
                                for (var i = 0; i < startPath.length; i++) {
                                    moved.push(editorMap._translateCoord(startPath[i], dLat, dLon))
                                }
                                area.path = moved
                            }

                            onReleased: {
                                mouse.accepted = true
                                saveGreenlandsGlobal()

                                // 关键：拖完恢复地图交互
                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForGreenlandDrag(true)
                            }

                            onCanceled: {
                                // 关键：如果系统取消/抢占导致 cancel，也必须恢复
                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForGreenlandDrag(true)
                            }
                        }
                    }
                }
            }
            
            // 3) Vertex handles (final: left-drag stable + right-delete, disable map gestures during drag)
            MapItemView {
                model: (editorMap.greenlandEditMode && editorMap.selectedGreenlandId >= 0)
                    ? editorMap._vertexModel()
                    : []
                visible: editorMap.showGreenlandLayer

                delegate: MapQuickItem {
                    property int gid: modelData.gid
                    property int vidx: modelData.vidx
                    property var area: modelData.areaRef

                    visible: editorMap.greenlandEditMode
                            && (gid === editorMap.selectedGreenlandId)
                            && area
                            && area.path
                            && area.path.length > vidx

                    z: QGroundControl.zOrderWaypointLines + 20
                    anchorPoint.x: 8
                    anchorPoint.y: 8

                    // 关键：绑定真实数组元素，避免不同步/重建
                    coordinate: visible ? area.path[vidx] : QtPositioning.coordinate()

                    sourceItem: Rectangle {
                        id: handleRect
                        width: 16
                        height: 16
                        radius: 8
                        color: editorMap.greenlandHandleColor
                        border.width: 2
                        border.color: editorMap.greenlandHandleBorderColor

                        // 只用于 drag.target 的“视觉跟随”，释放时复位
                        property real _startX: 0
                        property real _startY: 0
                        property bool _rightPressed: false
                        property bool _draggingLeft: false

                        MouseArea {
                            id: vMa
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            propagateComposedEvents: false
                            acceptedButtons: Qt.LeftButton | Qt.RightButton

                            // 用 drag.target 保持 grab（但真正坐标更新仍由 onPositionChanged 负责）
                            drag.target: handleRect
                            drag.axis: Drag.XAndYAxis
                            drag.minimumX: -100000
                            drag.maximumX:  100000
                            drag.minimumY: -100000
                            drag.maximumY:  100000

                            onPressed: {
                                mouse.accepted = true

                                handleRect._startX = handleRect.x
                                handleRect._startY = handleRect.y

                                handleRect._rightPressed = (mouse.button === Qt.RightButton)
                                handleRect._draggingLeft = (mouse.button === Qt.LeftButton)

                                // 右键：删除顶点（不进入拖动，不禁用地图也行）
                                if (handleRect._rightPressed) {
                                    // 立即复位，避免 drag.target 让它跑偏
                                    handleRect.x = handleRect._startX
                                    handleRect.y = handleRect._startY

                                    if (!area || !area.path) return
                                    if (area.path.length <= 3) {
                                        console.log("[Greenland] cannot delete: polygon needs >= 3 vertices")
                                        return
                                    }

                                    var pdel = area.path.slice(0)
                                    pdel.splice(vidx, 1)
                                    area.path = pdel
                                    saveGreenlandsGlobal()
                                    return
                                }

                                // 左键：开始拖动 => 禁用地图交互，防止1秒后Map抢事件
                                if (handleRect._draggingLeft) {
                                    editorMap._dragInProgress = true
                                    editorMap._setMapInteractiveForGreenlandDrag(false)
                                }
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true

                                if (handleRect._rightPressed) return
                                if (!handleRect._draggingLeft) return

                                if (!area || !area.path || area.path.length <= vidx) return

                                // 用当前 handleRect 的中心点 -> map像素 -> coordinate
                                var mapP = editorMap.mapFromItem(handleRect, handleRect.width / 2, handleRect.height / 2)
                                var newCoord = editorMap.toCoordinate(mapP, false)
                                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return

                                var p = area.path.slice(0)
                                p[vidx] = newCoord
                                area.path = p
                            }

                            onReleased: {
                                mouse.accepted = true

                                // 复位视觉位置
                                handleRect.x = handleRect._startX
                                handleRect.y = handleRect._startY

                                if (handleRect._draggingLeft) {
                                    saveGreenlandsGlobal()
                                }

                                handleRect._rightPressed = false
                                handleRect._draggingLeft = false

                                // 恢复地图交互
                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForGreenlandDrag(true)
                            }

                            onCanceled: {
                                // 被系统/地图手势取消时也要恢复，否则会“越用越怪”
                                handleRect.x = handleRect._startX
                                handleRect.y = handleRect._startY
                                handleRect._rightPressed = false
                                handleRect._draggingLeft = false

                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForGreenlandDrag(true)
                            }
                        }
                    }
                }
            }

            
            /*MapItemView {
                model: editorMap.greenlands

                delegate: Item {
                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)
                    property bool show: editorMap.greenlandEditMode && selected && area && area.path && area.path.length >= 4

                    function _setVertex(vIndex, newCoord) {
                        var p = area.path.slice(0)
                        p[vIndex] = newCoord
                        area.path = p
                    }

                    // 角点 0
                    MapQuickItem {
                        visible: show
                        z: QGroundControl.zOrderWaypointLines + 8
                        anchorPoint.x: 8; anchorPoint.y: 8
                        coordinate: show ? area.path[0] : QtPositioning.coordinate()
                        sourceItem: cornerHandleSource(0)
                    }
                    // 角点 1
                    MapQuickItem {
                        visible: show
                        z: QGroundControl.zOrderWaypointLines + 8
                        anchorPoint.x: 8; anchorPoint.y: 8
                        coordinate: show ? area.path[1] : QtPositioning.coordinate()
                        sourceItem: cornerHandleSource(1)
                    }
                    // 角点 2
                    MapQuickItem {
                        visible: show
                        z: QGroundControl.zOrderWaypointLines + 8
                        anchorPoint.x: 8; anchorPoint.y: 8
                        coordinate: show ? area.path[2] : QtPositioning.coordinate()
                        sourceItem: cornerHandleSource(2)
                    }
                    // 角点 3
                    MapQuickItem {
                        visible: show
                        z: QGroundControl.zOrderWaypointLines + 8
                        anchorPoint.x: 8; anchorPoint.y: 8
                        coordinate: show ? area.path[3] : QtPositioning.coordinate()
                        sourceItem: cornerHandleSource(3)
                    }

                    // 用 Component 动态生成 handle 的 sourceItem，避免重复代码
                    function cornerHandleSource(vIndex) {
                        return handleComponent.createObject(editorMap, {
                            vIndex: vIndex,
                            areaRef: area,
                            setVertexFn: _setVertex
                        })
                    }

                    Component {
                        id: handleComponent
                        Rectangle {
                            property int vIndex: -1
                            property var areaRef: null
                            property var setVertexFn: null

                            width: 16
                            height: 16
                            radius: 8
                            color: "white"
                            border.width: 2
                            border.color: "#00FF00"

                            MouseArea {
                                anchors.fill: parent
                                preventStealing: true
                                propagateComposedEvents: false
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                                property point startMouse
                                property point startPx

                                onPressed: {
                                    mouse.accepted = true
                                    startMouse = Qt.point(mouse.x, mouse.y)

                                    // 当前顶点坐标 -> 像素
                                    var c = areaRef.path[vIndex]
                                    startPx = editorMap.fromCoordinate(c, false)
                                }

                                onPositionChanged: {
                                    if (!pressed) return
                                    mouse.accepted = true

                                    var dx = mouse.x - startMouse.x
                                    var dy = mouse.y - startMouse.y
                                    var newPx = Qt.point(startPx.x + dx, startPx.y + dy)
                                    var newCoord = editorMap.toCoordinate(newPx, false)

                                    setVertexFn(vIndex, newCoord)
                                }

                                onReleased: mouse.accepted = true
                            }
                        }
                    }
                }
            }*/
            /*// Corner 0
            MapItemView {
                model: editorMap.greenlands
                delegate: MapQuickItem {
                    id: corner0Item

                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)
                    property bool show: editorMap.greenlandEditMode && selected && area && area.path && area.path.length >= 4

                    visible: show
                    z: QGroundControl.zOrderWaypointLines + 8
                    anchorPoint.x: 8; anchorPoint.y: 8
                    coordinate: show ? area.path[0] : QtPositioning.coordinate()

                    sourceItem: Rectangle {
                        width: 16; height: 16; radius: 8
                        color: "white"; border.width: 2; border.color: "#00FF00"

                        MouseArea {
                            anchors.fill: parent
                            preventStealing: true
                            propagateComposedEvents: false
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point startMouse
                            property point startPx
                            onPressed: {
                                mouse.accepted = true
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true

                                // 把鼠标点从当前 handle(Rectangle)坐标系映射到地图坐标系（像素）
                                var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                var newCoord = editorMap.toCoordinate(mapP, false)

                                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return

                                // 可选：夹取范围，避免异常值
                                var lat = Math.max(-85, Math.min(85, newCoord.latitude))
                                var lon = Math.max(-180, Math.min(180, newCoord.longitude))
                                newCoord = QtPositioning.coordinate(lat, lon, newCoord.altitude)

                                var p = area.path.slice(0)
                                p[0] = newCoord
                                area.path = p
                            }
                            onReleased: {
                                mouse.accepted = true
                                saveGreenlandsGlobal()
                            }
                        }
                    }
                }
            }

            // Corner 1
            MapItemView {
                model: editorMap.greenlands
                delegate: MapQuickItem {
                    id: corner1Item

                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)
                    property bool show: editorMap.greenlandEditMode && selected && area && area.path && area.path.length >= 4

                    visible: show
                    z: QGroundControl.zOrderWaypointLines + 8
                    anchorPoint.x: 8; anchorPoint.y: 8
                    coordinate: show ? area.path[1] : QtPositioning.coordinate()

                    sourceItem: Rectangle {
                        width: 16; height: 16; radius: 8
                        color: "white"; border.width: 2; border.color: "#00FF00"

                        MouseArea {
                            anchors.fill: parent
                            preventStealing: true
                            propagateComposedEvents: false
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point startMouse
                            property point startPx
                            onPressed: {
                                mouse.accepted = true
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true

                                // 把鼠标点从当前 handle(Rectangle)坐标系映射到地图坐标系（像素）
                                var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                var newCoord = editorMap.toCoordinate(mapP, false)

                                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return

                                // 可选：夹取范围，避免异常值
                                var lat = Math.max(-85, Math.min(85, newCoord.latitude))
                                var lon = Math.max(-180, Math.min(180, newCoord.longitude))
                                newCoord = QtPositioning.coordinate(lat, lon, newCoord.altitude)

                                var p = area.path.slice(0)
                                p[1] = newCoord
                                area.path = p
                            }
                            onReleased: {
                                mouse.accepted = true
                                saveGreenlandsGlobal()
                            }
                        }
                    }
                }
            }

            // Corner 2
            MapItemView {
                model: editorMap.greenlands
                delegate: MapQuickItem {
                    id: corner2Item

                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)
                    property bool show: editorMap.greenlandEditMode && selected && area && area.path && area.path.length >= 4

                    visible: show
                    z: QGroundControl.zOrderWaypointLines + 8
                    anchorPoint.x: 8; anchorPoint.y: 8
                    coordinate: show ? area.path[2] : QtPositioning.coordinate()

                    sourceItem: Rectangle {
                        width: 16; height: 16; radius: 8
                        color: "white"; border.width: 2; border.color: "#00FF00"

                        MouseArea {
                            anchors.fill: parent
                            preventStealing: true
                            propagateComposedEvents: false
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point startMouse
                            property point startPx
                            onPressed: {
                                mouse.accepted = true
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true

                                // 把鼠标点从当前 handle(Rectangle)坐标系映射到地图坐标系（像素）
                                var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                var newCoord = editorMap.toCoordinate(mapP, false)

                                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return

                                // 可选：夹取范围，避免异常值
                                var lat = Math.max(-85, Math.min(85, newCoord.latitude))
                                var lon = Math.max(-180, Math.min(180, newCoord.longitude))
                                newCoord = QtPositioning.coordinate(lat, lon, newCoord.altitude)

                                var p = area.path.slice(0)
                                p[2] = newCoord
                                area.path = p
                            }
                            onReleased: {
                                mouse.accepted = true
                                saveGreenlandsGlobal()
                            }
                        }
                    }
                }
            }

            // Corner 3
            MapItemView {
                model: editorMap.greenlands
                delegate: MapQuickItem {
                    id: corner3Item

                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)
                    property bool show: editorMap.greenlandEditMode && selected && area && area.path && area.path.length >= 4

                    visible: show
                    z: QGroundControl.zOrderWaypointLines + 8
                    anchorPoint.x: 8; anchorPoint.y: 8
                    coordinate: show ? area.path[3] : QtPositioning.coordinate()

                    sourceItem: Rectangle {
                        width: 16; height: 16; radius: 8
                        color: "white"; border.width: 2; border.color: "#00FF00"

                        MouseArea {
                            anchors.fill: parent
                            preventStealing: true
                            propagateComposedEvents: false
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point startMouse
                            property point startPx
                            onPressed: {
                                mouse.accepted = true
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true

                                // 把鼠标点从当前 handle(Rectangle)坐标系映射到地图坐标系（像素）
                                var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                var newCoord = editorMap.toCoordinate(mapP, false)

                                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return

                                // 可选：夹取范围，避免异常值
                                var lat = Math.max(-85, Math.min(85, newCoord.latitude))
                                var lon = Math.max(-180, Math.min(180, newCoord.longitude))
                                newCoord = QtPositioning.coordinate(lat, lon, newCoord.altitude)

                                var p = area.path.slice(0)
                                p[3] = newCoord
                                area.path = p
                            }
                            onReleased: {
                                mouse.accepted = true
                                saveGreenlandsGlobal()
                            }
                        }
                    }
                }
            }
            */
            // =======================
            // Water render + edit handles
            // =======================
            MapItemView {
                model: visibleWatersModel
                visible: editorMap.showWaterLayer
                delegate: MapPolygon {
                    id: waterPoly
                    property var area: areaRef
                    property bool selected: area && (area.wid === editorMap.selectedWaterId)

                    path: area && area.path ? area.path : []

                    color: selected ? "#660066FF" : "#330066FF"
                    border.width: selected ? 4 : 3
                    border.color: selected ? "#66CCFF" : "#3399FF"

                    z: QGroundControl.zOrderWaypointLines + 4

                    MouseArea {
                        anchors.fill: parent
                        enabled: editorMap.waterEditMode
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (!area) return

                            editorMap.selectedWaterId = area.wid

                            var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                            if (editorMap._insertWaterVertexAtClick(area, mapP)) {
                                saveWatersGlobal()
                            }
                        }
                    }
                }
            }
            MapItemView {
                model: visibleWatersModel
                visible: editorMap.showWaterLayer && editorMap.showWaterLabels

                delegate: MapQuickItem {
                    property var area: areaRef
                    property bool selected: area && (area.wid === editorMap.selectedWaterId)

                    visible: area && area.path && area.path.length >= 3
                    z: QGroundControl.zOrderWaypointLines + 5
                    coordinate: visible ? editorMap._pathCenter(area.path) : QtPositioning.coordinate()

                    anchorPoint.x: sourceItem.width / 2
                    anchorPoint.y: sourceItem.height + 6

                    sourceItem: Rectangle {
                        color: selected ? "#CC0066FF" : "#AA000000"
                        radius: 4
                        border.width: 1
                        border.color: "#60FFFFFF"
                        implicitWidth: label.implicitWidth + 12
                        implicitHeight: label.implicitHeight + 8

                        Text {
                            id: label
                            anchors.centerIn: parent
                            text: qsTr("Water%1").arg(area ? area.wid : 0)
                            color: "white"
                            font.pixelSize: 12
                            font.bold: true
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: editorMap.waterEditMode
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (area) {
                                editorMap.selectedWaterId = area.wid
                            }
                        }
                    }
                }
            }
            MapItemView {
                model: editorMap.waters
                visible: editorMap.showWaterLayer
                delegate: MapQuickItem {
                    property var area: modelData
                    property bool selected: area && (area.wid === editorMap.selectedWaterId)

                    visible: editorMap.waterEditMode && selected && area && area.path && area.path.length >= 3
                    z: QGroundControl.zOrderWaypointLines + 6
                    coordinate: visible ? editorMap._pathCenter(area.path) : QtPositioning.coordinate()

                    anchorPoint.x: 10
                    anchorPoint.y: 10

                    sourceItem: Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        color: "#FF66CCFF"
                        border.width: 2
                        border.color: "white"

                        Text {
                            anchors.centerIn: parent
                            text: "W"
                            color: "black"
                            font.pixelSize: 12
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            preventStealing: true
                            propagateComposedEvents: false
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                            property var startPath
                            property var refCenterCoord
                            property point pressMouseMapPx
                            property point pressCenterMapPx
                            property point dragOffsetPx

                            onPressed: {
                                mouse.accepted = true
                                editorMap._dragInProgress = true
                                editorMap._setMapInteractiveForWaterDrag(false)

                                editorMap.selectedWaterId = area.wid
                                editorMap.waterEditMode = true

                                startPath = area.path.slice(0)
                                refCenterCoord = editorMap._pathCenter(startPath)

                                pressMouseMapPx = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                pressCenterMapPx = editorMap.fromCoordinate(refCenterCoord, false)

                                dragOffsetPx = Qt.point(
                                    pressMouseMapPx.x - pressCenterMapPx.x,
                                    pressMouseMapPx.y - pressCenterMapPx.y
                                )
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true
                                if (!startPath || startPath.length < 3) return

                                var mouseMapPx = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                var newCenterPx = Qt.point(
                                    mouseMapPx.x - dragOffsetPx.x,
                                    mouseMapPx.y - dragOffsetPx.y
                                )

                                var newCenterCoord = editorMap.toCoordinate(newCenterPx, false)
                                if (!newCenterCoord || isNaN(newCenterCoord.latitude) || isNaN(newCenterCoord.longitude)) return

                                var dLat = newCenterCoord.latitude - refCenterCoord.latitude
                                var dLon = newCenterCoord.longitude - refCenterCoord.longitude

                                var moved = []
                                for (var i = 0; i < startPath.length; i++) {
                                    moved.push(editorMap._translateCoord(startPath[i], dLat, dLon))
                                }
                                area.path = moved
                            }

                            onReleased: {
                                mouse.accepted = true
                                saveWatersGlobal()
                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForWaterDrag(true)
                            }

                            onCanceled: {
                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForWaterDrag(true)
                            }
                        }
                    }
                }
            }
            MapItemView {
                model: (editorMap.waterEditMode && editorMap.selectedWaterId >= 0)
                    ? editorMap._waterVertexModel()
                    : []
                visible: editorMap.showWaterLayer
                delegate: MapQuickItem {
                    property int wid: modelData.wid
                    property int vidx: modelData.vidx
                    property var area: modelData.areaRef

                    visible: editorMap.waterEditMode
                            && (wid === editorMap.selectedWaterId)
                            && area
                            && area.path
                            && area.path.length > vidx

                    z: QGroundControl.zOrderWaypointLines + 21
                    anchorPoint.x: 8
                    anchorPoint.y: 8

                    coordinate: visible ? area.path[vidx] : QtPositioning.coordinate()

                    sourceItem: Rectangle {
                        id: waterHandleRect
                        width: 16
                        height: 16
                        radius: 8
                        color: "white"
                        border.width: 2
                        border.color: "#3399FF"

                        property real _startX: 0
                        property real _startY: 0
                        property bool _rightPressed: false
                        property bool _draggingLeft: false

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            propagateComposedEvents: false
                            acceptedButtons: Qt.LeftButton | Qt.RightButton

                            drag.target: waterHandleRect
                            drag.axis: Drag.XAndYAxis
                            drag.minimumX: -100000
                            drag.maximumX:  100000
                            drag.minimumY: -100000
                            drag.maximumY:  100000

                            onPressed: {
                                mouse.accepted = true

                                waterHandleRect._startX = waterHandleRect.x
                                waterHandleRect._startY = waterHandleRect.y

                                waterHandleRect._rightPressed = (mouse.button === Qt.RightButton)
                                waterHandleRect._draggingLeft = (mouse.button === Qt.LeftButton)

                                if (waterHandleRect._rightPressed) {
                                    waterHandleRect.x = waterHandleRect._startX
                                    waterHandleRect.y = waterHandleRect._startY

                                    if (!area || !area.path) return
                                    if (area.path.length <= 3) {
                                        console.log("[Water] cannot delete: polygon needs >= 3 vertices")
                                        return
                                    }

                                    var pdel = area.path.slice(0)
                                    pdel.splice(vidx, 1)
                                    area.path = pdel
                                    saveWatersGlobal()
                                    return
                                }

                                if (waterHandleRect._draggingLeft) {
                                    editorMap._dragInProgress = true
                                    editorMap._setMapInteractiveForWaterDrag(false)
                                }
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true
                                if (waterHandleRect._rightPressed) return
                                if (!waterHandleRect._draggingLeft) return
                                if (!area || !area.path || area.path.length <= vidx) return

                                var mapP = editorMap.mapFromItem(waterHandleRect, waterHandleRect.width/2, waterHandleRect.height/2)
                                var newCoord = editorMap.toCoordinate(mapP, false)
                                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return

                                var p = area.path.slice(0)
                                p[vidx] = newCoord
                                area.path = p
                            }

                            onReleased: {
                                mouse.accepted = true
                                waterHandleRect.x = waterHandleRect._startX
                                waterHandleRect.y = waterHandleRect._startY

                                if (waterHandleRect._draggingLeft) saveWatersGlobal()

                                waterHandleRect._rightPressed = false
                                waterHandleRect._draggingLeft = false

                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForWaterDrag(true)
                            }

                            onCanceled: {
                                waterHandleRect.x = waterHandleRect._startX
                                waterHandleRect.y = waterHandleRect._startY
                                waterHandleRect._rightPressed = false
                                waterHandleRect._draggingLeft = false

                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForWaterDrag(true)
                            }
                        }
                    }
                }
            }
            //Buildingdense
            MapItemView {
                model: visibleBuildingsDenseModel
                visible: editorMap.showBuildingLayer
                delegate: MapPolygon {
                    id: bdPoly
                    property var area: areaRef
                    property bool selected: area && (area.bdid === editorMap.selectedBuildingDenseId)
                    property bool hasHeight: area && (
                        Number(area.heightMeters || 0) > 0
                        || Number(area.minHeightMeters || 0) > 0
                        || Number(area.levels || 0) > 0)

                    path: area && area.path ? area.path : []

                    color: selected
                        ? (hasHeight ? "#668C52FF" : "#66FF8800")
                        : (hasHeight ? "#338C52FF" : "#33FF8800")
                    border.width: selected ? 4 : 3
                    border.color: selected
                        ? (hasHeight ? "#FFD8C3FF" : "#FFFFAA00")
                        : (hasHeight ? "#FF7A46D9" : "#FFCC7700")

                    z: QGroundControl.zOrderWaypointLines + 5

                    MouseArea {
                        anchors.fill: parent
                        enabled: editorMap.buildingDenseEditMode
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (!area) return

                            editorMap.selectedBuildingDenseId = area.bdid

                            var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                            if (editorMap._insertBuildingDenseVertexAtClick(area, mapP)) {
                                saveBuildingsDenseGlobal()
                            }
                        }
                    }
                }
            }

            MapItemView {
                model: visibleBuildingsDenseModel
                visible: editorMap.showBuildingLayer && editorMap.showBuildingLabels

                delegate: MapQuickItem {
                    property var area: areaRef
                    property bool selected: area && (area.bdid === editorMap.selectedBuildingDenseId)
                    property bool hasHeight: area && (
                        Number(area.heightMeters || 0) > 0
                        || Number(area.minHeightMeters || 0) > 0
                        || Number(area.levels || 0) > 0)

                    visible: area && area.path && area.path.length >= 3
                    z: QGroundControl.zOrderWaypointLines + 6
                    coordinate: visible ? editorMap._pathCenter(area.path) : QtPositioning.coordinate()

                    anchorPoint.x: sourceItem.width / 2
                    anchorPoint.y: sourceItem.height + 6

                    sourceItem: Rectangle {
                        color: selected
                            ? (hasHeight ? "#CC8C52FF" : "#CCFF8800")
                            : (hasHeight ? "#AA5A33B4" : "#AA000000")
                        radius: 4
                        border.width: 1
                        border.color: "#60FFFFFF"
                        implicitWidth: label.implicitWidth + 12
                        implicitHeight: label.implicitHeight + 8

                        Text {
                            id: label
                            anchors.centerIn: parent
                            text: qsTr("Building%1").arg(area ? area.bdid : 0)
                            color: "white"
                            font.pixelSize: 12
                            font.bold: true
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: editorMap.buildingDenseEditMode
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (area) {
                                editorMap.selectedBuildingDenseId = area.bdid
                            }
                        }
                    }
                }
            }

            MapItemView {
                model: editorMap.buildingsDense
                visible: editorMap.showBuildingLayer

                delegate: MapQuickItem {
                    property var area: modelData
                    property bool selected: area && (area.bdid === editorMap.selectedBuildingDenseId)

                    visible: editorMap.buildingDenseEditMode && selected && area && area.path && area.path.length >= 3
                    z: QGroundControl.zOrderWaypointLines + 7
                    coordinate: visible ? editorMap._pathCenter(area.path) : QtPositioning.coordinate()

                    anchorPoint.x: 10
                    anchorPoint.y: 10

                    sourceItem: Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        color: "#FFFFCC66"
                        border.width: 2
                        border.color: "white"

                        Text {
                            anchors.centerIn: parent
                            text: "B"
                            color: "black"
                            font.pixelSize: 12
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            preventStealing: true
                            propagateComposedEvents: false
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                            property var startPath
                            property var refCenterCoord
                            property point pressMouseMapPx
                            property point pressCenterMapPx
                            property point dragOffsetPx

                            onPressed: {
                                mouse.accepted = true
                                editorMap._dragInProgress = true
                                editorMap._setMapInteractiveForBuildingDenseDrag(false)

                                editorMap.selectedBuildingDenseId = area.bdid
                                editorMap.buildingDenseEditMode = true

                                startPath = area.path.slice(0)
                                refCenterCoord = editorMap._pathCenter(startPath)

                                pressMouseMapPx = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                pressCenterMapPx = editorMap.fromCoordinate(refCenterCoord, false)

                                dragOffsetPx = Qt.point(
                                    pressMouseMapPx.x - pressCenterMapPx.x,
                                    pressMouseMapPx.y - pressCenterMapPx.y
                                )
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true
                                if (!startPath || startPath.length < 3) return

                                var mouseMapPx = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                                var newCenterPx = Qt.point(
                                    mouseMapPx.x - dragOffsetPx.x,
                                    mouseMapPx.y - dragOffsetPx.y
                                )

                                var newCenterCoord = editorMap.toCoordinate(newCenterPx, false)
                                if (!newCenterCoord || isNaN(newCenterCoord.latitude) || isNaN(newCenterCoord.longitude)) return

                                var dLat = newCenterCoord.latitude - refCenterCoord.latitude
                                var dLon = newCenterCoord.longitude - refCenterCoord.longitude

                                var moved = []
                                for (var i = 0; i < startPath.length; i++) {
                                    moved.push(editorMap._translateCoord(startPath[i], dLat, dLon))
                                }
                                area.path = moved
                            }

                            onReleased: {
                                mouse.accepted = true
                                saveBuildingsDenseGlobal()
                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForBuildingDenseDrag(true)
                            }

                            onCanceled: {
                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForBuildingDenseDrag(true)
                            }
                        }
                    }
                }
            }
            // BuildingDense Vertex handles (left-drag + right-delete)
            MapItemView {
                model: (editorMap.buildingDenseEditMode && editorMap.selectedBuildingDenseId >= 0)
                    ? editorMap._buildingDenseVertexModel()
                    : []
                visible: editorMap.showBuildingLayer

                delegate: MapQuickItem {
                    property int bdid: modelData.bdid
                    property int vidx: modelData.vidx
                    property var area: modelData.areaRef

                    visible: editorMap.buildingDenseEditMode
                            && (bdid === editorMap.selectedBuildingDenseId)
                            && area
                            && area.path
                            && area.path.length > vidx

                    z: QGroundControl.zOrderWaypointLines + 21
                    anchorPoint.x: 8
                    anchorPoint.y: 8
                    coordinate: visible ? area.path[vidx] : QtPositioning.coordinate()

                    sourceItem: Rectangle {
                        id: bdHandleRect
                        width: 16
                        height: 16
                        radius: 8
                        color: "white"
                        border.width: 2
                        border.color: "#FF8800"

                        property real _startX: 0
                        property real _startY: 0
                        property bool _rightPressed: false
                        property bool _draggingLeft: false

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            propagateComposedEvents: false
                            acceptedButtons: Qt.LeftButton | Qt.RightButton

                            drag.target: bdHandleRect
                            drag.axis: Drag.XAndYAxis
                            drag.minimumX: -100000
                            drag.maximumX:  100000
                            drag.minimumY: -100000
                            drag.maximumY:  100000

                            onPressed: {
                                mouse.accepted = true

                                bdHandleRect._startX = bdHandleRect.x
                                bdHandleRect._startY = bdHandleRect.y

                                bdHandleRect._rightPressed = (mouse.button === Qt.RightButton)
                                bdHandleRect._draggingLeft = (mouse.button === Qt.LeftButton)

                                // 右键删点
                                if (bdHandleRect._rightPressed) {
                                    bdHandleRect.x = bdHandleRect._startX
                                    bdHandleRect.y = bdHandleRect._startY

                                    if (!area || !area.path) return
                                    if (area.path.length <= 3) {
                                        console.log("[BuildingDense] cannot delete: polygon needs >= 3 vertices")
                                        return
                                    }

                                    var pdel = area.path.slice(0)
                                    pdel.splice(vidx, 1)
                                    area.path = pdel
                                    saveBuildingsDenseGlobal()
                                    return
                                }

                                // 左键拖点：禁用地图手势，避免被 Map 抢 grab
                                if (bdHandleRect._draggingLeft) {
                                    editorMap._dragInProgress = true
                                    editorMap._setMapInteractiveForBuildingDenseDrag(false)
                                }
                            }

                            onPositionChanged: {
                                if (!pressed) return
                                mouse.accepted = true
                                if (bdHandleRect._rightPressed) return
                                if (!bdHandleRect._draggingLeft) return
                                if (!area || !area.path || area.path.length <= vidx) return

                                var mapP = editorMap.mapFromItem(bdHandleRect, bdHandleRect.width/2, bdHandleRect.height/2)
                                var newCoord = editorMap.toCoordinate(mapP, false)
                                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return

                                var p = area.path.slice(0)
                                p[vidx] = newCoord
                                area.path = p
                            }

                            onReleased: {
                                mouse.accepted = true
                                bdHandleRect.x = bdHandleRect._startX
                                bdHandleRect.y = bdHandleRect._startY

                                if (bdHandleRect._draggingLeft) saveBuildingsDenseGlobal()

                                bdHandleRect._rightPressed = false
                                bdHandleRect._draggingLeft = false

                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForBuildingDenseDrag(true)
                            }

                            onCanceled: {
                                bdHandleRect.x = bdHandleRect._startX
                                bdHandleRect.y = bdHandleRect._startY
                                bdHandleRect._rightPressed = false
                                bdHandleRect._draggingLeft = false

                                editorMap._dragInProgress = false
                                editorMap._setMapInteractiveForBuildingDenseDrag(true)
                            }
                        }
                    }
                }
            }
            // UI for splitting the current segment
            MapQuickItem {
                id:             splitSegmentItem
                anchorPoint.x:  sourceItem.width / 2
                anchorPoint.y:  sourceItem.height / 2
                z:              QGroundControl.zOrderWaypointLines + 1
                visible:        _editingLayer == _layerMission

                sourceItem: SplitIndicator {
                    onClicked:  _missionController.insertSimpleMissionItem(splitSegmentItem.coordinate,
                                                                           _missionController.currentPlanViewVIIndex,
                                                                           true /* makeCurrentItem */)
                }

                function _updateSplitCoord() {
                    if (_missionController.splitSegment) {
                        var distance = _missionController.splitSegment.coordinate1.distanceTo(_missionController.splitSegment.coordinate2)
                        var azimuth = _missionController.splitSegment.coordinate1.azimuthTo(_missionController.splitSegment.coordinate2)
                        splitSegmentItem.coordinate = _missionController.splitSegment.coordinate1.atDistanceAndAzimuth(distance / 2, azimuth)
                    } else {
                        coordinate = QtPositioning.coordinate()
                    }
                }

                Connections {
                    target:                 _missionController
                    function onSplitSegmentChanged()  { splitSegmentItem._updateSplitCoord() }
                }

                Connections {
                    target:                 _missionController.splitSegment
                    function onCoordinate1Changed()   { splitSegmentItem._updateSplitCoord() }
                    function onCoordinate2Changed()   { splitSegmentItem._updateSplitCoord() }
                }
            }

            // Add the vehicles to the map
            MapItemView {
                model: QGroundControl.multiVehicleManager.vehicles
                delegate: VehicleMapItem {
                    vehicle:        object
                    coordinate:     object.coordinate
                    map:            editorMap
                    size:           ScreenTools.defaultFontPixelHeight * 3
                    z:              QGroundControl.zOrderMapItems - 1
                }
            }

            GeoFenceMapVisuals {
                map:                    editorMap
                myGeoFenceController:   _geoFenceController
                interactive:            _editingLayer == _layerGeoFence
                homePosition:           _missionController.plannedHomePosition
                planView:               true
                opacity:                _editingLayer != _layerGeoFence ? editorMap._nonInteractiveOpacity : 1
            }

            RallyPointMapVisuals {
                map:                    editorMap
                myRallyPointController: _rallyPointController
                interactive:            _editingLayer == _layerRallyPoints
                planView:               true
                opacity:                _editingLayer != _layerRallyPoints ? editorMap._nonInteractiveOpacity : 1
            }

            // A* Debug Layer - Direct map components
            Item {
                id: astarDebugLayer
                anchors.fill: parent
                
                property bool debugVisible: false
                property var debugTrees: []
                
                function refreshDebugData() {
                    debugTrees = TowerOpt.getDebugSearchTrees()
                    console.log('[AStarDebug] Loaded', debugTrees.length, 'search trees')
                }
                
                // Debug control panel
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.margins: 10
                    width: 200
                    height: 120
                    color: "#80000000"
                    radius: 5
                    visible: astarDebugLayer.debugVisible
                    
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        
                        QGCLabel {
                            text: "A* Debug Layer"
                            color: "white"
                            font.bold: true
                        }
                        
                        QGCCheckBox {
                            id: showNodesCheck
                            text: "Show Nodes"
                            checked: true
                            textColor: "white"
                        }
                        
                        QGCCheckBox {
                            id: showEdgesCheck
                            text: "Show Edges"  
                            checked: true
                            textColor: "white"
                        }
                        
                        QGCCheckBox {
                            id: showPathCheck
                            text: "Show Final Path"
                            checked: true
                            textColor: "white"
                        }
                        
                        QGCButton {
                            text: "Refresh"
                            Layout.fillWidth: true
                            onClicked: astarDebugLayer.refreshDebugData()
                        }
                    }
                }
                
                // Debug visualization - direct map children
                Repeater {
                    model: astarDebugLayer.debugVisible ? astarDebugLayer.debugTrees : []
                    
                    delegate: Item {
                        property var treeData: modelData
                        
                        // Search edges
                        Repeater {
                            model: showEdgesCheck.checked ? treeData.edges : []
                            delegate: MapPolyline {
                                line.width: 1
                                line.color: "#20888888"
                                path: [
                                    QtPositioning.coordinate(modelData.from.lat, modelData.from.lon),
                                    QtPositioning.coordinate(modelData.to.lat, modelData.to.lon)
                                ]
                            }
                        }
                        
                        // Search nodes  
                        Repeater {
                            model: showNodesCheck.checked ? treeData.nodes : []
                            delegate: MapQuickItem {
                                coordinate: QtPositioning.coordinate(modelData.coord.lat, modelData.coord.lon)
                                anchorPoint.x: 4
                                anchorPoint.y: 4
                                
                                sourceItem: Rectangle {
                                    width: 8
                                    height: 8
                                    radius: 4
                                    color: modelData.isBest ? "#FFFF0000" : 
                                           modelData.isClosed ? "#40FF4444" : "#4000FF00"
                                    border.width: 1
                                    border.color: "#80FFFFFF"
                                }
                            }
                        }
                        
                        // Final path
                        MapPolyline {
                            visible: showPathCheck.checked && treeData.finalPath.length > 0
                            line.width: 3
                            line.color: "#FF00FF00"
                            path: {
                                var pathCoords = []
                                for (var i = 0; i < treeData.finalPath.length; i++) {
                                    pathCoords.push(QtPositioning.coordinate(
                                        treeData.finalPath[i].coord.lat,
                                        treeData.finalPath[i].coord.lon
                                    ))
                                }
                                return pathCoords
                            }
                        }
                        
                        // Start marker
                        MapQuickItem {
                            coordinate: QtPositioning.coordinate(treeData.originalCoord.lat, treeData.originalCoord.lon)
                            anchorPoint.x: 6
                            anchorPoint.y: 6
                            
                            sourceItem: Rectangle {
                                width: 12
                                height: 12
                                radius: 6
                                color: "#FF0000FF"
                                border.width: 2
                                border.color: "white"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "S"
                                    color: "white"
                                    font.pixelSize: 8
                                    font.bold: true
                                }
                            }
                        }
                        
                        // Target marker
                        MapQuickItem {
                            coordinate: QtPositioning.coordinate(treeData.targetCoord.lat, treeData.targetCoord.lon)
                            anchorPoint.x: 6
                            anchorPoint.y: 6
                            
                            sourceItem: Rectangle {
                                width: 12
                                height: 12
                                radius: 6
                                color: "#FFFF8000"
                                border.width: 2
                                border.color: "white"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "T"
                                    color: "white"
                                    font.pixelSize: 8
                                    font.bold: true
                                }
                            }
                        }
                    }
                }
            }
                        // =======================
            // Greenland editor (multi polygons)
            // =======================
            property bool greenlandEditMode: false
            property var greenlands: []   
            property int greenlandNextId: 1
            property int selectedGreenlandId: -1
            onSelectedGreenlandIdChanged: _scheduleRegionVisibleAreasRefresh()

            function _metersToLat(m) { return m / 111320.0 }
            function _metersToLon(m, lat) { return m / (111320.0 * Math.cos(lat * Math.PI / 180.0)) }


            function _makeRectInView(pixelW, pixelH) {
                // 用“当前视野中心”的屏幕像素点，生成一个像素宽高的矩形
                var c = editorMap.center
                var p = editorMap.fromCoordinate(c)

                var hw = pixelW / 2
                var hh = pixelH / 2

                var p1 = Qt.point(p.x - hw, p.y - hh)
                var p2 = Qt.point(p.x + hw, p.y - hh)
                var p3 = Qt.point(p.x + hw, p.y + hh)
                var p4 = Qt.point(p.x - hw, p.y + hh)

                // false => 不做 wrap（跨日界线）
                return [
                    editorMap.toCoordinate(p1, false),
                    editorMap.toCoordinate(p2, false),
                    editorMap.toCoordinate(p3, false),
                    editorMap.toCoordinate(p4, false)
                ]
            }
            function _closedPath(path) {
                if (!path || path.length === 0) return []
                var out = path.slice(0)
                // MapPolyline 需要闭合就把首点再追加到末尾
                out.push(path[0])
                return out
            }

            function _pathToScreen(path) {
                // 将经纬度 path 转为屏幕像素点数组 [{x,y}, ...]
                var pts = []
                if (!path) return pts
                for (var i = 0; i < path.length; i++) {
                    var p = editorMap.fromCoordinate(path[i], false)
                    pts.push({ x: p.x, y: p.y })
                }
                return pts
            }
            function _pathScreenBounds(path) {
                if (!path || path.length === 0) return null

                var minX =  1e30
                var minY =  1e30
                var maxX = -1e30
                var maxY = -1e30
                var validCount = 0

                for (var i = 0; i < path.length; i++) {
                    var p = editorMap.fromCoordinate(path[i], false)
                    if (!p || isNaN(p.x) || isNaN(p.y)) continue
                    if (p.x < minX) minX = p.x
                    if (p.y < minY) minY = p.y
                    if (p.x > maxX) maxX = p.x
                    if (p.y > maxY) maxY = p.y
                    validCount++
                }

                if (validCount === 0) return null
                return { minX: minX, minY: minY, maxX: maxX, maxY: maxY }
            }
            function _pathIntersectsViewport(path, padPx) {
                var bounds = _pathScreenBounds(path)
                if (!bounds) return false

                var pad = (typeof padPx === "number") ? padPx : 0
                return bounds.maxX >= -pad
                    && bounds.minX <= editorMap.width + pad
                    && bounds.maxY >= -pad
                    && bounds.minY <= editorMap.height + pad
            }
            function _visibleAreas(areas, padPx, selectedId, idKey) {
                var out = []
                if (!areas) return out

                for (var i = 0; i < areas.length; i++) {
                    var area = areas[i]
                    if (!area || !area.path || area.path.length < 3) continue

                    var isSelected = selectedId >= 0 && area[idKey] === selectedId
                    if (isSelected || _pathIntersectsViewport(area.path, padPx)) {
                        out.push(area)
                    }
                }

                return out
            }
            function _clearVisibleAreaModel(model) {
                if (model && model.count > 0) {
                    model.clear()
                }
            }
            function _syncVisibleAreaModel(model, areas, padPx, selectedId, idKey) {
                if (!model) return

                var nextAreas = _visibleAreas(areas, padPx, selectedId, idKey)
                if (!nextAreas || nextAreas.length === 0) {
                    _clearVisibleAreaModel(model)
                    return
                }

                var nextIds = {}
                for (var ni = 0; ni < nextAreas.length; ni++) {
                    nextIds[nextAreas[ni][idKey]] = true
                }

                for (var ci = model.count - 1; ci >= 0; ci--) {
                    var currentEntry = model.get(ci)
                    if (!nextIds[currentEntry.areaId]) {
                        model.remove(ci)
                    }
                }

                var modelIndex = 0
                for (var i = 0; i < nextAreas.length; i++) {
                    var nextArea = nextAreas[i]
                    var nextId = nextArea[idKey]

                    if (modelIndex < model.count) {
                        var existingEntry = model.get(modelIndex)
                        if (existingEntry.areaId === nextId) {
                            if (existingEntry.areaRef !== nextArea) {
                                model.setProperty(modelIndex, "areaRef", nextArea)
                            }
                            modelIndex++
                            continue
                        }
                    }

                    model.insert(modelIndex, {
                        areaId: nextId,
                        areaRef: nextArea
                    })
                    modelIndex++
                }

                while (model.count > nextAreas.length) {
                    model.remove(model.count - 1)
                }
            }
            function _pathCenter(path) {
                var lat = 0, lon = 0
                for (var i = 0; i < path.length; i++) {
                    lat += path[i].latitude
                    lon += path[i].longitude
                }
                return QtPositioning.coordinate(lat / path.length, lon / path.length)
            }
            function _scalePathTowardCenter(path, factor) {
                var out = []
                if (!path || path.length < 3) return out

                var center = _pathCenter(path)
                var f = Math.max(0.05, Math.min(1.0, factor))
                for (var i = 0; i < path.length; i++) {
                    var p = path[i]
                    out.push(QtPositioning.coordinate(
                        center.latitude + (p.latitude - center.latitude) * f,
                        center.longitude + (p.longitude - center.longitude) * f,
                        p.altitude
                    ))
                }
                return out
            }
            function _translateCoord(coord, dLat, dLon) {
                return QtPositioning.coordinate(coord.latitude + dLat, coord.longitude + dLon, coord.altitude)
            }
            function _dist2(a, b) {
                var dx = a.x - b.x
                var dy = a.y - b.y
                return dx*dx + dy*dy
            }

            // 点P到线段AB的投影
            function _projectPointToSegment(P, A, B) {
                var ABx = B.x - A.x
                var ABy = B.y - A.y
                var APx = P.x - A.x
                var APy = P.y - A.y
                var ab2 = ABx*ABx + ABy*ABy
                var t = (ab2 > 0) ? ((APx*ABx + APy*ABy) / ab2) : 0
                t = Math.max(0, Math.min(1, t))
                var foot = Qt.point(A.x + ABx*t, A.y + ABy*t)
                return { t: t, foot: foot, d2: _dist2(P, foot) }
            }

            // 点击靠近边时在最近边插入一个顶点
            function _insertVertexAtClick(area, mapPx) {
                if (!area || !area.path || area.path.length < 3) return false

                // 经纬度 -> 像素点
                var pts = []
                for (var i = 0; i < area.path.length; i++) {
                    pts.push(fromCoordinate(area.path[i], false))
                }

                // 找最近边
                var bestEdge = -1
                var bestD2 = 1e30
                var bestFoot = null

                for (var j = 0; j < pts.length; j++) {
                    var A = pts[j]
                    var B = pts[(j + 1) % pts.length]
                    var pr = _projectPointToSegment(mapPx, A, B)
                    if (pr.d2 < bestD2) {
                        bestD2 = pr.d2
                        bestEdge = j
                        bestFoot = pr.foot
                    }
                }

                // 阈值：离边 <= 12px 才允许插入（按手感可调）
                var threshold = 12
                if (bestEdge < 0 || bestD2 > threshold * threshold) return false

                // 用foot更贴边
                var newCoord = toCoordinate(bestFoot, false)
                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return false

                var p = area.path.slice(0)
                p.splice(bestEdge + 1, 0, newCoord)
                area.path = p
                return true
            }
            // 屏幕像素拖动 dx/dy -> 经纬度平移增量（用中心点近似，足够好用）
            function _screenDragToLatLonDelta(dx, dy, refCoord) {
                var p0 = editorMap.fromCoordinate(refCoord, false)
                var p1 = Qt.point(p0.x + dx, p0.y + dy)
                var c1 = editorMap.toCoordinate(p1, false)
                return { dLat: (c1.latitude - refCoord.latitude), dLon: (c1.longitude - refCoord.longitude) }
            }

            function addGreenland() {
                var rect = _makeRectInView(240, 180)

                var area = Qt.createQmlObject(
                    'import QGroundControl.Greenland 1.0; GreenlandArea {}',
                    editorMap,
                    'GreenlandArea' + greenlandNextId
                )

                area.gid = greenlandNextId
                area.path = rect

                greenlandNextId += 1
                greenlands = greenlands.concat([area])

                selectedGreenlandId = area.gid
                greenlandEditMode = true

                console.log("[Greenland] created GreenlandArea gid=", area.gid, "pathCount=", area.path.length)
                saveGreenlandsGlobal()
            }

            function removeSelectedGreenland() {
                if (!greenlands || greenlands.length === 0) return

                var removeId = selectedGreenlandId
                if (removeId < 0) {
                    removeId = greenlands[greenlands.length - 1].gid
                }

                var arr = []
                for (var i = 0; i < greenlands.length; i++) {
                    if (greenlands[i].gid !== removeId) arr.push(greenlands[i])
                }
                greenlands = arr

                selectedGreenlandId = greenlands.length ? greenlands[greenlands.length - 1].gid : -1
                if (greenlands.length === 0) greenlandEditMode = false
                saveGreenlandsGlobal()
            }

            function updateGreenlandVertex(gIndex, vIndex, newCoord) {
                var g = greenlands[gIndex]
                if (!g || !g.path || g.path.length <= vIndex) return

                var p = g.path.slice(0)
                p[vIndex] = newCoord
                g.path = p // 关键：触发 pathChanged
            }
            function exitGreenlandEditMode() {
                greenlandEditMode = false
            }
            // =======================
            // Water editor (multi polygons)
            // =======================
            property bool waterEditMode: false
            property var waters: []
            property int waterNextId: 1
            property int selectedWaterId: -1
            onSelectedWaterIdChanged: _scheduleRegionVisibleAreasRefresh()

            function _waterVertexModel() {
                var out = []
                if (!waters) return out

                for (var wi = 0; wi < waters.length; wi++) {
                    var area = waters[wi]
                    if (!area || !area.path || area.path.length < 3) continue

                    for (var vi = 0; vi < area.path.length; vi++) {
                        out.push({
                            wid: area.wid,
                            vidx: vi,
                            areaRef: area
                        })
                    }
                }
                return out
            }

            // 复用你已有的 _projectPointToSegment/_insertVertexAtClick 思路，做 Water 版
            function _insertWaterVertexAtClick(area, mapPx) {
                if (!area || !area.path || area.path.length < 3) return false

                var pts = []
                for (var i = 0; i < area.path.length; i++) {
                    pts.push(fromCoordinate(area.path[i], false))
                }

                var bestEdge = -1
                var bestD2 = 1e30
                var bestFoot = null

                for (var j = 0; j < pts.length; j++) {
                    var A = pts[j]
                    var B = pts[(j + 1) % pts.length]
                    var pr = _projectPointToSegment(mapPx, A, B)
                    if (pr.d2 < bestD2) {
                        bestD2 = pr.d2
                        bestEdge = j
                        bestFoot = pr.foot
                    }
                }

                var threshold = 12
                if (bestEdge < 0 || bestD2 > threshold * threshold) return false

                var newCoord = toCoordinate(bestFoot, false)
                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return false

                var p = area.path.slice(0)
                p.splice(bestEdge + 1, 0, newCoord)
                area.path = p
                return true
            }

            function _setMapInteractiveForWaterDrag(enable) {
                // 复制 Greenland 的兼容处理
                try {
                    if (enable) {
                        interactive = _savedMapInteractive
                    } else {
                        _savedMapInteractive = interactive
                        interactive = false
                    }
                    return
                } catch (e) { }

                try {
                    if (gestures) {
                        gestures.enabled = enable
                        return
                    }
                } catch (e2) { }

                try {
                    if (enable) {
                        if (map) map.interactive = true
                    } else {
                        if (map) map.interactive = false
                    }
                } catch (e3) { }
            }

            function addWater() {
                var rect = _makeRectInView(240, 180)

                var area = Qt.createQmlObject(
                    'import QGroundControl.Water 1.0; WaterArea {}',
                    editorMap,
                    'WaterArea' + waterNextId
                )

                area.wid = waterNextId
                area.path = rect

                waterNextId += 1
                waters = waters.concat([area])

                selectedWaterId = area.wid
                waterEditMode = true

                console.log("[Water] created WaterArea wid=", area.wid, "pathCount=", area.path.length)
                saveWatersGlobal()
            }

            function removeSelectedWater() {
                if (!waters || waters.length === 0) return

                var removeId = selectedWaterId
                if (removeId < 0) removeId = waters[waters.length - 1].wid

                var arr = []
                for (var i = 0; i < waters.length; i++) {
                    if (waters[i].wid !== removeId) arr.push(waters[i])
                }
                waters = arr

                selectedWaterId = waters.length ? waters[waters.length - 1].wid : -1
                if (waters.length === 0) waterEditMode = false
                saveWatersGlobal()
            }

            function exitWaterEditMode() {
                waterEditMode = false
            }
            // =======================
            // BuildingDense editor (multi polygons)
            // =======================
            property bool buildingDenseEditMode: false
            property var buildingsDense: []
            property int buildingDenseNextId: 1
            property int selectedBuildingDenseId: -1
            onSelectedBuildingDenseIdChanged: _scheduleRegionVisibleAreasRefresh()

            function _buildingDenseVertexModel() {
                var out = []
                if (!buildingsDense) return out

                for (var bi = 0; bi < buildingsDense.length; bi++) {
                    var area = buildingsDense[bi]
                    if (!area || !area.path || area.path.length < 3) continue

                    for (var vi = 0; vi < area.path.length; vi++) {
                        out.push({
                            bdid: area.bdid,
                            vidx: vi,
                            areaRef: area
                        })
                    }
                }
                return out
            }

            function addBuildingDense() {
                var rect = _makeRectInView(240, 180)

                var area = Qt.createQmlObject(
                    "import QGroundControl.Building 1.0; BuildingDense {}",
                    editorMap,
                    "BuildingDense" + buildingDenseNextId
                )

                area.bdid = buildingDenseNextId
                area.path = rect

                buildingDenseNextId += 1
                buildingsDense = buildingsDense.concat([area])

                selectedBuildingDenseId = area.bdid
                buildingDenseEditMode = true

                console.log("[BuildingDense] created bdid=", area.bdid, "pathCount=", area.path.length)
                saveBuildingsDenseGlobal()
            }

            function removeSelectedBuildingDense() {
                if (!buildingsDense || buildingsDense.length === 0) return

                var removeId = selectedBuildingDenseId
                if (removeId < 0) removeId = buildingsDense[buildingsDense.length - 1].bdid

                var arr = []
                for (var i = 0; i < buildingsDense.length; i++) {
                    if (buildingsDense[i].bdid !== removeId) arr.push(buildingsDense[i])
                }
                buildingsDense = arr

                selectedBuildingDenseId = buildingsDense.length
                    ? buildingsDense[buildingsDense.length - 1].bdid
                    : -1

                if (buildingsDense.length === 0) buildingDenseEditMode = false
                saveBuildingsDenseGlobal()
            }

            function exitBuildingDenseEditMode() {
                buildingDenseEditMode = false
            }

            // 点击边插点：复用你 Greenland 的 _projectPointToSegment 实现
            function _insertBuildingDenseVertexAtClick(area, mapPx) {
                if (!area || !area.path || area.path.length < 3) return false

                var pts = []
                for (var i = 0; i < area.path.length; i++) {
                    pts.push(fromCoordinate(area.path[i], false))
                }

                var bestEdge = -1
                var bestD2 = 1e30
                var bestFoot = null

                for (var j = 0; j < pts.length; j++) {
                    var A = pts[j]
                    var B = pts[(j + 1) % pts.length]
                    var pr = _projectPointToSegment(mapPx, A, B)
                    if (pr.d2 < bestD2) {
                        bestD2 = pr.d2
                        bestEdge = j
                        bestFoot = pr.foot
                    }
                }

                var threshold = 12
                if (bestEdge < 0 || bestD2 > threshold * threshold) return false

                var newCoord = toCoordinate(bestFoot, false)
                if (!newCoord || isNaN(newCoord.latitude) || isNaN(newCoord.longitude)) return false

                var p = area.path.slice(0)
                p.splice(bestEdge + 1, 0, newCoord)
                area.path = p
                return true
            }

            function _setMapInteractiveForBuildingDenseDrag(enable) {
                // 复制你 Greenland 的兼容策略
                try {
                    if (enable) {
                        interactive = _savedMapInteractive
                    } else {
                        _savedMapInteractive = interactive
                        interactive = false
                    }
                    return
                } catch (e) { }

                try {
                    if (gestures) {
                        gestures.enabled = enable
                        return
                    }
                } catch (e2) { }

                try {
                    if (enable) {
                        if (map) map.interactive = true
                    } else {
                        if (map) map.interactive = false
                    }
                } catch (e3) { }
            }
  
        }

        //-----------------------------------------------------------
        // Left tool strip
        ToolStrip {
            id:                 toolStrip
            anchors.margins:    _toolsMargin
            anchors.left:       parent.left
            anchors.top:        parent.top
            z:                  QGroundControl.zOrderWidgets
            maxHeight:          parent.height - toolStrip.y
            title:              qsTr("Plan")

            readonly property int flyButtonIndex:       0
            readonly property int fileButtonIndex:      1
            readonly property int takeoffButtonIndex:   2
            readonly property int waypointButtonIndex:  3
            readonly property int roiButtonIndex:       4
            readonly property int patternButtonIndex:   5
            readonly property int landButtonIndex:      6
            readonly property int centerButtonIndex:    7
            readonly property int optimizeButtonIndex:  8

            property bool _isRallyLayer:    _editingLayer == _layerRallyPoints
            property bool _isMissionLayer:  _editingLayer == _layerMission

            ToolStripActionList {
                id: toolStripActionList
                model: [
                    ToolStripAction {
                        text:           qsTr("Fly")
                        iconSource:     "/qmlimages/PaperPlane.svg"
                        onTriggered:    mainWindow.showFlyView()
                    },
                    ToolStripAction {
                        text:                   qsTr("File")
                        enabled:                !_planMasterController.syncInProgress
                        visible:                true
                        showAlternateIcon:      _planMasterController.dirty
                        iconSource:             "/qmlimages/MapSync.svg"
                        alternateIconSource:    "/qmlimages/MapSyncChanged.svg"
                        dropPanelComponent:     syncDropPanel
                    },
                    ToolStripAction {
                        text:       qsTr("Takeoff")
                        iconSource: "/res/takeoff.svg"
                        enabled:    _missionController.isInsertTakeoffValid
                        visible:    toolStrip._isMissionLayer && !_planMasterController.controllerVehicle.rover
                        onTriggered: {
                            toolStrip.allAddClickBoolsOff()
                            insertTakeItemAfterCurrent()
                        }
                    },
                    ToolStripAction {
                        id:                 addWaypointRallyPointAction
                        text:               _editingLayer == _layerRallyPoints ? qsTr("Rally Point") : qsTr("Waypoint")
                        iconSource:         "/qmlimages/MapAddMission.svg"
                        enabled:            toolStrip._isRallyLayer ? true : _missionController.flyThroughCommandsAllowed
                        visible:            toolStrip._isRallyLayer || toolStrip._isMissionLayer
                        checkable:          true
                        onTriggered: {
                            // Entering waypoint-add mode should exit custom area edit modes,
                            // otherwise the map click handler is intentionally disabled.
                            if (checked) {
                                editorMap.exitGreenlandEditMode()
                                editorMap.exitWaterEditMode()
                                editorMap.exitBuildingDenseEditMode()
                            }
                        }
                    },
                    ToolStripAction {
                        text:               _missionController.isROIActive ? qsTr("Cancel ROI") : qsTr("ROI")
                        iconSource:         "/qmlimages/MapAddMission.svg"
                        enabled:            !_missionController.onlyInsertTakeoffValid
                        visible:            toolStrip._isMissionLayer && _planMasterController.controllerVehicle.roiModeSupported
                        checkable:          !_missionController.isROIActive
                        onCheckedChanged:   _addROIOnClick = checked
                        onTriggered: {
                            if (_missionController.isROIActive) {
                                toolStrip.allAddClickBoolsOff()
                                insertCancelROIAfterCurrent()
                            }
                        }
                        property bool myAddROIOnClick: _addROIOnClick
                        onMyAddROIOnClickChanged: checked = _addROIOnClick
                    },
                    ToolStripAction {
                        text:               _singleComplexItem ? _missionController.complexMissionItemNames[0] : qsTr("Pattern")
                        iconSource:         "/qmlimages/MapDrawShape.svg"
                        enabled:            _missionController.flyThroughCommandsAllowed
                        visible:            toolStrip._isMissionLayer
                        dropPanelComponent: _singleComplexItem ? undefined : patternDropPanel
                        onTriggered: {
                            toolStrip.allAddClickBoolsOff()
                            if (_singleComplexItem) {
                                insertComplexItemAfterCurrent(_missionController.complexMissionItemNames[0])
                            }
                        }
                    },
                    ToolStripAction {
                        text:       _planMasterController.controllerVehicle.multiRotor ? qsTr("Return") : qsTr("Land")
                        iconSource: "/res/rtl.svg"
                        enabled:    _missionController.isInsertLandValid
                        visible:    toolStrip._isMissionLayer
                        onTriggered: {
                            toolStrip.allAddClickBoolsOff()
                            insertLandItemAfterCurrent()
                        }
                    },
                    ToolStripAction {
                        text:               qsTr("Center")
                        iconSource:         "/qmlimages/MapCenter.svg"
                        enabled:            true
                        visible:            true
                        dropPanelComponent: centerMapDropPanel
                    },
                    ToolStripAction {
                        id:             optimizeAction
                        text:           qsTr("Optimize")
                        iconSource:     "/qmlimages/Optimize.svg"
                        enabled:        toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                        visible:        toolStrip._isMissionLayer
                        dropPanelComponent: optimizeDropPanel
                    },
                    ToolStripAction {
                        id: heatmapToggle
                        text: qsTr("Signal")
                        iconSource: "/qmlimages/signal.svg"
                        checkable: true
                        checked: editorMap.showSignalStrengthLayer
                        visible: toolStrip._isMissionLayer
                        onTriggered: editorMap.showSignalStrengthLayer = !editorMap.showSignalStrengthLayer
                    },
                    /*ToolStripAction {
                        id: astarDebugToggle
                        text: qsTr("A* Debug")
                        iconSource: "/qmlimages/MapCenter.svg"
                        checkable: true
                        checked: false
                        visible: toolStrip._isMissionLayer
                        onTriggered: {
                            checked = !checked
                            if (checked) {
                                editorMap.astarDebugLayer.debugVisible = true
                                editorMap.astarDebugLayer.refreshDebugData()
                            } else {
                                editorMap.astarDebugLayer.debugVisible = false
                            }
                        }
                    }
                    ,*/
                    ToolStripAction {
                        id: weatherToggle
                        text: qsTr("Weather")
                        iconSource: "/qmlimages/weather.svg"
                        checkable: true
                        checked: editorMap.showWeatherLayer
                        visible: toolStrip._isMissionLayer
                        onTriggered: {
                            editorMap.showWeatherLayer = !editorMap.showWeatherLayer
                            console.log('[PlanView] Weather layer toggled:', editorMap.showWeatherLayer)
                        }
                    }
                    ,

                    ToolStripAction {
                        id: greenlandAction
                        text: qsTr("Greenland")
                        iconSource: "/qmlimages/greenland.svg"
                        enabled: true
                        visible: toolStrip._isMissionLayer
                        dropPanelComponent: greenlandDropPanel
                    }
                    ,
                    ToolStripAction {
                        id: buildingDenseAction
                        text: qsTr("Building")
                        iconSource: "/qmlimages/building.svg"
                        enabled: true
                        visible: toolStrip._isMissionLayer
                        dropPanelComponent: buildingDenseDropPanel
                    }
                    ,
                    ToolStripAction {
                        id: waterAction
                        text: qsTr("Water")
                        iconSource: "/qmlimages/water.svg"
                        enabled: true
                        visible: toolStrip._isMissionLayer
                        dropPanelComponent: waterDropPanel
                    }
                    ,
                    ToolStripAction {
                        id: roadToggleAction
                        text: qsTr("Roads")
                        iconSource: "/qmlimages/road.svg"   // 先复用一个现成图标，后续你想换再说
                        enabled: true
                        visible: toolStrip._isMissionLayer
                        checkable: true
                        checked: editorMap.showRoadLayer

                        onTriggered: {
                            var next = !editorMap.showRoadLayer
                            if (next && !editorMap.roadsLoaded) {
                                loadRoadsFromResource("qrc:/roads/export.geojson", true)
                            } else {
                                editorMap.showRoadLayer = next
                            }
                        }
                    }

                ]
            }

            model: toolStripActionList.model

            function allAddClickBoolsOff() {
                _addROIOnClick =        false
                addWaypointRallyPointAction.checked = false
            }

            onDropped: allAddClickBoolsOff()
        }
        Rectangle {
            id: buildingLoadStatusPanel
            z: 10000
            visible: editorMap.buildingRestoreLoading || buildingRestoreDoneToast.running
            radius: 6
            color: "#B0000000"
            border.color: "#40FFFFFF"
            border.width: 1

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: _toolsMargin

            width: Math.min(parent.width * 0.7, ScreenTools.defaultFontPixelWidth * 58)
            height: ScreenTools.defaultFontPixelHeight * 2.2

            property int _loaded: Math.max(0, editorMap.buildingRestoreLoadedCount)
            property int _total: Math.max(0, editorMap.buildingRestoreTargetCount)
            property int _pct: _total > 0 ? Math.min(100, Math.floor((_loaded * 100) / _total)) : 100

            QGCLabel {
                anchors.centerIn: parent
                color: "white"
                text: editorMap.buildingRestoreLoading
                      ? qsTr("Building loading: %1/%2 (%3%)").arg(buildingLoadStatusPanel._loaded).arg(buildingLoadStatusPanel._total).arg(buildingLoadStatusPanel._pct)
                      : qsTr("Building loaded: %1").arg(buildingLoadStatusPanel._total)
            }
        }
        Rectangle {
            id: weightPanel
            z: 9999
            radius: 6
            color: "#B0000000"
            border.color: "#40FFFFFF"
            border.width: 1

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: _toolsMargin

            /*width: Math.min(parent.width * 1, ScreenTools.defaultFontPixelWidth * 100)
            height: ScreenTools.defaultFontPixelHeight * 15
            visible: true */
            width: Math.min(parent.width * 1, ScreenTools.defaultFontPixelWidth * 100)
            property bool weightsExpanded: true
            readonly property real collapsedH: ScreenTools.defaultFontPixelHeight * 2.6
            height: weightsExpanded ? (ScreenTools.defaultFontPixelHeight * 17.5) : collapsedH
            visible: true
            property real signalWeightLocal: 0.50
            property real distanceWeightLocal: 0.50
            property real weatherWeightLocal: 0.50
            property real greenlandWeightLocal: 0.50
            property real buildingWeightLocal: 0.50
            property real waterWeightLocal: 0.50
            property real roadsWeightLocal: 0.50
            // 你要的“离边框空隙”就在这里调
            readonly property int sidePad: 24   // 左右留白
            readonly property int topPad: 16    // 上留白
            readonly property int bottomPad: 16 // 下留白

            // label 固定宽度（保证两行严格对齐）
            readonly property int labelW: 220
            // Header bar (always visible)
            Item {
                id: weightHeader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: weightPanel.collapsedH

                QGCLabel {
                    anchors.centerIn: parent
                    text: qsTr("Optimize Weights")
                    color: "white"
                    font.bold: true
                }

                QGCButton {
                    anchors.right: parent.right
                    anchors.rightMargin: weightPanel.sidePad
                    anchors.verticalCenter: parent.verticalCenter
                    text: weightPanel.weightsExpanded ? qsTr("Hide") : qsTr("Show")
                    onClicked: weightPanel.weightsExpanded = !weightPanel.weightsExpanded
                }
            }

            // 内容容器：用 anchors 硬做 padding，必生效
            Item {
                id: content
                /*anchors.fill: parent
                anchors.leftMargin: weightPanel.sidePad
                anchors.rightMargin: weightPanel.sidePad
                anchors.topMargin: weightPanel.topPad
                anchors.bottomMargin: weightPanel.bottomPad */
                anchors.fill: parent
                anchors.leftMargin: weightPanel.sidePad
                anchors.rightMargin: weightPanel.sidePad
                anchors.topMargin: weightPanel.collapsedH + weightPanel.topPad
                anchors.bottomMargin: weightPanel.bottomPad
                visible: weightPanel.weightsExpanded

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Math.round(ScreenTools.defaultFontPixelHeight * 0.6)

                    // 标题居中
                    /*QGCLabel {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("Optimize Weights")
                        color: "white"
                        font.bold: true
                    } */

                    // 两行严格对齐
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 3
                        columnSpacing: 16
                        rowSpacing: Math.round(ScreenTools.defaultFontPixelHeight * 0.8)

                        // 右侧输入框固定宽度
                        readonly property int inputW: 84

                        function _clamp01(x) {
                            if (isNaN(x)) return 0
                            return Math.max(0, Math.min(1, x))
                        }

                        function _fmt(x) {
                            // 统一显示两位小数
                            return _clamp01(x).toFixed(2)
                        }

                        // Row 1: Signal strength
                        QGCLabel {
                            Layout.preferredWidth: weightPanel.labelW
                            Layout.minimumWidth: weightPanel.labelW
                            Layout.maximumWidth: weightPanel.labelW
                            verticalAlignment: Text.AlignVCenter
                            text: qsTr("Signal strength")
                            color: "white"
                            elide: Text.ElideRight
                        }

                        Slider {
                            id: signalSlider
                            Layout.fillWidth: true
                            minimumValue: 0
                            maximumValue: 1
                            stepSize: 0.01
                            value: weightPanel.signalWeightLocal

                            onValueChanged: {
                                weightPanel.signalWeightLocal = value
                                PathOptimizationManager.signalWeight = value
                                // 只有在“非编辑状态”下才强行回写，避免打字时抖动
                                if (!signalInput.activeFocus) {
                                    signalInput.text = grid._fmt(value)
                                }
                            }
                        }

                        TextField {
                            id: signalInput
                            Layout.preferredWidth: grid.inputW
                            Layout.minimumWidth: grid.inputW
                            Layout.maximumWidth: grid.inputW

                            // 初始显示
                            text: grid._fmt(weightPanel.signalWeightLocal)

                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            validator: DoubleValidator { bottom: 0; top: 1; decimals: 2 }

                            // 回车/确认输入
                            onAccepted: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                // 同步 slider（slider 的 onValueChanged 会负责写入 PathOptimizationManager）
                                signalSlider.value = v
                                focus = false
                            }

                            // 失焦也提交
                            onEditingFinished: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                signalSlider.value = v
                            }
                        }

                        // Row 2: Distance
                        QGCLabel {
                            Layout.preferredWidth: weightPanel.labelW
                            Layout.minimumWidth: weightPanel.labelW
                            Layout.maximumWidth: weightPanel.labelW
                            verticalAlignment: Text.AlignVCenter
                            text: qsTr("Distance")
                            color: "white"
                            elide: Text.ElideRight
                        }

                        Slider {
                            id: distanceSlider
                            Layout.fillWidth: true
                            minimumValue: 0
                            maximumValue: 1
                            stepSize: 0.01
                            value: weightPanel.distanceWeightLocal

                            onValueChanged: {
                                weightPanel.distanceWeightLocal = value
                                PathOptimizationManager.distanceWeight = value
                                if (!distanceInput.activeFocus) {
                                    distanceInput.text = grid._fmt(value)
                                }
                            }
                        }

                        TextField {
                            id: distanceInput
                            Layout.preferredWidth: grid.inputW
                            Layout.minimumWidth: grid.inputW
                            Layout.maximumWidth: grid.inputW

                            text: grid._fmt(weightPanel.distanceWeightLocal)

                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            validator: DoubleValidator { bottom: 0; top: 1; decimals: 2 }

                            onAccepted: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                distanceSlider.value = v
                                focus = false
                            }

                            onEditingFinished: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                distanceSlider.value = v
                            }
                        }
                        // Row 3: Weather
                        QGCLabel {
                            Layout.preferredWidth: weightPanel.labelW
                            Layout.minimumWidth: weightPanel.labelW
                            Layout.maximumWidth: weightPanel.labelW
                            verticalAlignment: Text.AlignVCenter
                            text: qsTr("Weather")
                            color: "white"
                            elide: Text.ElideRight
                        }

                        Slider {
                            id: weatherSlider
                            Layout.fillWidth: true
                            minimumValue: 0
                            maximumValue: 1
                            stepSize: 0.01
                            value: weightPanel.weatherWeightLocal

                            onValueChanged: {
                                weightPanel.weatherWeightLocal = value
                                PathOptimizationManager.weatherWeight = value
                                if (!weatherInput.activeFocus) {
                                    weatherInput.text = grid._fmt(value)
                                }
                            }
                        }

                        TextField {
                            id: weatherInput
                            Layout.preferredWidth: grid.inputW
                            Layout.minimumWidth: grid.inputW
                            Layout.maximumWidth: grid.inputW

                            text: grid._fmt(weightPanel.weatherWeightLocal)

                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            validator: DoubleValidator { bottom: 0; top: 1; decimals: 2 }

                            onAccepted: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                weatherSlider.value = v
                                focus = false
                            }

                            onEditingFinished: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                weatherSlider.value = v
                            }
                        }
                        // Row 4: Greenland
                        QGCLabel {
                            Layout.preferredWidth: weightPanel.labelW
                            Layout.minimumWidth: weightPanel.labelW
                            Layout.maximumWidth: weightPanel.labelW
                            verticalAlignment: Text.AlignVCenter
                            text: qsTr("Greenland")
                            color: "white"
                            elide: Text.ElideRight
                        }

                        Slider {
                            id: greenlandSlider
                            Layout.fillWidth: true
                            minimumValue: 0
                            maximumValue: 1
                            stepSize: 0.01
                            value: weightPanel.greenlandWeightLocal

                            onValueChanged: {
                                weightPanel.greenlandWeightLocal = value
                                PathOptimizationManager.greenlandWeight = value
                                if (!greenlandInput.activeFocus) {
                                    greenlandInput.text = grid._fmt(value)
                                }
                            }
                        }

                        TextField {
                            id: greenlandInput
                            Layout.preferredWidth: grid.inputW
                            Layout.minimumWidth: grid.inputW
                            Layout.maximumWidth: grid.inputW

                            text: grid._fmt(weightPanel.greenlandWeightLocal)

                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            validator: DoubleValidator { bottom: 0; top: 1; decimals: 2 }

                            onAccepted: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                greenlandSlider.value = v
                                focus = false
                            }

                            onEditingFinished: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                greenlandSlider.value = v
                            }
                        }
                        // Row 5: Building
                        QGCLabel {
                            Layout.preferredWidth: weightPanel.labelW
                            Layout.minimumWidth: weightPanel.labelW
                            Layout.maximumWidth: weightPanel.labelW
                            verticalAlignment: Text.AlignVCenter
                            text: qsTr("Building")
                            color: "white"
                            elide: Text.ElideRight
                        }

                        Slider {
                            id: buildingSlider
                            Layout.fillWidth: true
                            minimumValue: 0
                            maximumValue: 1
                            stepSize: 0.01
                            value: weightPanel.buildingWeightLocal

                            onValueChanged: {
                                weightPanel.buildingWeightLocal = value
                                PathOptimizationManager.buildingWeight = value
                                if (!buildingInput.activeFocus) {
                                    buildingInput.text = grid._fmt(value)
                                }
                            }
                        }

                        TextField {
                            id: buildingInput
                            Layout.preferredWidth: grid.inputW
                            Layout.minimumWidth: grid.inputW
                            Layout.maximumWidth: grid.inputW

                            text: grid._fmt(weightPanel.buildingWeightLocal)

                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            validator: DoubleValidator { bottom: 0; top: 1; decimals: 2 }

                            onAccepted: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                buildingSlider.value = v
                                focus = false
                            }

                            onEditingFinished: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                buildingSlider.value = v
                            }
                        }
                        // Row 6: Water
                        QGCLabel {
                            Layout.preferredWidth: weightPanel.labelW
                            Layout.minimumWidth: weightPanel.labelW
                            Layout.maximumWidth: weightPanel.labelW
                            verticalAlignment: Text.AlignVCenter
                            text: qsTr("Water")
                            color: "white"
                            elide: Text.ElideRight
                        }

                        Slider {
                            id: waterSlider
                            Layout.fillWidth: true
                            minimumValue: 0
                            maximumValue: 1
                            stepSize: 0.01
                            value: weightPanel.waterWeightLocal

                            onValueChanged: {
                                weightPanel.waterWeightLocal = value
                                PathOptimizationManager.waterWeight = value
                                if (!waterInput.activeFocus) {
                                    waterInput.text = grid._fmt(value)
                                }
                            }
                        }

                        TextField {
                            id: waterInput
                            Layout.preferredWidth: grid.inputW
                            Layout.minimumWidth: grid.inputW
                            Layout.maximumWidth: grid.inputW

                            text: grid._fmt(weightPanel.waterWeightLocal)

                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            validator: DoubleValidator { bottom: 0; top: 1; decimals: 2 }

                            onAccepted: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                waterSlider.value = v
                                focus = false
                            }

                            onEditingFinished: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                waterSlider.value = v
                            }
                        }
                        // Row 7: Roads
                        QGCLabel {
                            Layout.preferredWidth: weightPanel.labelW
                            Layout.minimumWidth: weightPanel.labelW
                            Layout.maximumWidth: weightPanel.labelW
                            verticalAlignment: Text.AlignVCenter
                            text: qsTr("Roads")
                            color: "white"
                            elide: Text.ElideRight
                        }

                        Slider {
                            id: roadsSlider
                            Layout.fillWidth: true
                            minimumValue: 0
                            maximumValue: 1
                            stepSize: 0.01
                            value: weightPanel.roadsWeightLocal

                            onValueChanged: {
                                weightPanel.roadsWeightLocal = value
                                PathOptimizationManager.roadWeight = value
                                if (!roadsInput.activeFocus) {
                                    roadsInput.text = grid._fmt(value)
                                }
                            }
                        }

                        TextField {
                            id: roadsInput
                            Layout.preferredWidth: grid.inputW
                            Layout.minimumWidth: grid.inputW
                            Layout.maximumWidth: grid.inputW

                            text: grid._fmt(weightPanel.roadsWeightLocal)

                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            validator: DoubleValidator { bottom: 0; top: 1; decimals: 2 }

                            onAccepted: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                roadsSlider.value = v
                                focus = false
                            }

                            onEditingFinished: {
                                var v = grid._clamp01(parseFloat(text))
                                text = grid._fmt(v)
                                roadsSlider.value = v
                            }
                        }
                        // 给上面函数一个对象名引用（QtQuick 2.3 下用 id 访问更稳）
                        id: grid
                    }
                }
            }
        }
       //算法权重条
        /*Rectangle {
            id: weightPanel
            z: 9999

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: _toolsMargin

            width:  Math.min(parent.width * 0.55, ScreenTools.defaultFontPixelWidth * 60)
            height: ScreenTools.defaultFontPixelHeight * 4.2
            radius: 6
            color: "#B0000000"
            border.color: "#40FFFFFF"
            border.width: 1

            visible: true

            // Local-only weights (no PathOptimizationManager dependency)
            property real distanceWeightLocal: 0.50
            property real signalWeightLocal:   0.50

            Column {
                anchors.fill: parent
                anchors.margins: _margin
                spacing: ScreenTools.defaultFontPixelHeight * 0.3

                QGCLabel {
                    text: qsTr("Tower Optimize Weights")
                    color: "white"
                    font.bold: true
                }

                Row {
                    spacing: _margin
                    width: parent.width

                    QGCLabel {
                        width: ScreenTools.defaultFontPixelWidth * 16
                        color: "white"
                        text: qsTr("Distance: %1").arg(distanceWeightLocal.toFixed(2))
                    }

                    Slider {
                        width: parent.width - (ScreenTools.defaultFontPixelWidth * 16) - _margin
                        minimumValue: 0
                        maximumValue: 1
                        stepSize: 0.01
                        value: distanceWeightLocal
                        onValueChanged: distanceWeightLocal = value
                    }
                }

                Row {
                    spacing: _margin
                    width: parent.width

                    QGCLabel {
                        width: ScreenTools.defaultFontPixelWidth * 16
                        color: "white"
                        text: qsTr("Signal: %1").arg(signalWeightLocal.toFixed(2))
                    }

                    Slider {
                        width: parent.width - (ScreenTools.defaultFontPixelWidth * 16) - _margin
                        minimumValue: 0
                        maximumValue: 1
                        stepSize: 0.01
                        value: signalWeightLocal
                        onValueChanged: signalWeightLocal = value
                    }
                }
            }
        }*/
        //-----------------------------------------------------------
        // Right pane for mission editing controls
        Rectangle {
            id:                 rightPanel
            height:             parent.height
            width:              _rightPanelWidth
            color:              qgcPal.window
            opacity:            layerTabBar.visible ? 0.2 : 0
            anchors.bottom:     parent.bottom
            anchors.right:      parent.right
            anchors.rightMargin: _toolsMargin
        }
        Loader {
            id:                 comparisonPanelLoader
            source:             "PathComparisonPanel.qml"
            anchors.right:      rightPanel.left
            anchors.rightMargin: _toolsMargin
            anchors.top:        parent.top
            anchors.bottom:     parent.bottom
            width:              Math.min(ScreenTools.defaultFontPixelWidth * 46, parent.width * 0.38)
            readonly property bool _hasComparisonData: originalPathForDisplay.length > 0 || signalPathForDisplay.length > 0 || lengthPathForDisplay.length > 0 || smoothPathForDisplay.length > 0
            visible:            _editingLayer == _layerMission && _hasComparisonData && item !== null
            active:             _editingLayer == _layerMission && _hasComparisonData

            onLoaded: {
                if (item) {
                    item.missionController = _missionController
                    Qt.callLater(_refreshPathComparisonPanel)
                }
            }
        }

        //-------------------------------------------------------
        // Right Panel Controls
        Item {
            anchors.fill:           rightPanel
            anchors.topMargin:      _toolsMargin
            DeadMouseArea {
                anchors.fill:   parent
            }
            Column {
                id:                 rightControls
                spacing:            ScreenTools.defaultFontPixelHeight * 0.5
                anchors.left:       parent.left
                anchors.right:      parent.right
                anchors.top:        parent.top
                //-------------------------------------------------------
                // Mission Controls (Expanded)
                QGCTabBar {
                    id:         layerTabBar
                    width:      parent.width
                    visible:    QGroundControl.corePlugin.options.enablePlanViewSelector
                    Component.onCompleted: currentIndex = 0
                    QGCTabButton {
                        text:       qsTr("Mission")
                    }
                    QGCTabButton {
                        text:       qsTr("Fence")
                        enabled:    _geoFenceController.supported
                    }
                    QGCTabButton {
                        text:       qsTr("Rally")
                        enabled:    _rallyPointController.supported
                    }
                }
            }
            //-------------------------------------------------------
            // Mission Item Editor
            Item {
                id:                     missionItemEditor
                anchors.left:           parent.left
                anchors.right:          parent.right
                anchors.top:            rightControls.bottom
                anchors.topMargin:      ScreenTools.defaultFontPixelHeight * 0.25
                anchors.bottom:         parent.bottom
                anchors.bottomMargin:   ScreenTools.defaultFontPixelHeight * 0.25
                visible:                _editingLayer == _layerMission && !planControlColapsed
                QGCListView {
                    id:                 missionItemEditorListView
                    anchors.fill:       parent
                    spacing:            ScreenTools.defaultFontPixelHeight / 4
                    orientation:        ListView.Vertical
                    model:              _missionController.visualItems
                    cacheBuffer:        Math.max(height * 2, 0)
                    clip:               true
                    currentIndex:       _missionController.currentPlanViewSeqNum
                    highlightMoveDuration: 250
                    visible:            _editingLayer == _layerMission && !planControlColapsed
                    //-- List Elements
                    delegate: MissionItemEditor {
                        map:            editorMap
                        masterController:  _planMasterController
                        missionItem:    object
                        width:          missionItemEditorListView.width
                        readOnly:       false
                        onClicked:      _missionController.setCurrentPlanViewSeqNum(object.sequenceNumber, false)
                        onRemove: {
                            var removeVIIndex = index
                            _missionController.removeVisualItem(removeVIIndex)
                            if (removeVIIndex >= _missionController.visualItems.count) {
                                removeVIIndex--
                            }
                        }
                        onSelectNextNotReadyItem:   selectNextNotReady()
                    }
                }
            }
            // GeoFence Editor
            GeoFenceEditor {
                anchors.top:            rightControls.bottom
                anchors.topMargin:      ScreenTools.defaultFontPixelHeight * 0.25
                anchors.bottom:         parent.bottom
                anchors.left:           parent.left
                anchors.right:          parent.right
                myGeoFenceController:   _geoFenceController
                flightMap:              editorMap
                visible:                _editingLayer == _layerGeoFence
            }

            // Rally Point Editor
            RallyPointEditorHeader {
                id:                     rallyPointHeader
                anchors.top:            rightControls.bottom
                anchors.topMargin:      ScreenTools.defaultFontPixelHeight * 0.25
                anchors.left:           parent.left
                anchors.right:          parent.right
                visible:                _editingLayer == _layerRallyPoints
                controller:             _rallyPointController
            }
            RallyPointItemEditor {
                id:                     rallyPointEditor
                anchors.top:            rallyPointHeader.bottom
                anchors.topMargin:      ScreenTools.defaultFontPixelHeight * 0.25
                anchors.left:           parent.left
                anchors.right:          parent.right
                visible:                _editingLayer == _layerRallyPoints && _rallyPointController.points.count
                rallyPoint:             _rallyPointController.currentRallyPoint
                controller:             _rallyPointController
            }
        }

        QGCLabel {
            // Elevation provider notice on top of terrain plot
            readonly property string _licenseString: QGroundControl.elevationProviderNotice

            id:                         licenseLabel
            visible:                    terrainStatus.visible && _licenseString !== ""
            anchors.bottom:             terrainStatus.top
            anchors.horizontalCenter:   terrainStatus.horizontalCenter
            anchors.bottomMargin:       ScreenTools.defaultFontPixelWidth * 0.5
            font.pointSize:             ScreenTools.smallFontPointSize
            text:                       qsTr("Powered by %1").arg(_licenseString)
        }

        TerrainStatus {
            id:                 terrainStatus
            anchors.margins:    _toolsMargin
            anchors.leftMargin: 0
            anchors.left:       mapScale.left
            anchors.right:      rightPanel.left
            anchors.bottom:     parent.bottom
            height:             ScreenTools.defaultFontPixelHeight * 7
            missionController:  _missionController
            visible:            _internalVisible && _editingLayer === _layerMission && QGroundControl.corePlugin.options.showMissionStatus

            onSetCurrentSeqNum: _missionController.setCurrentPlanViewSeqNum(seqNum, true)

            property bool _internalVisible: _planViewSettings.showMissionItemStatus.rawValue

            function toggleVisible() {
                _internalVisible = !_internalVisible
                _planViewSettings.showMissionItemStatus.rawValue = _internalVisible
            }
        }

        MapScale {
            id:                     mapScale
            anchors.margins:        _toolsMargin
            anchors.bottom:         terrainStatus.visible ? terrainStatus.top : parent.bottom
            anchors.left:           toolStrip.y + toolStrip.height + _toolsMargin > mapScale.y ? toolStrip.right: parent.left
            mapControl:             editorMap
            buttonsOnLeft:          true
            terrainButtonVisible:   _editingLayer === _layerMission
            terrainButtonChecked:   terrainStatus.visible
            onTerrainButtonClicked: terrainStatus.toggleVisible()
        }
    }

    function showLoadFromFileOverwritePrompt(title) {
        mainWindow.showMessageDialog(title,
                                     qsTr("You have unsaved/unsent changes. Loading from a file will lose these changes. Are you sure you want to load from a file?"),
                                     StandardButton.Yes | StandardButton.Cancel,
                                     function() { _planMasterController.loadFromSelectedFile() } )
    }

    Component {
        id: createPlanRemoveAllPromptDialog

        QGCSimpleMessageDialog {
            title:      qsTr("Create Plan")
            text:       qsTr("Are you sure you want to remove current plan and create a new plan? ")
            buttons:    StandardButton.Yes | StandardButton.No

            property var mapCenter
            property var planCreator

            onAccepted: planCreator.createPlan(mapCenter)
        }
    }

    function clearButtonClicked() {
        mainWindow.showMessageDialog(qsTr("Clear"),
                                     qsTr("Are you sure you want to remove all mission items and clear the mission from the vehicle?"),
                                     StandardButton.Yes | StandardButton.Cancel,
                                     function() { _planMasterController.removeAllFromVehicle(); _missionController.setCurrentPlanViewSeqNum(0, true) })
    }

    //- ToolStrip DropPanel Components

    Component {
        id: centerMapDropPanel

        CenterMapDropPanel {
            map:            editorMap
            fitFunctions:   mapFitFunctions
        }
    }

    Component {
        id: patternDropPanel

        ColumnLayout {
            spacing:    ScreenTools.defaultFontPixelWidth * 0.5

            QGCLabel { text: qsTr("Create complex pattern:") }

            Repeater {
                model: _missionController.complexMissionItemNames

                QGCButton {
                    text:               modelData
                    Layout.fillWidth:   true

                    onClicked: {
                        insertComplexItemAfterCurrent(modelData)
                        dropPanel.hide()
                    }
                }
            }
        } // Column
    }

    Component {
        id: optimizeDropPanel
        ColumnLayout {
            spacing: _margin
            QGCLabel { text: qsTr("Optimize") }
            QGCButton {
                text: qsTr("Linear")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    TowerOpt.optimizeMissionLinear(_missionController, _planMasterController, 0.2)
                    dropPanel.hide()
                }
            }
            QGCButton {
                text: qsTr("Astar")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    _syncPathOptimizationStateToCpp()

                    var multiResult = TowerOpt.generateMultiPathPlans(_missionController, _planMasterController, {})
                    if (multiResult) {
                        originalPathForDisplay = multiResult.original || []
                        signalPathForDisplay = multiResult.signal || []
                        lengthPathForDisplay = multiResult.length || []
                        smoothPathForDisplay = multiResult.smooth || []
                    } else {
                        TowerOpt.optimizeMissionAStar(_missionController, _planMasterController, 0.2)
                        originalPathForDisplay = TowerOpt.getOriginalPathWaypoints() || []
                        signalPathForDisplay = []
                        lengthPathForDisplay = []
                        smoothPathForDisplay = []
                    }

                    _scheduleTerrainRecoveryPasses(3)
                    Qt.callLater(_refreshPathComparisonPanel)
                    dropPanel.hide()
                }
            }
            QGCButton {
                text: qsTr("RRT")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    _syncPathOptimizationStateToCpp()
                    TowerOpt.optimizeMissionRRT(_missionController, _planMasterController, 0.2)
                    originalPathForDisplay = TowerOpt.getOriginalPathWaypoints() || []
                    signalPathForDisplay = []
                    lengthPathForDisplay = []
                    smoothPathForDisplay = []
                    Qt.callLater(_refreshPathComparisonPanel)
                    dropPanel.hide()
                }
            }
            /*QGCButton {
                text: qsTr("A* New")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    _syncPathOptimizationStateToCpp()
                    TowerOpt.optimizeMissionAStarNew(_missionController, _planMasterController, 0.2)
                    originalPathForDisplay = TowerOpt.getOriginalPathWaypoints() || []
                    signalPathForDisplay = []
                    lengthPathForDisplay = []
                    smoothPathForDisplay = []
                    Qt.callLater(_refreshPathComparisonPanel)
                    dropPanel.hide()
                }
            }*/
        }
    }

    function downloadClicked(title) {
        if (_planMasterController.dirty) {
            mainWindow.showMessageDialog(title,
                                         qsTr("You have unsaved/unsent changes. Loading from the Vehicle will lose these changes. Are you sure you want to load from the Vehicle?"),
                                         StandardButton.Yes | StandardButton.Cancel,
                                         function() { _planMasterController.loadFromVehicle() })
        } else {
            _planMasterController.loadFromVehicle()
        }
    }

    Component {
        id: greenlandDropPanel

        Rectangle {
            width: 240
            height: 320
            clip: true
            color: "#CC000000"
            radius: 6
            border.color: "#4000FF00"
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 10

                QGCLabel {
                    text: qsTr("Greenland Editor")
                    color: "white"
                    font.bold: true
                }

                QGCButton {
                    text: qsTr("Add Rectangle")
                    Layout.fillWidth: true
                    onClicked: {
                        console.log("[Greenland] Add Rectangle button clicked")
                        editorMap.addGreenland()
                        dropPanel.hide()
                    }
                }

                QGCButton {
                    text: qsTr("Remove Selected")
                    Layout.fillWidth: true
                    enabled: editorMap.greenlands && editorMap.greenlands.length > 0
                    onClicked: {
                        editorMap.removeSelectedGreenland()
                        dropPanel.hide()
                    }
                }
                QGCButton {
                    Layout.fillWidth: true
                    text: editorMap.showGreenlandLayer ? qsTr("Hide Greenland") : qsTr("Show Greenland")
                    onClicked: {
                        editorMap.showGreenlandLayer = !editorMap.showGreenlandLayer
                        // 可选：隐藏时退出编辑模式，避免“看不见但还在编辑”
                        if (!editorMap.showGreenlandLayer) {
                            editorMap.greenlandEditMode = false
                        }
                    }
                }
                QGCButton {
                    Layout.fillWidth: true
                    text: editorMap.showGreenlandLabels ? qsTr("Hide Labels") : qsTr("Show Labels")
                    onClicked: {
                        editorMap.showGreenlandLabels = !editorMap.showGreenlandLabels
                    }
                }
                QGCCheckBox {
                    text: qsTr("Edit Mode")
                    checked: editorMap.greenlandEditMode
                    textColor: "white"
                    onClicked: editorMap.greenlandEditMode = checked
                }

                QGCButton {
                    text: qsTr("Exit Edit Mode")
                    Layout.fillWidth: true
                    enabled: editorMap.greenlandEditMode
                    onClicked: {
                        editorMap.exitGreenlandEditMode()
                        dropPanel.hide()
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    QGCButton {
                        text: qsTr("Prev")
                        Layout.fillWidth: true
                        enabled: editorMap.greenlands && editorMap.greenlands.length > 0
                        onClicked: {
                            var arr = editorMap.greenlands
                            if (!arr || arr.length === 0) return

                            var idx = 0
                            for (var i = 0; i < arr.length; i++) {
                                if (arr[i].gid === editorMap.selectedGreenlandId) { idx = i; break }
                            }
                            idx = (idx - 1 + arr.length) % arr.length
                            editorMap.selectedGreenlandId = arr[idx].gid
                            editorMap.greenlandEditMode = true
                        }
                    }

                    QGCButton {
                        text: qsTr("Next")
                        Layout.fillWidth: true
                        enabled: editorMap.greenlands && editorMap.greenlands.length > 0
                        onClicked: {
                            var arr = editorMap.greenlands
                            if (!arr || arr.length === 0) return

                            var idx = 0
                            for (var i = 0; i < arr.length; i++) {
                                if (arr[i].gid === editorMap.selectedGreenlandId) { idx = i; break }
                            }
                            idx = (idx + 1) % arr.length
                            editorMap.selectedGreenlandId = arr[idx].gid
                            editorMap.greenlandEditMode = true
                        }
                    }
                }
                QGCLabel {
                    text: qsTr("Count: %1").arg(editorMap.greenlands ? editorMap.greenlands.length : 0)
                    color: "#CCFFFFFF"
                }
            }
        }
    }
    Component {
        id: waterDropPanel

        Rectangle {
            width: 240
            height: 320
            clip: true
            color: "#CC000000"
            radius: 6
            border.color: "#400066FF"
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 10

                QGCLabel {
                    text: qsTr("Water Editor")
                    color: "white"
                    font.bold: true
                }

                QGCButton {
                    text: qsTr("Add Rectangle")
                    Layout.fillWidth: true
                    onClicked: {
                        editorMap.addWater()
                        dropPanel.hide()
                    }
                }

                QGCButton {
                    text: qsTr("Remove Selected")
                    Layout.fillWidth: true
                    enabled: editorMap.waters && editorMap.waters.length > 0
                    onClicked: {
                        editorMap.removeSelectedWater()
                        dropPanel.hide()
                    }
                }
                QGCButton {
                    Layout.fillWidth: true
                    text: editorMap.showWaterLayer ? qsTr("Hide Water") : qsTr("Show Water")
                    onClicked: {
                        editorMap.showWaterLayer = !editorMap.showWaterLayer
                        if (!editorMap.showWaterLayer) {
                            editorMap.waterEditMode = false
                        }
                    }
                }
                QGCButton {
                    Layout.fillWidth: true
                    text: editorMap.showWaterLabels ? qsTr("Hide Labels") : qsTr("Show Labels")
                    onClicked: {
                        editorMap.showWaterLabels = !editorMap.showWaterLabels
                    }
                }
                QGCCheckBox {
                    text: qsTr("Edit Mode")
                    checked: editorMap.waterEditMode
                    textColor: "white"
                    onClicked: editorMap.waterEditMode = checked
                }

                QGCButton {
                    text: qsTr("Exit Edit Mode")
                    Layout.fillWidth: true
                    enabled: editorMap.waterEditMode
                    onClicked: {
                        editorMap.exitWaterEditMode()
                        dropPanel.hide()
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    QGCButton {
                        text: qsTr("Prev")
                        Layout.fillWidth: true
                        enabled: editorMap.waters && editorMap.waters.length > 0
                        onClicked: {
                            var arr = editorMap.waters
                            if (!arr || arr.length === 0) return

                            var idx = 0
                            for (var i = 0; i < arr.length; i++) {
                                if (arr[i].wid === editorMap.selectedWaterId) { idx = i; break }
                            }
                            idx = (idx - 1 + arr.length) % arr.length
                            editorMap.selectedWaterId = arr[idx].wid
                            editorMap.waterEditMode = true
                        }
                    }

                    QGCButton {
                        text: qsTr("Next")
                        Layout.fillWidth: true
                        enabled: editorMap.waters && editorMap.waters.length > 0
                        onClicked: {
                            var arr = editorMap.waters
                            if (!arr || arr.length === 0) return

                            var idx = 0
                            for (var i = 0; i < arr.length; i++) {
                                if (arr[i].wid === editorMap.selectedWaterId) { idx = i; break }
                            }
                            idx = (idx + 1) % arr.length
                            editorMap.selectedWaterId = arr[idx].wid
                            editorMap.waterEditMode = true
                        }
                    }
                }

                QGCLabel {
                    text: qsTr("Count: %1").arg(editorMap.waters ? editorMap.waters.length : 0)
                    color: "#CCFFFFFF"
                }
            }
        }
    }
    Component {
        id: buildingDenseDropPanel

        Rectangle {
            width: 240
            height: 240
            clip: true
            color: "#CC000000"
            radius: 6
            border.color: "#40FF8800"
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 10

                QGCLabel {
                    text: qsTr("BuildingDense Editor")
                    color: "white"
                    font.bold: true
                }

                QGCButton {
                    text: qsTr("Add Rectangle")
                    Layout.fillWidth: true
                    onClicked: {
                        editorMap.addBuildingDense()
                        dropPanel.hide()
                    }
                }

                QGCButton {
                    text: qsTr("Remove Selected")
                    Layout.fillWidth: true
                    enabled: editorMap.buildingsDense && editorMap.buildingsDense.length > 0
                    onClicked: {
                        editorMap.removeSelectedBuildingDense()
                        dropPanel.hide()
                    }
                }
                QGCButton {
                    Layout.fillWidth: true
                    text: editorMap.showBuildingLayer ? qsTr("Hide Building") : qsTr("Show Building")
                    onClicked: {
                        editorMap.showBuildingLayer = !editorMap.showBuildingLayer
                        if (!editorMap.showBuildingLayer) {
                            editorMap.buildingDenseEditMode = false
                        }
                    }
                }
                QGCButton {
                    Layout.fillWidth: true
                    text: editorMap.showBuildingLabels ? qsTr("Hide Labels") : qsTr("Show Labels")
                    onClicked: {
                        editorMap.showBuildingLabels = !editorMap.showBuildingLabels
                    }
                }
                QGCCheckBox {
                    text: qsTr("Edit Mode")
                    checked: editorMap.buildingDenseEditMode
                    textColor: "white"
                    onClicked: editorMap.buildingDenseEditMode = checked
                }

                QGCButton {
                    text: qsTr("Exit Edit Mode")
                    Layout.fillWidth: true
                    enabled: editorMap.buildingDenseEditMode
                    onClicked: {
                        editorMap.exitBuildingDenseEditMode()
                        dropPanel.hide()
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    QGCButton {
                        text: qsTr("Prev")
                        Layout.fillWidth: true
                        enabled: editorMap.buildingsDense && editorMap.buildingsDense.length > 0
                        onClicked: {
                            var arr = editorMap.buildingsDense
                            if (!arr || arr.length === 0) return

                            var idx = 0
                            for (var i = 0; i < arr.length; i++) {
                                if (arr[i].bdid === editorMap.selectedBuildingDenseId) { idx = i; break }
                            }
                            idx = (idx - 1 + arr.length) % arr.length
                            editorMap.selectedBuildingDenseId = arr[idx].bdid
                            editorMap.buildingDenseEditMode = true
                        }
                    }

                    QGCButton {
                        text: qsTr("Next")
                        Layout.fillWidth: true
                        enabled: editorMap.buildingsDense && editorMap.buildingsDense.length > 0
                        onClicked: {
                            var arr = editorMap.buildingsDense
                            if (!arr || arr.length === 0) return

                            var idx = 0
                            for (var i = 0; i < arr.length; i++) {
                                if (arr[i].bdid === editorMap.selectedBuildingDenseId) { idx = i; break }
                            }
                            idx = (idx + 1) % arr.length
                            editorMap.selectedBuildingDenseId = arr[idx].bdid
                            editorMap.buildingDenseEditMode = true
                        }
                    }
                }

                QGCLabel {
                    text: qsTr("Count: %1").arg(editorMap.buildingsDense ? editorMap.buildingsDense.length : 0)
                    color: "#CCFFFFFF"
                }
            }
        }
    }
    Component {
        id: syncDropPanel

        ColumnLayout {
            id:         columnHolder
            spacing:    _margin

            property string _overwriteText: qsTr("Plan overwrite")

            QGCLabel {
                id:                 unsavedChangedLabel
                Layout.fillWidth:   true
                wrapMode:           Text.WordWrap
                text:               globals.activeVehicle ?
                                        qsTr("You have unsaved changes. You should upload to your vehicle, or save to a file.") :
                                        qsTr("You have unsaved changes.")
                visible:            _planMasterController.dirty
            }

            SectionHeader {
                id:                 createSection
                Layout.fillWidth:   true
                text:               qsTr("Create Plan")
                showSpacer:         false
            }

            GridLayout {
                columns:            2
                columnSpacing:      _margin
                rowSpacing:         _margin
                Layout.fillWidth:   true
                visible:            createSection.visible

                Repeater {
                    model: _planMasterController.planCreators

                    Rectangle {
                        id:     button
                        width:  ScreenTools.defaultFontPixelHeight * 7
                        height: planCreatorNameLabel.y + planCreatorNameLabel.height
                        color:  button.pressed || button.highlighted ? qgcPal.buttonHighlight : qgcPal.button

                        property bool highlighted: mouseArea.containsMouse
                        property bool pressed:     mouseArea.pressed

                        Image {
                            id:                 planCreatorImage
                            anchors.left:       parent.left
                            anchors.right:      parent.right
                            source:             object.imageResource
                            sourceSize.width:   width
                            fillMode:           Image.PreserveAspectFit
                            mipmap:             true
                        }

                        QGCLabel {
                            id:                     planCreatorNameLabel
                            anchors.top:            planCreatorImage.bottom
                            anchors.left:           parent.left
                            anchors.right:          parent.right
                            horizontalAlignment:    Text.AlignHCenter
                            text:                   object.name
                            color:                  button.pressed || button.highlighted ? qgcPal.buttonHighlightText : qgcPal.buttonText
                        }

                        QGCMouseArea {
                            id:                 mouseArea
                            anchors.fill:       parent
                            hoverEnabled:       true
                            preventStealing:    true
                            onClicked:          {
                                if (_planMasterController.containsItems) {
                                    createPlanRemoveAllPromptDialog.createObject(mainWindow, { mapCenter: _mapCenter(), planCreator: object }).open()
                                } else {
                                    object.createPlan(_mapCenter())
                                }
                                dropPanel.hide()
                            }

                            function _mapCenter() {
                                var centerPoint = Qt.point(editorMap.centerViewport.left + (editorMap.centerViewport.width / 2), editorMap.centerViewport.top + (editorMap.centerViewport.height / 2))
                                return editorMap.toCoordinate(centerPoint, false /* clipToViewPort */)
                            }
                        }
                    }
                }
            }

            SectionHeader {
                id:                 storageSection
                Layout.fillWidth:   true
                text:               qsTr("Storage")
            }

            GridLayout {
                columns:            3
                rowSpacing:         _margin
                columnSpacing:      ScreenTools.defaultFontPixelWidth
                visible:            storageSection.visible

                QGCButton {
                    text:               qsTr("Open...")
                    Layout.fillWidth:   true
                    enabled:            !_planMasterController.syncInProgress
                    onClicked: {
                        dropPanel.hide()
                        if (_planMasterController.dirty) {
                            showLoadFromFileOverwritePrompt(columnHolder._overwriteText)
                        } else {
                            _planMasterController.loadFromSelectedFile()
                        }
                    }
                }

                QGCButton {
                    text:               qsTr("Save")
                    Layout.fillWidth:   true
                    enabled:            !_planMasterController.syncInProgress && _planMasterController.currentPlanFile !== ""
                    onClicked: {
                        dropPanel.hide()
                        if(_planMasterController.currentPlanFile !== "") {
                            _planMasterController.saveToCurrent()
                        } else {
                            _planMasterController.saveToSelectedFile()
                        }
                    }
                }

                QGCButton {
                    text:               qsTr("Save As...")
                    Layout.fillWidth:   true
                    enabled:            !_planMasterController.syncInProgress && _planMasterController.containsItems
                    onClicked: {
                        dropPanel.hide()
                        _planMasterController.saveToSelectedFile()
                    }
                }

                QGCButton {
                    Layout.columnSpan:  3
                    Layout.fillWidth:   true
                    text:               qsTr("Save Mission Waypoints As KML...")
                    enabled:            !_planMasterController.syncInProgress && _visualItems.count > 1
                    onClicked: {
                        // First point does not count
                        if (_visualItems.count < 2) {
                            mainWindow.showMessageDialog(qsTr("KML"), qsTr("You need at least one item to create a KML."))
                            return
                        }
                        dropPanel.hide()
                        _planMasterController.saveKmlToSelectedFile()
                    }
                }
            }

            SectionHeader {
                id:                 vehicleSection
                Layout.fillWidth:   true
                text:               qsTr("Vehicle")
            }

            RowLayout {
                Layout.fillWidth:   true
                spacing:            _margin
                visible:            vehicleSection.visible

                QGCButton {
                    text:               qsTr("Upload")
                    Layout.fillWidth:   true
                    enabled:            !_planMasterController.offline && !_planMasterController.syncInProgress && _planMasterController.containsItems
                    visible:            !QGroundControl.corePlugin.options.disableVehicleConnection
                    onClicked: {
                        dropPanel.hide()
                        _planMasterController.upload()
                    }
                }

                QGCButton {
                    text:               qsTr("Download")
                    Layout.fillWidth:   true
                    enabled:            !_planMasterController.offline && !_planMasterController.syncInProgress
                    visible:            !QGroundControl.corePlugin.options.disableVehicleConnection

                    onClicked: {
                        dropPanel.hide()
                        downloadClicked(columnHolder._overwriteText)
                    }
                }

                QGCButton {
                    text:               qsTr("Clear")
                    Layout.fillWidth:   true
                    Layout.columnSpan:  2
                    enabled:            !_planMasterController.offline && !_planMasterController.syncInProgress
                    visible:            !QGroundControl.corePlugin.options.disableVehicleConnection
                    onClicked: {
                        dropPanel.hide()
                        clearButtonClicked()
                    }
                }
            }
        }
    }
}
