/****************************************************************************
 *
 * Path Comparison Panel - Display metrics comparison between original and optimized paths
 *
 ****************************************************************************/

import QtQuick          2.3
import QtQuick.Controls 1.2
import QtQuick.Layouts  1.2
import QtCharts         2.3

import QGroundControl                   1.0
import QGroundControl.ScreenTools       1.0
import QGroundControl.Controls          1.0
import QGroundControl.Palette          1.0

import "./TowerOptimize.js" as TowerOpt

Rectangle {
    id:                 comparisonPanel
    width:              400
    height:             parent.height
    color:              qgcPal.window
    border.color:       qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.1) : Qt.rgba(1,1,1,0.1)
    border.width:       2  // 增加边框宽度，更容易看到
    visible:            true  // 确保可见
    
    property var missionController: null
    property var comparisonData: ({ original: null, optimized: null })
    
    QGCPalette { id: qgcPal }
    
    Component.onCompleted: {
        console.log('[TowerOptimize] PathComparisonPanel created')
        console.log('[TowerOptimize]   - missionController:', !!missionController)
        console.log('[TowerOptimize]   - Panel width:', width, 'height:', height)
        console.log('[TowerOptimize]   - Panel visible:', visible)
        console.log('[TowerOptimize]   - Panel color:', color)
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
            comparisonData = TowerOpt.getPathComparisonMetrics(missionController)
            console.log('[TowerOptimize] Comparison data received:')
            console.log('[TowerOptimize]   - original:', !!comparisonData.original)
            console.log('[TowerOptimize]   - optimized:', !!comparisonData.optimized)
            if (comparisonData.original) {
                console.log('[TowerOptimize]   - original obstacleMinDistance:', comparisonData.original.obstacleMinDistance)
                console.log('[TowerOptimize]   - original signalAvg:', comparisonData.original.signalAvg)
            }
            if (comparisonData.optimized) {
                console.log('[TowerOptimize]   - optimized obstacleMinDistance:', comparisonData.optimized.obstacleMinDistance)
                console.log('[TowerOptimize]   - optimized signalAvg:', comparisonData.optimized.signalAvg)
            }
            updateChart()
            console.log('[TowerOptimize] Chart updated')
        } else {
            console.warn('[TowerOptimize] No missionController available, cannot refresh')
        }
        console.log('[TowerOptimize] ===== PathComparisonPanel Refresh completed =====')
    }
    
    Column {
        id:                 mainColumn
        anchors.fill:       parent
        anchors.margins:    ScreenTools.defaultFontPixelWidth
        spacing:           ScreenTools.defaultFontPixelHeight * 0.5
        
        // Header
        QGCLabel {
            id:                 header
            text:               "Path Comparison"
            font.pointSize:     ScreenTools.defaultFontPointSize * 1.2
            font.bold:          true
        }
        
        // Scrollable content
        ScrollView {
            width:          parent.width
            height:         parent.height - header.height - refreshButton.height - parent.spacing * 3
            
            Column {
                width:      parent.width
                spacing:    ScreenTools.defaultFontPixelHeight * 0.5
                
                // Metric comparison items
                Repeater {
                    model: [
                        { name: "Min Obstacle Distance", key: "obstacleMinDistance", unit: "m", format: "f1" },
                        { name: "Avg Obstacle Distance", key: "obstacleAvgDistance", unit: "m", format: "f1" },
                        { name: "Avg Signal Strength", key: "signalAvg", unit: "", format: "f2" },
                        { name: "Min Signal Strength", key: "signalMin", unit: "", format: "f2" },
                        { name: "Max Signal Strength", key: "signalMax", unit: "", format: "f2" },
                        { name: "Path Length", key: "pathLength", unit: "m", format: "f0" },
                        { name: "Path Smoothness", key: "pathSmoothness", unit: "°", format: "f1" },
                        { name: "Overall Score", key: "overscore", unit: "", format: "f2" }
                    ]
                    
                    delegate: Loader {
                        width:          parent.width
                        sourceComponent: metricItemComponent
                        property string metricName:     modelData.name
                        property string metricKey:      modelData.key
                        property string unit:           modelData.unit
                        property string format:         modelData.format
                        property real   originalValue:  comparisonPanel.comparisonData.original ? comparisonPanel.comparisonData.original[modelData.key] : 0
                        property real   optimizedValue: comparisonPanel.comparisonData.optimized ? comparisonPanel.comparisonData.optimized[modelData.key] : 0
                    }
                }
                
                // Signal distribution chart
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
                        
                        ChartView {
                            id:             signalChart
                            width:          parent.width
                            height:         parent.height - signalLabel.height - parent.spacing * 2
                            antialiasing:   true
                            backgroundColor: "transparent"
                            legend.visible: false
                            
                            ValueAxis {
                                id:         axisX
                                min:        0
                                max:        100
                            }
                            
                            ValueAxis {
                                id:         axisY
                                min:        0
                                max:        100
                            }
                            
                            LineSeries {
                                id:         originalSignalSeries
                                name:       "Original"
                                axisX:      axisX
                                axisY:      axisY
                                color:      "#959b59"
                                width:      2
                                visible:     comparisonPanel.comparisonData.original && comparisonPanel.comparisonData.original.signalDistribution
                            }
                            
                            LineSeries {
                                id:         optimizedSignalSeries
                                name:       "Optimized"
                                axisX:      axisX
                                axisY:      axisY
                                color:      QGroundControl.globalPalette.mapMissionTrajectory
                                width:      2
                                visible:     comparisonPanel.comparisonData.optimized && comparisonPanel.comparisonData.optimized.signalDistribution
                            }
                        }
                    }
                }
            }
        }
        
        // Refresh button
        QGCButton {
            id:                 refreshButton
            text:               "Refresh"
            anchors.horizontalCenter: parent.horizontalCenter
            onClicked: {
                comparisonPanel.refresh()
            }
        }
    }
    
    Component.onCompleted: {
        refresh()
    }
    
    function updateChart() {
        if (!comparisonData) return
        
        // Clear existing data
        originalSignalSeries.clear()
        optimizedSignalSeries.clear()
        
        // Update original signal distribution
        if (comparisonData.original && comparisonData.original.signalDistribution) {
            var origDist = comparisonData.original.signalDistribution
            var maxY = 0
            for (var i = 0; i < origDist.length; i++) {
                var x = (i / Math.max(origDist.length - 1, 1)) * 100
                var y = origDist[i]
                originalSignalSeries.append(x, y)
                if (y > maxY) maxY = y
            }
        }
        
        // Update optimized signal distribution
        if (comparisonData.optimized && comparisonData.optimized.signalDistribution) {
            var optDist = comparisonData.optimized.signalDistribution
            for (var j = 0; j < optDist.length; j++) {
                var x2 = (j / Math.max(optDist.length - 1, 1)) * 100
                var y2 = optDist[j]
                optimizedSignalSeries.append(x2, y2)
                if (y2 > maxY) maxY = y2
            }
        }
        
        // Update Y axis
        axisY.max = maxY * 1.1
    }
}

// Metric comparison item component
Component {
    id:                 metricItemComponent
    
    Item {
        property string metricName:     ""
        property string metricKey:      ""
        property string unit:           ""
        property string format:         "f2"
        property real   originalValue:  0
        property real   optimizedValue: 0
        
        height:         ScreenTools.defaultFontPixelHeight * 3
        width:          parent.width
        
        Rectangle {
            anchors.fill:       parent
            color:              qgcPal.windowShade
            border.color:        qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.1) : Qt.rgba(1,1,1,0.1)
            border.width:        1
            radius:              4
        }
        
        Column {
            anchors.fill:       parent
            anchors.margins:    ScreenTools.defaultFontPixelWidth * 0.5
            spacing:            ScreenTools.defaultFontPixelHeight * 0.25
        
            QGCLabel {
                text:           metricName
                font.pointSize: ScreenTools.defaultFontPointSize * 0.9
            }
            
            Row {
                width:          parent.width
                spacing:        ScreenTools.defaultFontPixelWidth
                
                // Original value bar
                Rectangle {
                    width:          (parent.width - parent.spacing) * 0.5
                    height:         ScreenTools.defaultFontPixelHeight * 1.5
                    color:          "#959b59"
                    radius:         2
                    
                    QGCLabel {
                        anchors.centerIn:   parent
                        text:               originalValue.toFixed(format === "f0" ? 0 : (format === "f1" ? 1 : 2)) + (unit ? " " + unit : "")
                        color:              "white"
                        font.pointSize:     ScreenTools.defaultFontPointSize * 0.8
                    }
                }
                
                // Optimized value bar
                Rectangle {
                    width:          (parent.width - parent.spacing) * 0.5
                    height:         ScreenTools.defaultFontPixelHeight * 1.5
                    color:          QGroundControl.globalPalette.mapMissionTrajectory
                    radius:         2
                    
                    QGCLabel {
                        anchors.centerIn:   parent
                        text:               optimizedValue.toFixed(format === "f0" ? 0 : (format === "f1" ? 1 : 2)) + (unit ? " " + unit : "")
                        color:              "white"
                        font.pointSize:     ScreenTools.defaultFontPointSize * 0.8
                    }
                }
            }
        }
    }
}
