/****************************************************************************
 *
 * (c) 2009-2020 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

import QtQuick          2.3
import QtLocation       5.3
import QtPositioning    5.3

import QGroundControl           1.0
import QGroundControl.Palette   1.0

/// The MissionLineView control is used to add lines between mission items
MapItemView {
    property bool showSpecialVisual: false
    property real lineWidth: 3
    property real lineZ: QGroundControl.zOrderWaypointLines
    property color lineColor: "#123F9D"
    property color collisionLineColor: "red"
    property color specialLineColor: "green"
    delegate: MapPolyline {
        line.width: lineWidth
        // Note: Special visuals for ROI are hacked out for now since they are not working correctly
        line.color: _hasCollision ?
                        collisionLineColor :
                        (_showSpecialVisual ? specialLineColor : lineColor)
        z:          lineZ
        path:       object && object.coordinate1.isValid && object.coordinate2.isValid ? [ object.coordinate1, object.coordinate2 ] : []

        property bool _terrainCollision: object ? object.terrainCollision : false
        property bool _weatherCollision: object ? object.weatherCollision : false
        property bool _hasCollision: object ? (object.hasCollision || object.terrainCollision || object.weatherCollision) : false
        property bool _showSpecialVisual:   object && showSpecialVisual && object.specialVisual
    }
}
