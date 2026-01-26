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
import QGroundControl                   1.0
import QGroundControl.FlightMap         1.0
import QGroundControl.ScreenTools       1.0
import QGroundControl.Controls          1.0
import QGroundControl.FactSystem        1.0
import QGroundControl.FactControls      1.0
import QGroundControl.Palette           1.0
import QGroundControl.Controllers       1.0
import QGroundControl.ShapeFileHelper   1.0
import Qt.labs.settings 1.0
import "./TowerOptimize.js" as TowerOpt

Item {
    id: _root
    // Greenland persistence (GLOBAL, permanent)
    Settings {
        id: greenlandSettings
        category: "Greenland"               // QSettings group name
        property string greenlandsJson: "[]"
        property int nextId: 1
    }
    // Water persistence (GLOBAL, permanent)
    Settings {
        id: waterSettings
        category: "Water"
        property string watersJson: "[]"
        property int nextId: 1
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
            editorMap.waters = editorMap.waters.concat([area])
        }

        editorMap.waterNextId = Math.max(maxId + 1, waterSettings.nextId || 1)
        waterSettings.nextId = editorMap.waterNextId

        if (editorMap.waters.length) {
            editorMap.selectedWaterId = editorMap.waters[editorMap.waters.length - 1].wid
        }

        console.log("[Water] restored count=", editorMap.waters.length, "nextId=", editorMap.waterNextId)
    }

    function saveWatersGlobal() {
        waterSettings.watersJson = _serializeWaters()
        waterSettings.nextId = editorMap.waterNextId
        _pushRegionAttractorsToCpp()
        console.log("[Attractors] greenlands=", editorMap.greenlands ? editorMap.greenlands.length : -1,
            "waters=", editorMap.waters ? editorMap.waters.length : -1)

        console.log("[Attractors] about to call setAttractors, pts=", pts.length)
        PathOptimizationManager.towerOptimizer.setAttractors(pts)
        console.log("[Attractors] called setAttractors OK")
    }

    function loadWatersGlobal() {
        _restoreWatersFromJson(waterSettings.watersJson)
        _pushRegionAttractorsToCpp()
    }

    function _pushRegionAttractorsToCpp() {
        console.log("[Attractors] ENTER _pushRegionAttractorsToCpp")
        if (typeof PathOptimizationManager === "undefined") return
        if (!PathOptimizationManager.towerOptimizer) return

        var pts = []

        if (editorMap.greenlands) {
            for (var i = 0; i < editorMap.greenlands.length; i++) {
                var g = editorMap.greenlands[i]
                if (!g || !g.path || g.path.length < 3) continue
                var c = editorMap._pathCenter(g.path)
                pts.push({ lat: c.latitude, lon: c.longitude, name: "Greenland" + g.gid, type: "greenland" })
            }
        }

        if (editorMap.waters) {
            for (var j = 0; j < editorMap.waters.length; j++) {
                var w = editorMap.waters[j]
                if (!w || !w.path || w.path.length < 3) continue
                var c2 = editorMap._pathCenter(w.path)
                pts.push({ lat: c2.latitude, lon: c2.longitude, name: "Water" + w.wid, type: "water" })
            }
        }

        PathOptimizationManager.towerOptimizer.setAttractors(pts)
        console.log("[Attractors] pushed:", pts.length)
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
            editorMap.greenlands = editorMap.greenlands.concat([area])
        }

        editorMap.greenlandNextId = Math.max(maxId + 1, greenlandSettings.nextId || 1)
        greenlandSettings.nextId = editorMap.greenlandNextId

        if (editorMap.greenlands.length) {
            editorMap.selectedGreenlandId = editorMap.greenlands[editorMap.greenlands.length - 1].gid
        }

        console.log("[Greenland] restored count=", editorMap.greenlands.length, "nextId=", editorMap.greenlandNextId)
    }

    function saveGreenlandsGlobal() {
        greenlandSettings.greenlandsJson = _serializeGreenlands()
        greenlandSettings.nextId = editorMap.greenlandNextId
        _pushRegionAttractorsToCpp()
    }

    function loadGreenlandsGlobal() {
        _restoreGreenlandsFromJson(greenlandSettings.greenlandsJson)
        _pushRegionAttractorsToCpp()
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
        console.log("[RoadLayer] bbox lat:", minLat, maxLat, "lon:", minLon, maxLon)
        return out
    }
    function loadRoadsFromResource(url) {
        console.log("[RoadLayer] loading:", url)

        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return

            console.log("[RoadLayer] xhr status=", xhr.status, "bytes=", (xhr.responseText ? xhr.responseText.length : 0))

            // status==0 常见于 qrc/本地读取
            if (xhr.status !== 200 && xhr.status !== 0) {
                console.warn("[RoadLayer] Failed to load", url, "status=", xhr.status)
                return
            }

            editorMap.roads = _parseRoadsFromGeoJSONText(xhr.responseText)
            editorMap.showRoadLayer = true
            // 强制跳到道路区域，方便验证“到底有没有画出来”
            if (editorMap.roads && editorMap.roads.length > 0
                    && editorMap.roads[0].path && editorMap.roads[0].path.length > 0) {
                var c = editorMap.roads[0].path[0]
                editorMap.center = c
                editorMap.zoomLevel = Math.max(editorMap.zoomLevel, 16)
                console.log("[RoadLayer] jump to:", c.latitude, c.longitude)
            }
        }
        xhr.send()
    }
    property bool planControlColapsed: false
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

    // Load towers once when PlanView root completes
    Component.onCompleted: {
        console.log("[PlanView] LOADED DEBUG_MARKER_20260113_ABC123")
        console.log('[PlanView] ===== Testing C++ Backend =====')
        console.log('[PlanView] typeof PathOptimizationManager:', typeof PathOptimizationManager)
        
        // C++后端初始化（用于碰撞检测）
        if (typeof PathOptimizationManager !== 'undefined') {
            console.log('[PlanView] ✓✓✓ C++ backend IS AVAILABLE!')
            console.log('[PlanView] Instance:', PathOptimizationManager)
            console.log('[PlanView] Calling C++ loadDefaultTowers()...')
            PathOptimizationManager.loadDefaultTowers()
            PathOptimizationManager.loadDefaultConfig()
            
            // 测试C++ A*算法
            try {
                console.log('[PlanView] ===== Testing C++ A* Algorithm =====')
                var testStart = QtPositioning.coordinate(22.710, 114.404, 100)
                var testEnd = QtPositioning.coordinate(22.712, 114.408, 100)
                
                console.log('[Test] Original waypoint:', testStart.latitude.toFixed(6), testStart.longitude.toFixed(6))
                console.log('[Test] Target waypoint:', testEnd.latitude.toFixed(6), testEnd.longitude.toFixed(6))
                
                // 计算原始信号强度
                var origSignal = PathOptimizationManager.towerOptimizer.calculateSignalStrength(testStart)
                console.log('[Test] Original signal strength:', origSignal.toFixed(4))
                
                // 运行C++ A*优化
                console.log('[Test] Running C++ A* optimization...')
                var optimized = PathOptimizationManager.towerOptimizer.optimizeSingleWaypoint(testStart, testEnd, 100)
                console.log('[Test] Optimized waypoint:', optimized.latitude.toFixed(6), optimized.longitude.toFixed(6))
                
                // 计算优化后的信号强度
                var optSignal = PathOptimizationManager.towerOptimizer.calculateSignalStrength(optimized)
                console.log('[Test] Optimized signal strength:', optSignal.toFixed(4))
                
                // 计算改善百分比
                var improvement = ((optSignal - origSignal) / Math.max(origSignal, 0.0001) * 100)
                console.log('[Test] Signal improvement:', improvement.toFixed(1), '%')
                
                // 计算移动距离
                var moved = testStart.distanceTo(optimized)
                console.log('[Test] Waypoint moved:', moved.toFixed(2), 'meters')
                
                console.log('[Test] ===== C++ A* Test Complete =====')
            } catch(e) {
                console.error('[Test] C++ A* test failed:', e.toString())
            }
        } else {
            console.log('[PlanView] ✗✗✗ C++ backend NOT available')
        }
        
        // JavaScript数据加载（用于信号计算和路径优化）
        console.log('[PlanView] Loading JavaScript towers data...')
        TowerOpt.loadTowers()
        // Restore global greenlands
        loadGreenlandsGlobal()
        loadWatersGlobal()
        _pushRegionAttractorsToCpp()
        loadRoadsFromResource("qrc:/roads/export.geojson")

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
            property var roads: []
            zoomLevel:                  QGroundControl.flightMapZoom
            center:                     QGroundControl.flightMapPosition

            // This is the center rectangle of the map which is not obscured by tools
            property rect centerViewport:   Qt.rect(_leftToolWidth + _margin,  _margin, editorMap.width - _leftToolWidth - _rightToolWidth - (_margin * 2), (terrainStatus.visible ? terrainStatus.y : height - _margin) - _margin)

            property real _leftToolWidth:       toolStrip.x + toolStrip.width
            property real _rightToolWidth:      rightPanel.width + rightPanel.anchors.rightMargin
            property real _nonInteractiveOpacity:  0.5

            // Initial map position duplicates Fly view position
            Component.onCompleted: {
                editorMap.center = QGroundControl.flightMapPosition
                //editorMap._dumpPossibleMapHandles()
            }

            QGCMapPalette { id: mapPal; lightColors: editorMap.isSatelliteMap }
            onZoomLevelChanged: {
                QGroundControl.flightMapZoom = zoomLevel
            }
            onCenterChanged: {
                QGroundControl.flightMapPosition = center
            }
            
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
                enabled: !editorMap.greenlandEditMode && !editorMap.waterEditMode
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
            }

            // Direction arrows in waypoint lines
            MapItemView {
                model: _editingLayer == _layerMission ? _missionController.directionArrows : undefined

                delegate: MapLineArrow {
                    fromCoord:      object ? object.coordinate1 : undefined
                    toCoord:        object ? object.coordinate2 : undefined
                    arrowPosition:  3
                    z:              QGroundControl.zOrderWaypointLines + 1
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
                model: editorMap.greenlands

                delegate: MapPolygon {
                    id: poly
                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    path: area && area.path ? area.path : []

                    color: selected ? "#6600FF66" : "#3300FF00"
                    border.width: selected ? 4 : 3
                    border.color: selected ? "#00FF66" : "#00CC00"

                    z: QGroundControl.zOrderWaypointLines + 5
                    opacity: 1

                    // 点击选中（并可选：自动进入编辑模式）
                    MouseArea {
                        anchors.fill: parent
                        enabled: true
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (!area) return

                            editorMap.selectedGreenlandId = area.gid
                            editorMap.greenlandEditMode = true

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
            // 1.5) Label (Greenland 1/2/3...)
            MapItemView {
                model: editorMap.greenlands

                delegate: MapQuickItem {
                    property var area: modelData
                    property bool selected: area && (area.gid === editorMap.selectedGreenlandId)

                    visible: area && area.path && area.path.length >= 3
                    z: QGroundControl.zOrderWaypointLines + 6
                    coordinate: visible ? editorMap._pathCenter(area.path) : QtPositioning.coordinate()

                    anchorPoint.x: sourceItem.width / 2
                    anchorPoint.y: sourceItem.height + 6

                    sourceItem: Rectangle {
                        color: selected ? "#CC00AA00" : "#AA000000"
                        radius: 4
                        border.width: 1
                        border.color: "#60FFFFFF"
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
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (area) {
                                editorMap.selectedGreenlandId = area.gid
                                editorMap.greenlandEditMode = true
                            }
                        }
                    }
                }
            }
            // 2) Center handle (drag to move whole shape)
            MapItemView {
                model: editorMap.greenlands

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
                        color: "#FF00FF66"
                        border.width: 2
                        border.color: "white"

                        Text {
                            anchors.centerIn: parent
                            text: "M"
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
                        color: "white"
                        border.width: 2
                        border.color: "#00FF00"

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
                model: editorMap.waters

                delegate: MapPolygon {
                    id: waterPoly
                    property var area: modelData
                    property bool selected: area && (area.wid === editorMap.selectedWaterId)

                    path: area && area.path ? area.path : []

                    color: selected ? "#660066FF" : "#330066FF"
                    border.width: selected ? 4 : 3
                    border.color: selected ? "#66CCFF" : "#3399FF"

                    z: QGroundControl.zOrderWaypointLines + 4

                    MouseArea {
                        anchors.fill: parent
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (!area) return

                            editorMap.selectedWaterId = area.wid
                            editorMap.waterEditMode = true

                            var mapP = editorMap.mapFromItem(parent, mouse.x, mouse.y)
                            if (editorMap._insertWaterVertexAtClick(area, mapP)) {
                                saveWatersGlobal()
                            }
                        }
                    }
                }
            }
            MapItemView {
                model: editorMap.waters

                delegate: MapQuickItem {
                    property var area: modelData
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
                        preventStealing: true
                        propagateComposedEvents: false
                        onClicked: {
                            mouse.accepted = true
                            if (area) {
                                editorMap.selectedWaterId = area.wid
                                editorMap.waterEditMode = true
                            }
                        }
                    }
                }
            }
            MapItemView {
                model: editorMap.waters

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
            function _pathCenter(path) {
                var lat = 0, lon = 0
                for (var i = 0; i < path.length; i++) {
                    lat += path[i].latitude
                    lon += path[i].longitude
                }
                return QtPositioning.coordinate(lat / path.length, lon / path.length)
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
                        iconSource: "/qmlimages/MapDrawShape.svg"
                        checkable: true
                        checked: editorMap.showSignalStrengthLayer
                        visible: toolStrip._isMissionLayer
                        onTriggered: editorMap.showSignalStrengthLayer = !editorMap.showSignalStrengthLayer
                    },
                    ToolStripAction {
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
                    ,
                    ToolStripAction {
                        id: weatherToggle
                        text: qsTr("Weather")
                        iconSource: "/qmlimages/MapDrawShape.svg"
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
                        iconSource: "/qmlimages/MapDrawShape.svg"
                        enabled: true
                        visible: toolStrip._isMissionLayer
                        dropPanelComponent: greenlandDropPanel
                    }
                    ,
                    ToolStripAction {
                        id: waterAction
                        text: qsTr("Water")
                        iconSource: "/qmlimages/MapDrawShape.svg"
                        enabled: true
                        visible: toolStrip._isMissionLayer
                        dropPanelComponent: waterDropPanel
                    }
                    ,
                    ToolStripAction {
                        id: roadToggleAction
                        text: qsTr("Roads")
                        iconSource: "/qmlimages/MapDrawShape.svg"   // 先复用一个现成图标，后续你想换再说
                        enabled: true
                        visible: toolStrip._isMissionLayer
                        checkable: true
                        checked: editorMap.showRoadLayer

                        onTriggered: {
                            editorMap.showRoadLayer = !editorMap.showRoadLayer
                            checked = editorMap.showRoadLayer   // 保险：让UI状态同步
                            console.log("[RoadLayer] toggled:", editorMap.showRoadLayer)
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
            id: weightPanel
            z: 9999
            radius: 6
            color: "#B0000000"
            border.color: "#40FFFFFF"
            border.width: 1

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: _toolsMargin

            width: Math.min(parent.width * 1, ScreenTools.defaultFontPixelWidth * 100)
            height: ScreenTools.defaultFontPixelHeight * 7.5
            visible: true

            property real signalWeightLocal: 0.50
            property real distanceWeightLocal: 0.50

            // 你要的“离边框空隙”就在这里调
            readonly property int sidePad: 24   // 左右留白
            readonly property int topPad: 16    // 上留白
            readonly property int bottomPad: 16 // 下留白

            // label 固定宽度（保证两行严格对齐）
            readonly property int labelW: 220

            // 内容容器：用 anchors 硬做 padding，必生效
            Item {
                id: content
                anchors.fill: parent
                anchors.leftMargin: weightPanel.sidePad
                anchors.rightMargin: weightPanel.sidePad
                anchors.topMargin: weightPanel.topPad
                anchors.bottomMargin: weightPanel.bottomPad

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Math.round(ScreenTools.defaultFontPixelHeight * 0.6)

                    // 标题居中
                    QGCLabel {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("Tower Optimize Weights")
                        color: "white"
                        font.bold: true
                    }

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
                    TowerOpt.optimizeMissionAStar(_missionController, _planMasterController, 0.2)
                    dropPanel.hide()
                }
            }
            QGCButton {
                text: qsTr("RRT")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    TowerOpt.optimizeMissionRRT(_missionController, _planMasterController, 0.2)
                    dropPanel.hide()
                }
            }
            QGCButton {
                text: qsTr("A* New")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    TowerOpt.optimizeMissionAStarNew(_missionController, _planMasterController, 0.2)
                    dropPanel.hide()
                }
            }
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
            height: 240
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
            height: 240
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
