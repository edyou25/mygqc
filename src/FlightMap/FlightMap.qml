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
                            towerModel.append({ 
                                name: arr[i].name, 
                                latitude: arr[i].latitude, 
                                longitude: arr[i].longitude,
                                type: arr[i].type || (arr[i].name.indexOf('Sensor') !== -1 ? 'sensor' : 'tower'),
                                no_fly_radius: arr[i].no_fly_radius || (arr[i].name.indexOf('Sensor') !== -1 ? 600 : 500)
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
        model: towerModel
        delegate: MapQuickItem {
            coordinate: QtPositioning.coordinate(latitude, longitude)
            anchorPoint.x: icon.width / 2
            anchorPoint.y: icon.height
            z: QGroundControl.zOrderMapItems
            sourceItem: Column {
                spacing: 2
                Image {
                    id: icon
                    source: type === 'sensor' ? '/res/QGCLogoFull' : '/res/QGCLogoArrow'
                    width: type === 'sensor' ? 28 : 24
                    height: type === 'sensor' ? 28 : 24
                    fillMode: Image.PreserveAspectFit
                }
                Rectangle {
                    radius: 3
                    color: type === 'sensor' ? Qt.rgba(1,0,0,0.8) : Qt.rgba(0,0,0,0.6)
                    border.width: type === 'sensor' ? 1 : 0
                    border.color: type === 'sensor' ? 'white' : 'transparent'
                    anchors.horizontalCenter: parent.horizontalCenter
                    property int hPad: 4
                    property int vPad: 2
                    implicitWidth: label.implicitWidth + hPad * 2
                    implicitHeight: label.implicitHeight + vPad * 2
                    Text {
                        id: label
                        text: name
                        color: 'white'
                        font.pixelSize: 12
                        font.bold: type === 'sensor'
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
            item.contours = true
            item.z = QGroundControl.zOrderMapItems - 1 // below markers
            signalStrengthLayer = item
        }
        anchors.fill: parent
        Connections {
            target: _map
            function onCenterChanged() { if (signalStrengthLayer) signalStrengthLayer.map = _map }
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
            console.log('[FlightMap] WeatherNoFlyLayer loaded successfully')
            console.log('[FlightMap] towerModel count:', towerModel.count)
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
    
    // Debug: Monitor showWeatherLayer changes
    onShowWeatherLayerChanged: {
        console.log('[FlightMap] showWeatherLayer changed to:', showWeatherLayer)
    }
} // Map
