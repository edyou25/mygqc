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
    // Pure visualization overlay: never consume map click/drag events.
    enabled: false
    // Model providing tower entries { latitude, longitude, name }
    // Removed invalid alias (previously 'property alias model: towerModel') which referenced no id.
    property var towerModel: null
    // Attenuation exponent (lower => slower decay).
    property real attenExp: 2.5
    // Base distance scale (meters). Larger => slower decay.
    property real baseDistance: 80
    // Optional multiplier to globally raise/lower strength.
    property real strengthMultiplier: 1.0
    property real radiusMeters: 12000
    // Max grid; effective grid adapts by zoom/tower count to improve performance.
    property int gridSize: 44
    property real maxComposite: 0           // updated after compute
    property real displayLowComposite: 0
    property real displayHighComposite: 0
    property bool contours: true
    property int contourLevels: 6
    property real opacityFactor: 0.36
    property real contrastLowPercentile: 0.02
    property real contrastHighPercentile: 0.965
    property real contrastGamma: 0.72

    // Map object injected by parent
    property var map: null

    visible: !!towerModel && towerModel.count > 0 && map

    function effectiveGridSize() {
        var gs = root.gridSize
        if (map) {
            if (map.zoomLevel < 13) {
                gs = Math.min(gs, 28)
            } else if (map.zoomLevel < 15) {
                gs = Math.min(gs, 34)
            } else if (map.zoomLevel < 17) {
                gs = Math.min(gs, 40)
            }
        }
        if (towerModel && towerModel.count > 250) {
            gs = Math.max(24, gs - 8)
        }
        return Math.max(20, gs)
    }

    function effectiveContourLevels() {
        var lv = root.contourLevels
        if (towerModel && towerModel.count > 250) {
            lv = Math.min(lv, 4)
        }
        return Math.max(2, lv)
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            if (!root.map || !towerModel || towerModel.count === 0) return
            var ctx = getContext('2d')
            ctx.clearRect(0,0,width,height)
            var w = width; var h = height
            if (w < 2 || h < 2) return

            // Precompute composite strength per-cell, then render as blocks.
            var gs = root.effectiveGridSize()
            var cellW = w/gs
            var cellH = h/gs
            var strengths = []
            var maxS = 0
            var minS = Number.POSITIVE_INFINITY

            // Estimate meters per pixel around map center.
            var cpx = w * 0.5
            var cpy = h * 0.5
            var centerCoord = root.map.toCoordinate(Qt.point(cpx, cpy))
            var rightCoord = root.map.toCoordinate(Qt.point(cpx + 100, cpy))
            if (!centerCoord.isValid || !rightCoord.isValid) return
            var metersPerPixel = haversineMeters(centerCoord.latitude, centerCoord.longitude, rightCoord.latitude, rightCoord.longitude) / 100.0
            if (!isFinite(metersPerPixel) || metersPerPixel <= 0.01) metersPerPixel = 1.0
            var radiusPixels = root.radiusMeters / metersPerPixel

            // Build visible tower cache in pixel space to avoid repeated geo conversion.
            var towers = []
            for (var ti=0; ti<towerModel.count; ti++) {
                var tw = towerModel.get(ti)
                if (tw.type === 'sensor') continue
                var p = root.map.fromCoordinate(QtPositioning.coordinate(tw.latitude, tw.longitude))
                if (!isFinite(p.x) || !isFinite(p.y)) continue
                if (p.x < -radiusPixels || p.x > w + radiusPixels || p.y < -radiusPixels || p.y > h + radiusPixels) {
                    continue
                }
                towers.push({ x: p.x, y: p.y })
            }

            if (towers.length === 0) return

            for (var gy=0; gy<gs; gy++) {
                for (var gx=0; gx<gs; gx++) {
                    var px = (gx+0.5)*cellW
                    var py = (gy+0.5)*cellH
                    var composite = 0
                    for (var j=0; j<towers.length; j++) {
                        var dx = px - towers[j].x
                        var dy = py - towers[j].y
                        var d = Math.sqrt(dx*dx + dy*dy) * metersPerPixel
                        if (d < radiusMeters) {
                            var normD = d / baseDistance
                            var eff = strengthMultiplier / Math.pow(normD + 1.0, attenExp)
                            composite += eff
                        }
                    }
                    if (composite > maxS) maxS = composite
                    if (composite < minS) minS = composite
                    strengths.push(composite)
                }
            }
            root.maxComposite = maxS
            var displayStats = buildDisplayStrengths(strengths, minS, maxS)
            var displayStrengths = displayStats.values
            root.displayLowComposite = displayStats.lowRef
            root.displayHighComposite = displayStats.highRef
            // Draw cells
            var idx=0
            for (var gy=0; gy<gs; gy++) {
                for (var gx=0; gx<gs; gx++) {
                    var s = displayStrengths[idx++]
                    var col = colorRamp(s)
                    var x0 = Math.floor(gx*cellW)
                    var y0 = Math.floor(gy*cellH)
                    var x1 = Math.floor((gx+1)*cellW)
                    var y1 = Math.floor((gy+1)*cellH)
                    ctx.fillStyle = col
                    ctx.fillRect(x0,y0,x1-x0,y1-y0)
                }
            }
            if (root.contours) drawContours(ctx, displayStrengths, gs, gs)
        }

        function clamp01(v) {
            return Math.max(0, Math.min(1, v))
        }

        function percentile(sortedValues, p) {
            if (!sortedValues || sortedValues.length === 0) {
                return 0
            }

            var pp = clamp01(p)
            var pos = (sortedValues.length - 1) * pp
            var low = Math.floor(pos)
            var high = Math.ceil(pos)
            if (low === high) {
                return sortedValues[low]
            }

            var mix = pos - low
            return sortedValues[low] * (1 - mix) + sortedValues[high] * mix
        }

        function buildDisplayStrengths(strengths, minS, maxS) {
            var out = []
            if (!strengths || strengths.length === 0) {
                return { values: out, lowRef: 0, highRef: 0 }
            }

            if (!isFinite(minS)) minS = 0
            if (!isFinite(maxS) || maxS <= minS + 1e-9) {
                for (var flatIndex = 0; flatIndex < strengths.length; flatIndex++) {
                    out.push(0.5)
                }
                return { values: out, lowRef: minS, highRef: maxS }
            }

            var sorted = strengths.slice(0)
            sorted.sort(function(a, b) { return a - b })

            var lowRef = percentile(sorted, root.contrastLowPercentile)
            var highRef = percentile(sorted, root.contrastHighPercentile)

            if (!isFinite(lowRef)) lowRef = minS
            if (!isFinite(highRef) || highRef <= lowRef + 1e-9) {
                lowRef = minS
                highRef = maxS
            }

            var logLow = Math.log(1 + Math.max(0, lowRef))
            var logHigh = Math.log(1 + Math.max(lowRef + 1e-6, highRef))
            var denom = Math.max(1e-6, logHigh - logLow)

            for (var i = 0; i < strengths.length; i++) {
                var logValue = Math.log(1 + Math.max(0, strengths[i]))
                var normalized = clamp01((logValue - logLow) / denom)
                out.push(Math.pow(normalized, root.contrastGamma))
            }

            return { values: out, lowRef: lowRef, highRef: highRef }
        }

        function colorRamp(t) { // t in [0,1]
            var r,g,b
            var v = clamp01(t)

            if (v < 0.18) {
                var f = v / 0.18
                r = Math.round(168 + (228 - 168) * f)
                g = Math.round(34 + (102 - 34) * f)
                b = Math.round(18 * (1 - f))
            } else if (v < 0.38) {
                var f = (v - 0.18) / 0.20
                r = Math.round(228 + (255 - 228) * f)
                g = Math.round(102 + (188 - 102) * f)
                b = 0
            } else if (v < 0.60) {
                var f = (v - 0.38) / 0.22
                r = Math.round(255 - 72 * f)
                g = Math.round(188 + 44 * f)
                b = Math.round(8 + 18 * f)
            } else if (v < 0.82) {
                var f = (v - 0.60) / 0.22
                r = Math.round(183 - 96 * f)
                g = Math.round(232 + 16 * f)
                b = Math.round(26 + 26 * f)
            } else {
                var f = (v - 0.82) / 0.18
                r = Math.round(87 - 45 * f)
                g = Math.round(248 + 7 * f)
                b = Math.round(52 + 42 * f)
            }

            return 'rgba('+r+','+g+','+b+','+root.opacityFactor+')'
        }

        function drawContours(ctx, strengths, wCells, hCells) {
            var levels = root.effectiveContourLevels()
            if (levels < 2) return
            ctx.lineWidth = 1
            for (var l=1; l<levels; l++) {
                var threshold = l/(levels)
                ctx.strokeStyle = 'rgba(255,255,255,' + (0.08 + 0.18*(l/levels)) + ')'
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
                    var n0 = clamp01(strengths[i])
                    var n1 = clamp01(strengths[i+1])
                    var n2 = clamp01(strengths[i+wCells])
                    var n3 = clamp01(strengths[i+wCells+1])
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

    function scheduleRepaint() {
        if (!root.visible) return
        repaintDebounce.restart()
    }

    // Debounce repaint requests to avoid flooding while map is panning.
    Timer {
        id: repaintDebounce
        interval: 160
        repeat: false
        onTriggered: canvas.requestPaint()
    }

    Connections { target: map; function onCenterChanged() { scheduleRepaint() } }
    Connections { target: map; function onZoomLevelChanged() { scheduleRepaint() } }
    Connections { target: towerModel; function onCountChanged() { scheduleRepaint() } }
    onTowerModelChanged: scheduleRepaint()
    onVisibleChanged: { if (visible) scheduleRepaint() }
}
