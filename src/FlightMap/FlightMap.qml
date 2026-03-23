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
import QtLocation       5.3
import QtPositioning    5.3
import QtQuick.Dialogs  1.2

import QGroundControl                       1.0
import QGroundControl.FactSystem            1.0
import QGroundControl.Controls              1.0
import QGroundControl.FlightMap             1.0
import QGroundControl.ScreenTools           1.0
import QGroundControl.MultiVehicleManager   1.0
import QGroundControl.Vehicle               1.0
import QGroundControl.QGCPositionManager    1.0

Map {
    id: _map

    //-- Qt 5.9 has rotation gesture enabled by default. Here we limit the possible gestures.
    gesture.acceptedGestures:   MapGestureArea.PinchGesture | MapGestureArea.PanGesture | MapGestureArea.FlickGesture
    gesture.flickDeceleration:  3000
    plugin:                     Plugin { name: "QGroundControl" }

    // https://bugreports.qt.io/browse/QTBUG-82185
    opacity:                    0.99

    property string mapName:                        'defaultMap'
    property bool   isSatelliteMap:                 activeMapType.name.indexOf("Satellite") > -1 || activeMapType.name.indexOf("Hybrid") > -1
    property var    gcsPosition:                    QGroundControl.qgcPositionManger.gcsPosition
    property real   gcsHeading:                     QGroundControl.qgcPositionManger.gcsHeading
    property bool   allowGCSLocationCenter:         false   ///< true: map will center/zoom to gcs location one time
    property bool   allowVehicleLocationCenter:     false   ///< true: map will center/zoom to vehicle location one time
    property bool   firstGCSPositionReceived:       false   ///< true: first gcs position update was responded to
    property bool   firstVehiclePositionReceived:   false   ///< true: first vehicle position update was responded to
    property bool   planView:                       false   ///< true: map being using for Plan view, items should be draggable

    readonly property real  maxZoomLevel: 20
    readonly property real  towerOverlayZ: 2000000
    // Signal strength layer visibility (contours always on when layer visible)
    property bool showSignalStrengthLayer: false
    property var  signalStrengthLayer: null

    property var    _activeVehicle:             QGroundControl.multiVehicleManager.activeVehicle
    property var    _activeVehicleCoordinate:   _activeVehicle ? _activeVehicle.coordinate : QtPositioning.coordinate()

    function setVisibleRegion(region) {
        // TODO: Is this still necessary with Qt 5.11?
        // This works around a bug on Qt where if you set a visibleRegion and then the user moves or zooms the map
        // and then you set the same visibleRegion the map will not move/scale appropriately since it thinks there
        // is nothing to do.
        _map.visibleRegion = QtPositioning.rectangle(QtPositioning.coordinate(0, 0), QtPositioning.coordinate(0, 0))
        _map.visibleRegion = region
    }

    function _possiblyCenterToVehiclePosition() {
        if (!firstVehiclePositionReceived && allowVehicleLocationCenter && _activeVehicleCoordinate.isValid) {
            firstVehiclePositionReceived = true
            center = _activeVehicleCoordinate
            zoomLevel = QGroundControl.flightMapInitialZoom
        }
    }

    function centerToSpecifiedLocation() {
        specifyMapPositionDialog.createObject(mainWindow).open()
    }

    Component {
        id: specifyMapPositionDialog
        EditPositionDialog {
            title:                  qsTr("Specify Position")
            coordinate:             center
            onCoordinateChanged:    center = coordinate
        }
    }

    // Center map to gcs location
    onGcsPositionChanged: {
        if (gcsPosition.isValid && allowGCSLocationCenter && !firstGCSPositionReceived && !firstVehiclePositionReceived) {
            firstGCSPositionReceived = true
            //-- Only center on gsc if we have no vehicle (and we are supposed to do so)
            var _activeVehicleCoordinate = _activeVehicle ? _activeVehicle.coordinate : QtPositioning.coordinate()
            if(QGroundControl.settingsManager.flyViewSettings.keepMapCenteredOnVehicle.rawValue || !_activeVehicleCoordinate.isValid)
                center = gcsPosition
        }
    }

    function updateActiveMapType() {
        var settings =  QGroundControl.settingsManager.flightMapSettings
        var fullMapName = settings.mapProvider.value + " " + settings.mapType.value

        for (var i = 0; i < _map.supportedMapTypes.length; i++) {
            if (fullMapName === _map.supportedMapTypes[i].name) {
                _map.activeMapType = _map.supportedMapTypes[i]
                return
            }
        }
    }

    on_ActiveVehicleCoordinateChanged: _possiblyCenterToVehiclePosition()

    onMapReadyChanged: {
        if (_map.mapReady) {
            updateActiveMapType()
            _possiblyCenterToVehiclePosition()
        }
    }

    Connections {
        target:             QGroundControl.settingsManager.flightMapSettings.mapType
        function onRawValueChanged() { updateActiveMapType() }
    }

    Connections {
        target:             QGroundControl.settingsManager.flightMapSettings.mapProvider
        function onRawValueChanged() { updateActiveMapType() }
    }

    /// Ground Station location
    MapQuickItem {
        anchorPoint.x:  sourceItem.width / 2
        anchorPoint.y:  sourceItem.height / 2
        visible:        gcsPosition.isValid
        coordinate:     gcsPosition

        sourceItem: Image {
            id:             mapItemImage
            source:         isNaN(gcsHeading) ? "/res/QGCLogoFull" : "/res/QGCLogoArrow"
            mipmap:         true
            antialiasing:   true
            fillMode:       Image.PreserveAspectFit
            height:         ScreenTools.defaultFontPixelHeight * (isNaN(gcsHeading) ? 1.75 : 2.5 )
            sourceSize.height: height
            transform: Rotation {
                origin.x:       mapItemImage.width  / 2
                origin.y:       mapItemImage.height / 2
                angle:          isNaN(gcsHeading) ? 0 : gcsHeading
            }
        }
    }

    // Tower markers loaded from embedded JSON resource /data/towers.json
    ListModel { id: towerModel }
    QtObject {
        Component.onCompleted: {
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    try {
                        var arr = JSON.parse(xhr.responseText)
                        for (var i=0; i<arr.length; i++) {
                            var isSensor = (arr[i].type || (arr[i].name.indexOf('Sensor') !== -1 ? 'sensor' : 'tower')) === 'sensor'
                            var parsedNoFlyRadius = Number(arr[i].no_fly_radius)
                            if (!isFinite(parsedNoFlyRadius)) {
                                parsedNoFlyRadius = isSensor ? 600 : 500
                            }
                            var parsedHeight = Number(arr[i].height)
                            if (!isFinite(parsedHeight)) {
                                parsedHeight = 100
                            }
                            var weatherType = (arr[i].weather_type !== undefined && arr[i].weather_type !== null)
                                    ? arr[i].weather_type
                                    : (isSensor ? (parsedNoFlyRadius > 0 ? 'no_fly' : 'suitable') : '')
                            var parsedInfluenceRadius = Number(arr[i].influence_radius)
                            if (!isFinite(parsedInfluenceRadius)) {
                                parsedInfluenceRadius = 0
                            }
                            towerModel.append({ 
                                name: arr[i].name, 
                                latitude: arr[i].latitude, 
                                longitude: arr[i].longitude,
                                type: isSensor ? 'sensor' : 'tower',
                                no_fly_radius: parsedNoFlyRadius,
                                height: parsedHeight,
                                direction: arr[i].direction || 'up',
                                weather_type: weatherType,
                                influence_radius: parsedInfluenceRadius
                            })
                        }
                    } catch(e) {
                        console.log('Failed to parse towers.json', e)
                    }
                }
            }
            xhr.open('GET', 'qrc:/data/towers.json')
            xhr.send()
        }
    }

    MapItemView {
        z: _map.towerOverlayZ
        model: towerModel
        delegate: MapQuickItem {
            readonly property bool _isSensor: type === 'sensor'
            readonly property bool _compactTowerView: (!_isSensor) && (showSignalStrengthLayer || _map.zoomLevel < 15.0)
            coordinate: QtPositioning.coordinate(latitude, longitude)
            anchorPoint.x: icon.width / 2
            anchorPoint.y: icon.height
            z: _map.towerOverlayZ
            sourceItem: Column {
                spacing: _compactTowerView ? 0 : 2
                Image {
                    id: icon
                    source: _isSensor ? '/res/QGCLogoFull' : '/res/QGCLogoArrow'
                    width: _isSensor ? 48 : (_compactTowerView ? 18 : 32)
                    height: _isSensor ? 48 : (_compactTowerView ? 18 : 32)
                    fillMode: Image.PreserveAspectFit
                    smooth: !_compactTowerView
                }
                Rectangle {
                    visible: _isSensor || (!_compactTowerView && _map.zoomLevel >= 16.0)
                    radius: 5
                    color: _isSensor ? Qt.rgba(1,0,0,0.8) : Qt.rgba(0,0,0,0.6)
                    border.width: _isSensor ? 2 : 0
                    border.color: _isSensor ? 'white' : 'transparent'
                    anchors.horizontalCenter: parent.horizontalCenter
                    property int hPad: 8
                    property int vPad: 4
                    implicitWidth: label.implicitWidth + hPad * 2
                    implicitHeight: label.implicitHeight + vPad * 2
                    Text {
                        id: label
                        text: name
                        color: 'white'
                        font.pixelSize: _isSensor ? 18 : 14
                        font.bold: _isSensor
                        anchors.centerIn: parent
                    }
                }
            }
        }
    }

    // Signal strength heat/contour layer overlay
    Loader {
        active: showSignalStrengthLayer
        source: "qrc:/qml/QGroundControl/FlightMap/SignalStrengthLayer.qml"
        onLoaded: {
            item.map = _map
            item.towerModel = towerModel
            item.contours = towerModel.count <= 420 || _map.zoomLevel >= 16.0
            item.z = QGroundControl.zOrderMapItems - 1 // below markers
            signalStrengthLayer = item
        }
        anchors.fill: parent
        Connections {
            target: _map
            function onCenterChanged() { if (signalStrengthLayer) signalStrengthLayer.map = _map }
            function onZoomLevelChanged() {
                if (signalStrengthLayer) {
                    signalStrengthLayer.map = _map
                    signalStrengthLayer.contours = towerModel.count <= 420 || _map.zoomLevel >= 16.0
                }
            }
        }
    }

    // Weather no-fly circular zones overlay (stable Loader-based layer)
    property bool showWeatherLayer: false
    property var weatherNoFlyLayer: null
    Loader {
        id: weatherLoader
        active: showWeatherLayer
        source: "qrc:/qml/QGroundControl/FlightMap/WeatherNoFlyLayer.qml"
        onLoaded: {
            item.map = _map
            item.towerModel = towerModel
            item.z = QGroundControl.zOrderMapItems - 2
            weatherNoFlyLayer = item
        }
        onStatusChanged: {
            if (status === Loader.Error) {
                console.error('[FlightMap] Failed to load WeatherNoFlyLayer:', weatherLoader.sourceComponent)
            }
        }
        anchors.fill: parent
        Connections {
            target: _map
            function onCenterChanged() { 
                if (weatherNoFlyLayer) {
                    weatherNoFlyLayer.map = _map 
                }
            }
        }
    }
} // Map
