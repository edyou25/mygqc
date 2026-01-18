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
import QGroundControl.Palette          1.0

import "./TowerOptimize.js" as TowerOpt

Rectangle {
    id:                 comparisonPanel
    width:              400
    height:             parent ? Math.max(0, parent.height) : 400  // 确保高度不为负
    color:              qgcPal.window
    border.color:       qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.1) : Qt.rgba(1,1,1,0.1)
    border.width:       2  // 增加边框宽度，更容易看到
    visible:            true  // 确保可见
    
    property var missionController: null
    property var comparisonData: ({ original: null, optimized: null })
    property var originalPathWaypoints: []  // 从外部传入的原始路径点
    
    // 当 comparisonData 更新时，强制刷新 Repeater
    onComparisonDataChanged: {
        console.log('[TowerOptimize] comparisonData changed, original:', !!comparisonData.original, 'optimized:', !!comparisonData.optimized)
        // 强制 Repeater 重新评估
        if (contentColumn) {
            // 触发 Repeater 重新创建 items
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
        // 延迟刷新，确保所有组件都已初始化
        Qt.callLater(function() {
            refresh()
        })
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
            // 如果通过属性传入了原始路径点，使用它；否则使用模块变量
            if (originalPathWaypoints && originalPathWaypoints.length > 0) {
                console.log('[TowerOptimize] Using originalPathWaypoints from QML property')
                comparisonData = TowerOpt.getPathComparisonMetricsWithOriginal(missionController, originalPathWaypoints)
            } else {
                console.log('[TowerOptimize] Using originalPathWaypoints from module variable')
                comparisonData = TowerOpt.getPathComparisonMetrics(missionController)
            }
            console.log('[TowerOptimize] Comparison data received:')
            console.log('[TowerOptimize]   - original:', !!comparisonData.original)
            console.log('[TowerOptimize]   - optimized:', !!comparisonData.optimized)
            if (comparisonData.original) {
                console.log('[TowerOptimize]   - original obstacleMinDistance:', comparisonData.original.obstacleMinDistance)
                console.log('[TowerOptimize]   - original obstacleAvgDistance:', comparisonData.original.obstacleAvgDistance)
                console.log('[TowerOptimize]   - original signalAvg:', comparisonData.original.signalAvg)
                console.log('[TowerOptimize]   - original signalMin:', comparisonData.original.signalMin)
                console.log('[TowerOptimize]   - original signalMax:', comparisonData.original.signalMax)
                console.log('[TowerOptimize]   - original pathLength:', comparisonData.original.pathLength)
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
                console.log('[TowerOptimize]   - optimized pathLength:', comparisonData.optimized.pathLength)
                console.log('[TowerOptimize]   - optimized pathSmoothness:', comparisonData.optimized.pathSmoothness)
                console.log('[TowerOptimize]   - optimized overscore:', comparisonData.optimized.overscore)
            } else {
                console.warn('[TowerOptimize]   - optimized data is null!')
            }
            updateChart()
            console.log('[TowerOptimize] Chart updated')
            
            // 强制触发 comparisonData 变化信号，确保 UI 更新
            // 通过重新赋值来触发属性变化
            var tempData = comparisonData
            comparisonData = ({ original: null, optimized: null })
            Qt.callLater(function() {
                comparisonData = tempData
                console.log('[TowerOptimize] comparisonData reassigned to trigger UI update')
                console.log('[TowerOptimize]   - original after reassign:', !!comparisonData.original)
                console.log('[TowerOptimize]   - optimized after reassign:', !!comparisonData.optimized)
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
        spacing:           ScreenTools.defaultFontPixelHeight * 0.5
        
        // Header
        QGCLabel {
            id:                 header
            text:               "Path Comparison"
            font.pointSize:     ScreenTools.defaultFontPointSize * 1.2
            font.bold:          true
            Layout.fillWidth:   true
        }
        
        // Scrollable content
        ScrollView {
            id:             scrollView
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
                        id:                 metricLoader
                        width:              parent.width
                        sourceComponent:    metricItemComponent
                        property string metricName:     modelData.name
                        property string metricKey:      modelData.key
                        property string unit:           modelData.unit
                        property string format:         modelData.format
                        property real   originalValue:  comparisonPanel.comparisonData.original ? (comparisonPanel.comparisonData.original[modelData.key] || 0) : 0
                        property real   optimizedValue: comparisonPanel.comparisonData.optimized ? (comparisonPanel.comparisonData.optimized[modelData.key] || 0) : 0
                        
                        // 监听 comparisonData 的变化并更新 item
                        Connections {
                            target: comparisonPanel
                            function onComparisonDataChanged() {
                                if (metricLoader.item) {
                                    var newOriginal = comparisonPanel.comparisonData.original ? (comparisonPanel.comparisonData.original[modelData.key] || 0) : 0
                                    var newOptimized = comparisonPanel.comparisonData.optimized ? (comparisonPanel.comparisonData.optimized[modelData.key] || 0) : 0
                                    if (index === 0) {
                                        console.log('[TowerOptimize] ComparisonData changed for', modelData.key, 'original:', newOriginal, 'optimized:', newOptimized)
                                    }
                                    metricLoader.item.originalValue = newOriginal
                                    metricLoader.item.optimizedValue = newOptimized
                                }
                            }
                        }
                        
                        Component.onCompleted: {
                            if (index === 0) {
                                console.log('[TowerOptimize] MetricItem Loader created for', modelData.name)
                                console.log('[TowerOptimize]   - originalValue:', originalValue)
                                console.log('[TowerOptimize]   - optimizedValue:', optimizedValue)
                            }
                        }
                        
                        onItemChanged: {
                            if (item) {
                                item.metricName = metricName
                                item.metricKey = metricKey
                                item.unit = unit
                                item.format = format
                                item.originalValue = originalValue
                                item.optimizedValue = optimizedValue
                                if (index === 0) {
                                    console.log('[TowerOptimize] MetricItem Loader item set, originalValue:', originalValue, 'optimizedValue:', optimizedValue)
                                }
                            }
                        }
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
                        
                        // Signal distribution chart - temporarily simplified
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
                                                   ("Optimized points: " + (comparisonPanel.comparisonData.optimized.signalDistribution ? comparisonPanel.comparisonData.optimized.signalDistribution.length : 0)) : 
                                                   "No optimized data"
                                    font.pointSize: ScreenTools.defaultFontPointSize * 0.7
                                }
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
        // Chart update temporarily disabled - using placeholder
        console.log('[TowerOptimize] updateChart called (placeholder mode)')
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
            
            height:         ScreenTools.defaultFontPixelHeight * 4
            width:          parent.width
            
            // 当值变化时，强制更新显示
            onOriginalValueChanged: {
                console.log('[TowerOptimize] MetricItemComponent originalValue changed for', metricName, 'to', originalValue)
            }
            onOptimizedValueChanged: {
                console.log('[TowerOptimize] MetricItemComponent optimizedValue changed for', metricName, 'to', optimizedValue)
            }
            
            Component.onCompleted: {
                console.log('[TowerOptimize] MetricItemComponent created for', metricName)
                console.log('[TowerOptimize]   - originalValue:', originalValue)
                console.log('[TowerOptimize]   - optimizedValue:', optimizedValue)
            }
            
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
                        id:                 originalBar
                        width:              Math.max(50, (parent.width - parent.spacing) * 0.5)
                        height:             Math.max(20, ScreenTools.defaultFontPixelHeight * 1.5)
                        color:              "#959b59"
                        radius:             2
                        border.width:       1
                        border.color:       "#666666"
                        
                        Component.onCompleted: {
                            console.log('[TowerOptimize] Original bar created for', metricName, 'value:', originalValue, 'width:', width, 'height:', height)
                        }
                        
                        QGCLabel {
                            anchors.centerIn:   parent
                            text:               {
                                var val = originalValue
                                var decimals = format === "f0" ? 0 : (format === "f1" ? 1 : 2)
                                return val.toFixed(decimals) + (unit ? " " + unit : "")
                            }
                            color:              "white"
                            font.pointSize:     ScreenTools.defaultFontPointSize * 0.8
                            font.bold:          true
                        }
                    }
                    
                    // Optimized value bar
                    Rectangle {
                        id:                 optimizedBar
                        width:              Math.max(50, (parent.width - parent.spacing) * 0.5)
                        height:             Math.max(20, ScreenTools.defaultFontPixelHeight * 1.5)
                        color:              QGroundControl.globalPalette.mapMissionTrajectory
                        radius:             2
                        border.width:       1
                        border.color:       "#666666"
                        
                        Component.onCompleted: {
                            console.log('[TowerOptimize] Optimized bar created for', metricName, 'value:', optimizedValue, 'width:', width, 'height:', height)
                        }
                        
                        QGCLabel {
                            anchors.centerIn:   parent
                            text:               {
                                var val = optimizedValue
                                var decimals = format === "f0" ? 0 : (format === "f1" ? 1 : 2)
                                return val.toFixed(decimals) + (unit ? " " + unit : "")
                            }
                            color:              "white"
                            font.pointSize:     ScreenTools.defaultFontPointSize * 0.8
                            font.bold:          true
                        }
                    }
                }
            }
        }
    }
}
