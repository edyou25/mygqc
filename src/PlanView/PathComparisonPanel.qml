/****************************************************************************
 *
 * Path Comparison Panel - Display metrics comparison between original and optimized paths
 *
 ****************************************************************************/

import QtQuick          2.3
import QtQuick.Controls 1.2
import QtQuick.Layouts  1.2
// import QtCharts         2.3  // Temporarily disabled

import QGroundControl                   1.0
import QGroundControl.ScreenTools       1.0
import QGroundControl.Controls          1.0
import QGroundControl.Palette           1.0

import "./TowerOptimize.js" as TowerOpt

Rectangle {
    id:                 comparisonPanel
    width:              400
    height:             parent ? Math.max(0, parent.height) : 400
    color:              qgcPal.window
    border.color:       qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.1) : Qt.rgba(1,1,1,0.1)
    border.width:       2
    visible:            true

    property var missionController: null
    property var comparisonData: ({ original: null, optimized: null, length: null, smooth: null })
    property var originalPathWaypoints: []
    property var signalPathWaypoints: []
    property var lengthPathWaypoints: []
    property var smoothPathWaypoints: []

    // Layout tuning
    property real _barWidth: Math.max(18, ScreenTools.defaultFontPixelWidth * 2.5)
    property real _barMaxHeight: Math.max(72, ScreenTools.defaultFontPixelHeight * 5.5)

    onComparisonDataChanged: {
        console.log('[TowerOptimize] comparisonData changed, original:', !!comparisonData.original, 'optimized:', !!comparisonData.optimized, 'length:', !!comparisonData.length, 'smooth:', !!comparisonData.smooth)
        if (contentColumn) {
            console.log('[TowerOptimize] Triggering Repeater refresh')
        }
    }

    QGCPalette { id: qgcPal }

    Component.onCompleted: {
        console.log('[TowerOptimize] ===== PathComparisonPanel Component.onCompleted =====')
        console.log('[TowerOptimize] PathComparisonPanel Rectangle created')
        console.log('[TowerOptimize]   - width:', width, 'height:', height)
        console.log('[TowerOptimize]   - parent:', !!parent, 'parent.height:', parent ? parent.height : 'no parent')
        console.log('[TowerOptimize]   - missionController:', !!missionController)
        console.log('[TowerOptimize]   - Panel visible:', visible)
        console.log('[TowerOptimize]   - Panel color:', color)
        console.log('[TowerOptimize]   - Panel x:', x, 'y:', y)
        console.log('[TowerOptimize]   - comparisonData:', !!comparisonData)
        console.log('[TowerOptimize]   - qgcPal:', !!qgcPal)
        console.log('[TowerOptimize]   - originalPathWaypoints length:', originalPathWaypoints ? originalPathWaypoints.length : 0)
        console.log('[TowerOptimize] ===== Component.onCompleted end =====')

        Qt.callLater(function() { refresh() })
    }

    function refresh() {
        console.log('[TowerOptimize] ===== PathComparisonPanel Refresh called =====')
        console.log('[TowerOptimize] missionController:', !!missionController)
        console.log('[TowerOptimize] Panel visible:', visible)
        console.log('[TowerOptimize] Panel width:', width, 'height:', height)
        console.log('[TowerOptimize] Panel x:', x, 'y:', y)
        console.log('[TowerOptimize] Panel parent:', !!parent)

        if (missionController) {
            console.log('[TowerOptimize] Getting path comparison metrics...')
            console.log('[TowerOptimize] originalPathWaypoints from property:', originalPathWaypoints.length)
            console.log('[TowerOptimize] signalPathWaypoints from property:', signalPathWaypoints.length)
            console.log('[TowerOptimize] lengthPathWaypoints from property:', lengthPathWaypoints.length)
            console.log('[TowerOptimize] smoothPathWaypoints from property:', smoothPathWaypoints.length)

            if (originalPathWaypoints && originalPathWaypoints.length > 0 &&
                (signalPathWaypoints && signalPathWaypoints.length > 0)) {
                console.log('[TowerOptimize] Using provided multi-path waypoints')
                comparisonData = TowerOpt.getMultiPathComparisonMetrics(
                    originalPathWaypoints,
                    signalPathWaypoints,
                    lengthPathWaypoints,
                    smoothPathWaypoints
                )
            } else if (originalPathWaypoints && originalPathWaypoints.length > 0) {
                console.log('[TowerOptimize] Using originalPathWaypoints from QML property')
                comparisonData = TowerOpt.getPathComparisonMetricsWithOriginal(missionController, originalPathWaypoints)
            } else {
                console.log('[TowerOptimize] Using originalPathWaypoints from module variable')
                comparisonData = TowerOpt.getPathComparisonMetrics(missionController)
            }

            console.log('[TowerOptimize] Comparison data received:')
            console.log('[TowerOptimize]   - original:', !!comparisonData.original)
            console.log('[TowerOptimize]   - optimized:', !!comparisonData.optimized)
            if (comparisonData.length === undefined) comparisonData.length = null
            if (comparisonData.smooth === undefined) comparisonData.smooth = null

            if (comparisonData.original) {
                console.log('[TowerOptimize]   - original obstacleMinDistance:', comparisonData.original.obstacleMinDistance)
                console.log('[TowerOptimize]   - original obstacleAvgDistance:', comparisonData.original.obstacleAvgDistance)
                console.log('[TowerOptimize]   - original signalAvg:', comparisonData.original.signalAvg)
                console.log('[TowerOptimize]   - original signalMin:', comparisonData.original.signalMin)
                console.log('[TowerOptimize]   - original signalMax:', comparisonData.original.signalMax)
                console.log('[TowerOptimize]   - original energyIndex (pathLength):', comparisonData.original.pathLength)
                console.log('[TowerOptimize]   - original pathSmoothness:', comparisonData.original.pathSmoothness)
                console.log('[TowerOptimize]   - original overscore:', comparisonData.original.overscore)
            } else {
                console.warn('[TowerOptimize]   - original data is null!')
            }

            if (comparisonData.optimized) {
                console.log('[TowerOptimize]   - optimized obstacleMinDistance:', comparisonData.optimized.obstacleMinDistance)
                console.log('[TowerOptimize]   - optimized obstacleAvgDistance:', comparisonData.optimized.obstacleAvgDistance)
                console.log('[TowerOptimize]   - optimized signalAvg:', comparisonData.optimized.signalAvg)
                console.log('[TowerOptimize]   - optimized signalMin:', comparisonData.optimized.signalMin)
                console.log('[TowerOptimize]   - optimized signalMax:', comparisonData.optimized.signalMax)
                console.log('[TowerOptimize]   - optimized energyIndex (pathLength):', comparisonData.optimized.pathLength)
                console.log('[TowerOptimize]   - optimized pathSmoothness:', comparisonData.optimized.pathSmoothness)
                console.log('[TowerOptimize]   - optimized overscore:', comparisonData.optimized.overscore)
            } else {
                console.warn('[TowerOptimize]   - optimized data is null!')
            }

            if (comparisonData.length) {
                console.log('[TowerOptimize]   - length obstacleMinDistance:', comparisonData.length.obstacleMinDistance)
                console.log('[TowerOptimize]   - length obstacleAvgDistance:', comparisonData.length.obstacleAvgDistance)
                console.log('[TowerOptimize]   - length signalAvg:', comparisonData.length.signalAvg)
                console.log('[TowerOptimize]   - length signalMin:', comparisonData.length.signalMin)
                console.log('[TowerOptimize]   - length signalMax:', comparisonData.length.signalMax)
                console.log('[TowerOptimize]   - length energyIndex (pathLength):', comparisonData.length.pathLength)
                console.log('[TowerOptimize]   - length pathSmoothness:', comparisonData.length.pathSmoothness)
                console.log('[TowerOptimize]   - length overscore:', comparisonData.length.overscore)
            } else {
                console.warn('[TowerOptimize]   - length data is null!')
            }

            if (comparisonData.smooth) {
                console.log('[TowerOptimize]   - smooth obstacleMinDistance:', comparisonData.smooth.obstacleMinDistance)
                console.log('[TowerOptimize]   - smooth obstacleAvgDistance:', comparisonData.smooth.obstacleAvgDistance)
                console.log('[TowerOptimize]   - smooth signalAvg:', comparisonData.smooth.signalAvg)
                console.log('[TowerOptimize]   - smooth signalMin:', comparisonData.smooth.signalMin)
                console.log('[TowerOptimize]   - smooth signalMax:', comparisonData.smooth.signalMax)
                console.log('[TowerOptimize]   - smooth energyIndex (pathLength):', comparisonData.smooth.pathLength)
                console.log('[TowerOptimize]   - smooth pathSmoothness:', comparisonData.smooth.pathSmoothness)
                console.log('[TowerOptimize]   - smooth overscore:', comparisonData.smooth.overscore)
            } else {
                console.warn('[TowerOptimize]   - smooth data is null!')
            }

            updateChart()
            console.log('[TowerOptimize] Chart updated')

            // Force UI update
            var tempData = comparisonData
            comparisonData = ({ original: null, optimized: null, length: null, smooth: null })
            Qt.callLater(function() {
                comparisonData = tempData
                console.log('[TowerOptimize] comparisonData reassigned to trigger UI update')
                console.log('[TowerOptimize]   - original after reassign:', !!comparisonData.original)
                console.log('[TowerOptimize]   - optimized after reassign:', !!comparisonData.optimized)
                console.log('[TowerOptimize]   - length after reassign:', !!comparisonData.length)
                console.log('[TowerOptimize]   - smooth after reassign:', !!comparisonData.smooth)
            })
        } else {
            console.warn('[TowerOptimize] No missionController available, cannot refresh')
        }

        console.log('[TowerOptimize] ===== PathComparisonPanel Refresh completed =====')
    }

    ColumnLayout {
        id:                 mainColumn
        anchors.fill:       parent
        anchors.margins:    ScreenTools.defaultFontPixelWidth
        spacing:            ScreenTools.defaultFontPixelHeight * 0.5

        QGCLabel {
            id:                 header
            text:               "Path Comparison"
            font.pointSize:     ScreenTools.defaultFontPointSize * 1.2
            font.bold:          true
            Layout.fillWidth:   true
        }

        ScrollView {
            id:                 scrollView
            Layout.fillWidth:   true
            Layout.fillHeight:  true

            Component.onCompleted: {
                console.log('[TowerOptimize] ScrollView created')
                console.log('[TowerOptimize]   - width:', width, 'height:', height)
                console.log('[TowerOptimize]   - Layout.fillWidth:', Layout.fillWidth)
                console.log('[TowerOptimize]   - Layout.fillHeight:', Layout.fillHeight)
            }

            Column {
                id:         contentColumn
                width:      (scrollView.viewport ? scrollView.viewport.width : scrollView.width) || 400
                spacing:    ScreenTools.defaultFontPixelHeight * 0.5

                Component.onCompleted: {
                    console.log('[TowerOptimize] PathComparisonPanel contentColumn created')
                    console.log('[TowerOptimize]   - width:', width)
                    console.log('[TowerOptimize]   - scrollView.width:', scrollView.width)
                    console.log('[TowerOptimize]   - scrollView.viewport:', !!scrollView.viewport)
                }

                // Legend row for the bar columns (vertical bars)
                RowLayout {
                    width: parent.width
                    spacing: ScreenTools.defaultFontPixelWidth
                    height: ScreenTools.defaultFontPixelHeight * 1.2

                    Rectangle {
                        width: ScreenTools.defaultFontPixelWidth * 1.2
                        height: width
                        radius: 2
                        color: "#4569df"
                    }

                    QGCLabel {
                        text: "Original"
                        font.pointSize: ScreenTools.defaultFontPointSize * 0.8
                        opacity: 0.8
                    }

                    Rectangle {
                        width: ScreenTools.defaultFontPixelWidth * 1.2
                        height: width
                        radius: 2
                        color: QGroundControl.globalPalette.mapMissionTrajectory
                    }

                    QGCLabel {
                        text: "Signal"
                        font.pointSize: ScreenTools.defaultFontPointSize * 0.8
                        opacity: 0.8
                    }

                    Rectangle {
                        width: ScreenTools.defaultFontPixelWidth * 1.2
                        height: width
                        radius: 2
                        color: "#f2a900"
                        visible: comparisonPanel.comparisonData.length !== null && comparisonPanel.comparisonData.length !== undefined
                    }

                    QGCLabel {
                        text: "Shorter"
                        font.pointSize: ScreenTools.defaultFontPointSize * 0.8
                        opacity: 0.8
                        visible: comparisonPanel.comparisonData.length !== null && comparisonPanel.comparisonData.length !== undefined
                    }

                    Rectangle {
                        width: ScreenTools.defaultFontPixelWidth * 1.2
                        height: width
                        radius: 2
                        color: "#2fb66c"
                        visible: comparisonPanel.comparisonData.smooth !== null && comparisonPanel.comparisonData.smooth !== undefined
                    }

                    QGCLabel {
                        text: "Smoother"
                        font.pointSize: ScreenTools.defaultFontPointSize * 0.8
                        opacity: 0.8
                        visible: comparisonPanel.comparisonData.smooth !== null && comparisonPanel.comparisonData.smooth !== undefined
                    }

                    Item { Layout.fillWidth: true }
                }

                Flow {
                    id: metricFlow
                    width: parent.width
                    spacing: ScreenTools.defaultFontPixelWidth

                    Repeater {
                        model: [
                            { name: "Min Obstacle Distance", key: "obstacleMinDistance", unit: "m", format: "f1", higherBetter: true  },
                            { name: "Avg Obstacle Distance", key: "obstacleAvgDistance", unit: "m", format: "f1", higherBetter: true  },
                            { name: "Avg Signal Strength",   key: "signalAvg",          unit: "",  format: "f2", higherBetter: true  },
                            { name: "Min Signal Strength",   key: "signalMin",          unit: "",  format: "f2", higherBetter: true  },
                            { name: "Max Signal Strength",   key: "signalMax",          unit: "",  format: "f2", higherBetter: true  },
                            { name: "Energy Index",          key: "pathLength",         unit: "",  format: "f2", higherBetter: false },
                            { name: "Path Smoothness",       key: "pathSmoothness",     unit: "°", format: "f1", higherBetter: false },
                            { name: "Overall Score",         key: "overscore",          unit: "",  format: "f2", higherBetter: true  }
                        ]

                        delegate: Loader {
                            id:                 metricLoader
                            width:              item ? item.width : ScreenTools.defaultFontPixelWidth * 12
                            height:             item ? item.height : ScreenTools.defaultFontPixelHeight * 8
                            sourceComponent:    metricItemComponent

                            property string metricName:     modelData.name
                            property string metricKey:      modelData.key
                            property string unit:           modelData.unit
                            property string format:         modelData.format
                            property bool   higherBetter:   modelData.higherBetter

                            property real   originalValue:  comparisonPanel.comparisonData.original ? (comparisonPanel.comparisonData.original[modelData.key] || 0) : 0
                            property real   optimizedValue: comparisonPanel.comparisonData.optimized ? (comparisonPanel.comparisonData.optimized[modelData.key] || 0) : 0
                            property real   lengthValue: comparisonPanel.comparisonData.length ? (comparisonPanel.comparisonData.length[modelData.key] || 0) : 0
                            property real   smoothValue: comparisonPanel.comparisonData.smooth ? (comparisonPanel.comparisonData.smooth[modelData.key] || 0) : 0
                            property bool   showLength: comparisonPanel.comparisonData.length !== null && comparisonPanel.comparisonData.length !== undefined
                            property bool   showSmooth: comparisonPanel.comparisonData.smooth !== null && comparisonPanel.comparisonData.smooth !== undefined

                            Connections {
                                target: comparisonPanel
                                function onComparisonDataChanged() {
                                    if (metricLoader.item) {
                                        var newOriginal = comparisonPanel.comparisonData.original ? (comparisonPanel.comparisonData.original[modelData.key] || 0) : 0
                                    var newOptimized = comparisonPanel.comparisonData.optimized ? (comparisonPanel.comparisonData.optimized[modelData.key] || 0) : 0
                                    var newLength = comparisonPanel.comparisonData.length ? (comparisonPanel.comparisonData.length[modelData.key] || 0) : 0
                                    var newSmooth = comparisonPanel.comparisonData.smooth ? (comparisonPanel.comparisonData.smooth[modelData.key] || 0) : 0
                                    if (index === 0) {
                                        console.log('[TowerOptimize] ComparisonData changed for', modelData.key, 'original:', newOriginal, 'optimized:', newOptimized, 'length:', newLength, 'smooth:', newSmooth)
                                    }
                                        metricLoader.item.originalValue = newOriginal
                                        metricLoader.item.optimizedValue = newOptimized
                                        metricLoader.item.lengthValue = newLength
                                        metricLoader.item.smoothValue = newSmooth
                                        metricLoader.item.showLength = comparisonPanel.comparisonData.length !== null && comparisonPanel.comparisonData.length !== undefined
                                        metricLoader.item.showSmooth = comparisonPanel.comparisonData.smooth !== null && comparisonPanel.comparisonData.smooth !== undefined
                                        metricLoader.item.higherBetter = modelData.higherBetter
                                    }
                                }
                            }

                            Component.onCompleted: {
                                if (index === 0) {
                                    console.log('[TowerOptimize] MetricItem Loader created for', modelData.name)
                                    console.log('[TowerOptimize]   - originalValue:', originalValue)
                                console.log('[TowerOptimize]   - optimizedValue:', optimizedValue)
                                console.log('[TowerOptimize]   - lengthValue:', lengthValue)
                                console.log('[TowerOptimize]   - smoothValue:', smoothValue)
                            }
                        }

                            onItemChanged: {
                                if (item) {
                                    item.metricName = metricName
                                    item.metricKey = metricKey
                                    item.unit = unit
                                    item.format = format
                            item.higherBetter = higherBetter
                            item.originalValue = originalValue
                            item.optimizedValue = optimizedValue
                            item.lengthValue = lengthValue
                            item.smoothValue = smoothValue
                            item.showLength = showLength
                            item.showSmooth = showSmooth
                            if (index === 0) {
                                console.log('[TowerOptimize] MetricItem Loader item set, originalValue:', originalValue, 'optimizedValue:', optimizedValue, 'lengthValue:', lengthValue, 'smoothValue:', smoothValue)
                            }
                        }
                    }
                        }
                    }
                }

                Rectangle {
                    width:      parent.width
                    height:     150
                    color:      qgcPal.windowShade
                    border.color: qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.1) : Qt.rgba(1,1,1,0.1)
                    border.width: 1
                    radius:     4

                    Column {
                        anchors.fill:       parent
                        anchors.margins:   ScreenTools.defaultFontPixelWidth
                        spacing:           ScreenTools.defaultFontPixelHeight * 0.25

                        QGCLabel {
                            id:             signalLabel
                            text:           "Signal Strength Distribution"
                            font.pointSize: ScreenTools.defaultFontPointSize * 0.9
                        }

                        Rectangle {
                            width:          parent.width
                            height:         parent.height - signalLabel.height - parent.spacing * 2
                            color:          qgcPal.window
                            border.color:   qgcPal.text
                            border.width:   1

                            Column {
                                anchors.fill:       parent
                                anchors.margins:   ScreenTools.defaultFontPixelWidth
                                spacing:           ScreenTools.defaultFontPixelHeight * 0.25

                                QGCLabel {
                                    text:           "Chart placeholder"
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.8
                                }

                                QGCLabel {
                                    text:           comparisonPanel.comparisonData.original ?
                                                   ("Original points: " + (comparisonPanel.comparisonData.original.signalDistribution ? comparisonPanel.comparisonData.original.signalDistribution.length : 0)) :
                                                   "No original data"
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.7
                                }

                                QGCLabel {
                                    text:           comparisonPanel.comparisonData.optimized ?
                                                   ("Signal points: " + (comparisonPanel.comparisonData.optimized.signalDistribution ? comparisonPanel.comparisonData.optimized.signalDistribution.length : 0)) :
                                                   "No signal data"
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.7
                                }

                                QGCLabel {
                                    text:           comparisonPanel.comparisonData.length ?
                                                   ("Shorter points: " + (comparisonPanel.comparisonData.length.signalDistribution ? comparisonPanel.comparisonData.length.signalDistribution.length : 0)) :
                                                   "No shorter data"
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.7
                                }

                                QGCLabel {
                                    text:           comparisonPanel.comparisonData.smooth ?
                                                   ("Smoother points: " + (comparisonPanel.comparisonData.smooth.signalDistribution ? comparisonPanel.comparisonData.smooth.signalDistribution.length : 0)) :
                                                   "No smoother data"
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.7
                                }
                            }
                        }
                    }
                }
            }
        }

        QGCButton {
            id:                 refreshButton
            text:               "Refresh"
            Layout.alignment:   Qt.AlignHCenter

            Component.onCompleted: {
                console.log('[TowerOptimize] PathComparisonPanel refreshButton created')
            }

            onClicked: {
                console.log('[TowerOptimize] Refresh button clicked')
                comparisonPanel.refresh()
            }
        }
    }

    function updateChart() {
        console.log('[TowerOptimize] updateChart called (placeholder mode)')
    }

    // Metric comparison item component (vertical bars, columns: Original / Signal / Shorter / Smoother)
    // Visual rule:
    // - If optimized is better (delta > 0), exaggerate the separation between the two bars.
    // - If optimized is worse (delta < 0), compress the separation (make it less obvious).
    Component {
        id: metricItemComponent

        Item {
            property string metricName:     ""
            property string metricKey:      ""
            property string unit:           ""
            property string format:         "f2"
            property bool   higherBetter:   true
            property real   originalValue:  0
            property real   optimizedValue: 0
            property real   lengthValue:    0
            property real   smoothValue:    0
            property bool   showLength:     true
            property bool   showSmooth:     true

            width:  Math.max(ScreenTools.defaultFontPixelWidth * 14, comparisonPanel._barWidth * 4 + ScreenTools.defaultFontPixelWidth * 3)
            height: comparisonPanel._barMaxHeight + ScreenTools.defaultFontPixelHeight * 2.2

            function _fmt(v) {
                var decimals = (format === "f0") ? 0 : ((format === "f1") ? 1 : 2)
                return v.toFixed(decimals) + (unit ? " " + unit : "")
            }

            function _normalizedValue(value, minVal, maxVal) {
                var denom = maxVal - minVal
                if (denom <= 1e-9) return 0.5
                return (value - minVal) / denom
            }

            function _barFrac(value, values) {
                var minVal = values[0]
                var maxVal = values[0]
                for (var i = 1; i < values.length; i++) {
                    minVal = Math.min(minVal, values[i])
                    maxVal = Math.max(maxVal, values[i])
                }
                var adjusted = value
                if (!higherBetter) {
                    adjusted = maxVal + minVal - value
                }
                var norm = _normalizedValue(adjusted, minVal, maxVal)
                return Math.max(0.05, Math.min(0.95, norm))
            }

            function _activeValues() {
                var vals = [Number(originalValue || 0), Number(optimizedValue || 0)]
                if (showLength) vals.push(Number(lengthValue || 0))
                if (showSmooth) vals.push(Number(smoothValue || 0))
                return vals
            }

            property var _activeVals: _activeValues()
            property real _origFrac: _barFrac(Number(originalValue || 0), _activeVals)
            property real _optFrac:  _barFrac(Number(optimizedValue || 0), _activeVals)
            property real _lenFrac:  showLength ? _barFrac(Number(lengthValue || 0), _activeVals) : 0
            property real _smoFrac:  showSmooth ? _barFrac(Number(smoothValue || 0), _activeVals) : 0

            Rectangle {
                anchors.fill: parent
                color: qgcPal.windowShade
                border.color: qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.08) : Qt.rgba(1,1,1,0.08)
                border.width: 1
                radius: 4
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: ScreenTools.defaultFontPixelWidth * 0.5
                spacing: ScreenTools.defaultFontPixelHeight * 0.4

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: comparisonPanel._barMaxHeight

                    RowLayout {
                        anchors.fill: parent
                        spacing: ScreenTools.defaultFontPixelWidth * 0.6

                        // Original column (vertical bar)
                        Item {
                            Layout.fillHeight: true
                            Layout.preferredWidth: showLength ? comparisonPanel._barWidth : 0
                            visible: showLength

                            Rectangle {
                                id: originalBg
                                anchors.fill: parent
                                radius: 2
                                color: qgcPal.window
                                border.width: 1
                                border.color: qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.12) : Qt.rgba(1,1,1,0.12)

                                Rectangle {
                                    id: originalFill
                                    width: parent.width
                                    height: parent.height * _origFrac
                                    anchors.bottom: parent.bottom
                                    radius: 2
                                    color: "#4569df"
                                }

                                QGCLabel {
                                    anchors.centerIn: parent
                                    text: _fmt(originalValue)
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.75
                                    font.bold: true
                                    color: (originalFill.height > parent.height * 0.55) ? "white" : qgcPal.text
                                }
                            }
                        }

                        // Signal column (vertical bar)
                        Item {
                            Layout.fillHeight: true
                            Layout.preferredWidth: showSmooth ? comparisonPanel._barWidth : 0
                            visible: showSmooth

                            Rectangle {
                                id: optimizedBg
                                anchors.fill: parent
                                radius: 2
                                color: qgcPal.window
                                border.width: 1
                                border.color: qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.12) : Qt.rgba(1,1,1,0.12)

                                Rectangle {
                                    id: optimizedFill
                                    width: parent.width
                                    height: parent.height * _optFrac
                                    anchors.bottom: parent.bottom
                                    radius: 2
                                    color: QGroundControl.globalPalette.mapMissionTrajectory
                                }

                                QGCLabel {
                                    anchors.centerIn: parent
                                    text: _fmt(optimizedValue)
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.75
                                    font.bold: true
                                    color: (optimizedFill.height > parent.height * 0.55) ? "white" : qgcPal.text
                                }
                            }
                        }

                        // Shorter column (vertical bar)
                        Item {
                            Layout.fillHeight: true
                            Layout.preferredWidth: comparisonPanel._barWidth

                            Rectangle {
                                id: lengthBg
                                anchors.fill: parent
                                radius: 2
                                color: qgcPal.window
                                border.width: 1
                                border.color: qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.12) : Qt.rgba(1,1,1,0.12)

                                Rectangle {
                                    id: lengthFill
                                    width: parent.width
                                    height: parent.height * _lenFrac
                                    anchors.bottom: parent.bottom
                                    radius: 2
                                    color: "#f2a900"
                                }

                                QGCLabel {
                                    anchors.centerIn: parent
                                    text: _fmt(lengthValue)
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.75
                                    font.bold: true
                                    color: (lengthFill.height > parent.height * 0.55) ? "white" : qgcPal.text
                                }
                            }
                        }

                        // Smoother column (vertical bar)
                        Item {
                            Layout.fillHeight: true
                            Layout.preferredWidth: comparisonPanel._barWidth

                            Rectangle {
                                id: smoothBg
                                anchors.fill: parent
                                radius: 2
                                color: qgcPal.window
                                border.width: 1
                                border.color: qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.12) : Qt.rgba(1,1,1,0.12)

                                Rectangle {
                                    id: smoothFill
                                    width: parent.width
                                    height: parent.height * _smoFrac
                                    anchors.bottom: parent.bottom
                                    radius: 2
                                    color: "#2fb66c"
                                }

                                QGCLabel {
                                    anchors.centerIn: parent
                                    text: _fmt(smoothValue)
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.75
                                    font.bold: true
                                    color: (smoothFill.height > parent.height * 0.55) ? "white" : qgcPal.text
                                }
                            }
                        }
                    }
                }

                QGCLabel {
                    text: metricName
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    font.pointSize: ScreenTools.defaultFontPointSize * 0.75
                }
            }
        }
    }
}
