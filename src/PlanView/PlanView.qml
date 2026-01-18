/****************************************************************************
 *
 * (c) 2009-2020 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

import QtQuick          2.3
import QtQuick.Controls 1.2
import QtQuick.Dialogs  1.2
import QtLocation       5.3
import QtPositioning    5.3
import QtQuick.Layouts  1.2
import QtQuick.Window   2.2

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

    property bool planControlColapsed: false
    property var originalPathForDisplay: []  // 用于存储原始路径，触发QML更新

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
        console.log('[TowerOptimize] ===== PlanView _root Component.onCompleted =====')
        console.log('[TowerOptimize] PlanView loaded and initialized')
        console.log('[TowerOptimize] ===== Testing C++ Backend =====')
        console.log('[TowerOptimize] typeof PathOptimizationManager:', typeof PathOptimizationManager)
        
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
        
        Component.onCompleted: {
            console.log('[TowerOptimize] PlanView panel Component.onCompleted')
            console.log('[TowerOptimize]   - rightPanel exists:', !!rightPanel)
        }

        FlightMap {
            id:                         editorMap
            anchors.fill:               parent
            mapName:                    "MissionEditor"
            allowGCSLocationCenter:     true
            allowVehicleLocationCenter: true
            planView:                   true
            
            property alias astarDebugLayer: astarDebugLayer
            // Weather layer is now handled by FlightMap.qml
            
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
            }

            QGCMapPalette { id: mapPal; lightColors: editorMap.isSatelliteMap }

            onZoomLevelChanged: {
                QGroundControl.flightMapZoom = zoomLevel
            }
            onCenterChanged: {
                QGroundControl.flightMapPosition = center
            }
            
            // Weather layer visibility is now handled by FlightMap.qml

            // Weather layer is now handled by FlightMap.qml WeatherNoFlyLayer
            // Old Repeater removed to avoid conflicts

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    // Take focus to close any previous editing
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

            // 显示优化前的原始路径（用于对比）
            MapPolyline {
                id:                 originalPathPolyline
                line.width:         4  // 增加线宽，更明显
                line.color:         '#959b59'  // 红色显示原始路径，更醒目
                z:                  QGroundControl.zOrderWaypointLines - 1  // 在优化路径下方
                opacity:            _editingLayer == _layerMission && originalPathForDisplay.length > 0 ? 0.8 : 0  // 提高不透明度
                path:               originalPathForDisplay
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
                ]
            }

            model: toolStripActionList.model

            function allAddClickBoolsOff() {
                _addROIOnClick =        false
                addWaypointRallyPointAction.checked = false
            }

            onDropped: allAddClickBoolsOff()
        }

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
            
            Component.onCompleted: {
                console.log('[TowerOptimize] rightPanel Component.onCompleted')
                console.log('[TowerOptimize]   - width:', width, 'height:', height)
                console.log('[TowerOptimize]   - x:', x, 'y:', y)
                console.log('[TowerOptimize]   - anchors.rightMargin:', anchors.rightMargin)
            }
        }
        //-------------------------------------------------------
        // Path Comparison Panel (Left side of right panel)
        Loader {
            id:                 comparisonPanelLoader
            source:             "PathComparisonPanel.qml"
            anchors.right:      rightPanel.left
            anchors.rightMargin: _toolsMargin
            anchors.top:        parent.top
            anchors.bottom:     parent.bottom
            width:              400
            visible:            _editingLayer == _layerMission && item !== null
            
            active:             true  // 确保Loader是活动的
            
            // 立即输出初始状态
            property bool _initialized: false
            onActiveChanged: {
                console.log('[TowerOptimize] comparisonPanelLoader active changed:', active)
            }
            
            onSourceChanged: {
                console.log('[TowerOptimize] comparisonPanelLoader source changed:', source)
            }
            
            Component.onCompleted: {
                console.log('[TowerOptimize] ===== comparisonPanelLoader Component.onCompleted =====')
                console.log('[TowerOptimize]   - source:', source)
                console.log('[TowerOptimize]   - active:', active)
                console.log('[TowerOptimize]   - visible:', visible)
                console.log('[TowerOptimize]   - _editingLayer:', _editingLayer)
                console.log('[TowerOptimize]   - _layerMission:', _layerMission)
                console.log('[TowerOptimize]   - parent:', !!parent)
                console.log('[TowerOptimize]   - rightPanel:', !!rightPanel)
                console.log('[TowerOptimize]   - status:', status)
                console.log('[TowerOptimize] ===== Component.onCompleted end =====')
            }
            
            onLoaded: {
                console.log('[TowerOptimize] PathComparisonPanel loaded, item:', !!item)
                if (item) {
                    item.missionController = _missionController
                    console.log('[TowerOptimize] PathComparisonPanel missionController set')
                    // 延迟刷新，确保数据已准备好
                    Qt.callLater(function() {
                        if (item) {
                            item.refresh()
                        }
                    })
                }
            }
            
            onStatusChanged: {
                console.log('[TowerOptimize] ===== PathComparisonPanel status changed =====')
                console.log('[TowerOptimize]   - status:', status, '(0=Null, 1=Ready, 2=Loading, 3=Error)')
                console.log('[TowerOptimize]   - source:', source)
                console.log('[TowerOptimize]   - active:', active)
                console.log('[TowerOptimize]   - item:', !!item)
                console.log('[TowerOptimize]   - visible:', visible)
                
                if (status === Loader.Error) {
                    console.error('[TowerOptimize] ===== LOADER ERROR =====')
                    console.error('[TowerOptimize]   - source:', source)
                    console.error('[TowerOptimize]   - sourceComponent exists:', !!sourceComponent)
                    if (sourceComponent) {
                        console.error('[TowerOptimize]   - sourceComponent.status:', sourceComponent.status)
                        console.error('[TowerOptimize]   - sourceComponent.errorString:', sourceComponent.errorString())
                        console.error('[TowerOptimize]   - sourceComponent.errorLine:', sourceComponent.errorLine)
                        console.error('[TowerOptimize]   - sourceComponent.errorColumn:', sourceComponent.errorColumn)
                    }
                    console.error('[TowerOptimize]   - Try to get error from Loader')
                    try {
                        var errorInfo = comparisonPanelLoader.sourceComponent
                        if (errorInfo) {
                            console.error('[TowerOptimize]   - Error info:', JSON.stringify(errorInfo))
                        }
                    } catch(e) {
                        console.error('[TowerOptimize]   - Cannot get error info:', e)
                    }
                    console.error('[TowerOptimize] ===== ERROR END =====')
                } else if (status === Loader.Ready) {
                    console.log('[TowerOptimize] ===== PathComparisonPanel READY =====')
                    console.log('[TowerOptimize]   - visible:', visible)
                    console.log('[TowerOptimize]   - item:', !!item)
                    console.log('[TowerOptimize]   - item type:', item ? typeof item : 'null')
                    console.log('[TowerOptimize]   - editingLayer:', _editingLayer)
                    console.log('[TowerOptimize]   - layerMission:', _layerMission)
                    console.log('[TowerOptimize]   - anchors.right:', anchors.right)
                    console.log('[TowerOptimize]   - anchors.rightMargin:', anchors.rightMargin)
                    console.log('[TowerOptimize]   - width:', width, 'height:', height)
                    console.log('[TowerOptimize]   - x:', x, 'y:', y)
                    console.log('[TowerOptimize] ===== READY END =====')
                } else if (status === Loader.Loading) {
                    console.log('[TowerOptimize] PathComparisonPanel loading...')
                    console.log('[TowerOptimize]   - source:', source)
                } else if (status === Loader.Null) {
                    console.log('[TowerOptimize] PathComparisonPanel status: Null (not loaded)')
                }
                console.log('[TowerOptimize] ===== status changed end =====')
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
                    console.log('[TowerOptimize] A* optimization button clicked')
                    TowerOpt.optimizeMissionAStar(_missionController, _planMasterController, 0.2)
                    console.log('[TowerOptimize] A* Optimization completed')
                    // 更新原始路径显示
                    originalPathForDisplay = TowerOpt.getOriginalPathWaypoints() || []
                    console.log('[TowerOptimize] Original path waypoints:', originalPathForDisplay.length)
                    // 刷新对比面板
                    console.log('[TowerOptimize] Checking comparisonPanelLoader for A*, item:', !!comparisonPanelLoader.item)
                    console.log('[TowerOptimize]   - comparisonPanelLoader.status:', comparisonPanelLoader.status)
                    console.log('[TowerOptimize]   - comparisonPanelLoader.visible:', comparisonPanelLoader.visible)
                    if (comparisonPanelLoader.item) {
                        console.log('[TowerOptimize] Calling refresh on comparison panel (A*)')
                        comparisonPanelLoader.item.refresh()
                    } else {
                        console.warn('[TowerOptimize] comparisonPanelLoader.item is null (A*), status:', comparisonPanelLoader.status)
                    }
                    dropPanel.hide()
                }
            }
            QGCButton {
                text: qsTr("RRT")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    console.log('[TowerOptimize] RRT optimization button clicked')
                    TowerOpt.optimizeMissionRRT(_missionController, _planMasterController, 0.2)
                    console.log('[TowerOptimize] RRT Optimization completed')
                    // 更新原始路径显示
                    originalPathForDisplay = TowerOpt.getOriginalPathWaypoints() || []
                    console.log('[TowerOptimize] Original path waypoints:', originalPathForDisplay.length)
                    // 刷新对比面板
                    console.log('[TowerOptimize] Checking comparisonPanelLoader for RRT, item:', !!comparisonPanelLoader.item)
                    if (comparisonPanelLoader.item) {
                        console.log('[TowerOptimize] Calling refresh on comparison panel (RRT)')
                        comparisonPanelLoader.item.refresh()
                    } else {
                        console.warn('[TowerOptimize] comparisonPanelLoader.item is null (RRT)')
                    }
                    dropPanel.hide()
                }
            }
            QGCButton {
                text: qsTr("A* New")
                Layout.fillWidth: true
                enabled: toolStrip._isMissionLayer && _missionController.visualItems.count > 2
                onClicked: {
                    console.log('[TowerOptimize] A* New optimization button clicked')
                    TowerOpt.optimizeMissionAStarNew(_missionController, _planMasterController, 0.2)
                    console.log('[TowerOptimize] Optimization completed')
                    // 更新原始路径显示
                    originalPathForDisplay = TowerOpt.getOriginalPathWaypoints() || []
                    console.log('[TowerOptimize] Original path waypoints:', originalPathForDisplay.length)
                    // 刷新对比面板
                    console.log('[TowerOptimize] Checking comparisonPanelLoader')
                    console.log('[TowerOptimize]   - comparisonPanelLoader exists:', !!comparisonPanelLoader)
                    console.log('[TowerOptimize]   - comparisonPanelLoader.item:', !!comparisonPanelLoader.item)
                    console.log('[TowerOptimize]   - comparisonPanelLoader.visible:', comparisonPanelLoader.visible)
                    console.log('[TowerOptimize]   - comparisonPanelLoader.status:', comparisonPanelLoader.status)
                    if (comparisonPanelLoader.item) {
                        console.log('[TowerOptimize] Calling refresh on comparison panel')
                        comparisonPanelLoader.item.refresh()
                    } else {
                        console.warn('[TowerOptimize] comparisonPanelLoader.item is null, cannot refresh')
                        console.warn('[TowerOptimize] Loader status:', comparisonPanelLoader.status)
                        console.warn('[TowerOptimize] Loader source:', comparisonPanelLoader.source)
                    }
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
