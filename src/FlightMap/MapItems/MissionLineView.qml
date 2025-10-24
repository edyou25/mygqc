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
    delegate: MapPolyline {
        line.width: 3
        // Note: Special visuals for ROI are hacked out for now since they are not working correctly
        line.color: _hasCollision ?
                        "red" :
                        (false/*showSpecialVisual*/ ? "green" : QGroundControl.globalPalette.mapMissionTrajectory)
        z:          QGroundControl.zOrderWaypointLines
        path:       object && object.coordinate1.isValid && object.coordinate2.isValid ? [ object.coordinate1, object.coordinate2 ] : []

        property bool _terrainCollision: {
            var result = object && object.terrainCollision || false
            console.log("[MissionLineView] _terrainCollision:", result, "object:", !!object)
            return result
        }
        property bool _weatherCollision: {
            var result = object && object.weatherCollision || false
            console.log("[MissionLineView] _weatherCollision:", result, "object:", !!object)
            return result
        }
        property bool _hasCollision: {
            var result = object && (object.hasCollision || object.terrainCollision || object.weatherCollision) || false
            console.log("[MissionLineView] _hasCollision:", result, "hasCollision:", object ? object.hasCollision : "no object", "terrain:", object ? object.terrainCollision : "no object", "weather:", object ? object.weatherCollision : "no object")
            return result
        }
        property bool _showSpecialVisual:   object && showSpecialVisual && object.specialVisual
    }
}
