// SignalStrengthLayer.qml
// Renders a signal strength heat/contour overlay based on tower positions.
// Strength model: sum_i ( power / (d_i^attenExp + epsilon) ) with optional max range cutoff.
// Simplified for demo: power=1, attenExp=2 (inverse square). Color ramp from green (strong) to red (weak).

import QtQuick 2.12
import QtLocation 5.3
import QtPositioning 5.3
import QGroundControl 1.0

Item {
    id: root
    // Model providing tower entries { latitude, longitude, name }
    // Removed invalid alias (previously 'property alias model: towerModel') which referenced no id.
    property var towerModel: null
    property real attenExp: 2.0
    property real radiusMeters: 8000        // influence radius per tower
    property int gridSize: 64               // number of samples per side
    property real maxComposite: 0           // updated after compute
    property bool contours: true
    property int contourLevels: 8
    property real opacityFactor: 0.45

    // Map object injected by parent
    property var map: null

    visible: !!towerModel && towerModel.count > 0 && map

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            if (!root.map || !towerModel || towerModel.count === 0) return
            var ctx = getContext('2d')
            ctx.clearRect(0,0,width,height)
            var w = width; var h = height
            var img = ctx.createImageData(w,h)
            var data = img.data
            // Precompute composite strength per pixel row sampling at lower resolution then upscale
            var gs = root.gridSize
            var cellW = w/gs
            var cellH = h/gs
            var strengths = []
            var maxS = 0
            for (var gy=0; gy<gs; gy++) {
                for (var gx=0; gx<gs; gx++) {
                    var px = (gx+0.5)*cellW
                    var py = (gy+0.5)*cellH
                    var coord = root.map.toCoordinate(Qt.point(px, py))
                    if (!coord.isValid) continue
                    var composite = 0
                    for (var ti=0; ti<towerModel.count; ti++) {
                        var tw = towerModel.get(ti)
                        var d = haversineMeters(coord.latitude, coord.longitude, tw.latitude, tw.longitude)
                        if (d < radiusMeters) {
                            var eff = 1 / Math.pow(d + 20, attenExp) // +20m to avoid singularity
                            composite += eff
                        }
                    }
                    if (composite > maxS) maxS = composite
                    strengths.push(composite)
                }
            }
            root.maxComposite = maxS
            // Draw cells
            var idx=0
            for (var gy=0; gy<gs; gy++) {
                for (var gx=0; gx<gs; gx++) {
                    var s = strengths[idx++]
                    if (maxS > 0) s = s / maxS
                    var col = colorRamp(s)
                    var x0 = Math.floor(gx*cellW)
                    var y0 = Math.floor(gy*cellH)
                    var x1 = Math.floor((gx+1)*cellW)
                    var y1 = Math.floor((gy+1)*cellH)
                    ctx.fillStyle = col
                    ctx.fillRect(x0,y0,x1-x0,y1-y0)
                }
            }
            if (root.contours) drawContours(ctx, strengths, gs, gs)
        }

        function colorRamp(t) { // t in [0,1]
            // green (strong) -> yellow -> red (weak)
            var r,g,b
            var tt = Math.max(0, Math.min(1,t))
            // invert so strong=green at t=1; we computed t=signalStrengthNormalized
            var v = tt
            // Use simple gradient: 0 -> red, 0.5 -> yellow, 1 -> green
            if (v < 0.5) {
                var f = v/0.5
                r = 255
                g = Math.round(255*f)
                b = 0
            } else {
                var f2 = (v-0.5)/0.5
                r = Math.round(255*(1-f2))
                g = 255
                b = 0
            }
            return 'rgba('+r+','+g+','+b+','+root.opacityFactor+')'
        }

        function drawContours(ctx, strengths, wCells, hCells) {
            var levels = root.contourLevels
            if (levels < 2) return
            ctx.lineWidth = 1
            for (var l=1; l<levels; l++) {
                var threshold = l/(levels)
                ctx.strokeStyle = 'rgba(0,0,0,' + (0.15 + 0.25*(l/levels)) + ')'
                marchingSquares(ctx, strengths, wCells, hCells, threshold)
            }
        }

        function marchingSquares(ctx, strengths, wCells, hCells, threshold) {
            var cellW = width / wCells
            var cellH = height / hCells
            ctx.beginPath()
            for (var y=0; y<hCells-1; y++) {
                for (var x=0; x<wCells-1; x++) {
                    var i = y*wCells + x
                    var s0 = strengths[i]
                    var s1 = strengths[i+1]
                    var s2 = strengths[i+wCells]
                    var s3 = strengths[i+wCells+1]
                    var n0 = root.maxComposite > 0 ? s0/root.maxComposite : 0
                    var n1 = root.maxComposite > 0 ? s1/root.maxComposite : 0
                    var n2 = root.maxComposite > 0 ? s2/root.maxComposite : 0
                    var n3 = root.maxComposite > 0 ? s3/root.maxComposite : 0
                    var caseIndex = 0
                    if (n0 >= threshold) caseIndex |= 1
                    if (n1 >= threshold) caseIndex |= 2
                    if (n3 >= threshold) caseIndex |= 4
                    if (n2 >= threshold) caseIndex |= 8
                    if (caseIndex === 0 || caseIndex === 15) continue
                    var x0 = x*cellW, y0 = y*cellH
                    var x1 = x0 + cellW, y1 = y0 + cellH
                    var xm = x0 + cellW/2, ym = y0 + cellH/2
                    switch(caseIndex) {
                        case 1: case 14: ctx.moveTo(x0, ym); ctx.lineTo(xm, y0); break
                        case 2: case 13: ctx.moveTo(xm, y0); ctx.lineTo(x1, ym); break
                        case 3: case 12: ctx.moveTo(x0, ym); ctx.lineTo(x1, ym); break
                        case 4: case 11: ctx.moveTo(x1, ym); ctx.lineTo(xm, y1); break
                        case 5: ctx.moveTo(x0, ym); ctx.lineTo(xm, y0); ctx.moveTo(x1, ym); ctx.lineTo(xm, y1); break
                        case 6: case 9: ctx.moveTo(xm, y0); ctx.lineTo(xm, y1); break
                        case 7: case 8: ctx.moveTo(x0, ym); ctx.lineTo(xm, y1); break
                        case 10: ctx.moveTo(x0, ym); ctx.lineTo(xm, y0); ctx.moveTo(xm, y1); ctx.lineTo(x1, ym); break
                    }
                }
            }
            ctx.stroke()
        }

        function haversineMeters(lat1, lon1, lat2, lon2) {
            var R = 6371000
            var dLat = (lat2-lat1) * Math.PI/180
            var dLon = (lon2-lon1) * Math.PI/180
            var a = Math.sin(dLat/2)*Math.sin(dLat/2) + Math.cos(lat1*Math.PI/180)*Math.cos(lat2*Math.PI/180)*Math.sin(dLon/2)*Math.sin(dLon/2)
            var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
            return R * c
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // Update when towers change or map pans/zooms
    Timer {
        id: refreshTimer
        interval: 800
        repeat: true
        running: root.visible
        onTriggered: canvas.requestPaint()
    }

    Connections { target: map; function onCenterChanged() { canvas.requestPaint() } }
    Connections { target: map; function onZoomLevelChanged() { canvas.requestPaint() } }
    Connections { target: towerModel; function onCountChanged() { canvas.requestPaint() } }
    onTowerModelChanged: canvas.requestPaint()
}
