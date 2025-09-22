import QtQuick 2.12
import QtQuick.Controls 2.12
import QtQuick.Layouts 1.12
import QtLocation 5.12
import QtPositioning 5.12
import QGroundControl 1.0
import QGroundControl.Controls 1.0

Item {
    id: root
    
    property var map
    property var debugDataProvider: null
    property color nodeColor: "#40FF4444"           // 搜索节点颜色（半透明红）
    property color edgeColor: "#20888888"           // 搜索边颜色（半透明灰）
    property color pathColor: "#FF00FF00"           // 最终路径颜色（绿）
    property color bestNodeColor: "#FFFF0000"       // 最佳节点颜色（红）
    property real nodeSize: 8                       // 节点大小
    property real edgeWidth: 1                      // 边宽度
    property real pathWidth: 3                      // 路径宽度
    
    // 控制面板
    Rectangle {
        id: controlPanel
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.margins: 10
        width: 200
        height: 120
        color: "#80000000"
        radius: 5
        visible: root.visible
        
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
                onClicked: refreshDebugData()
            }
        }
    }
    
    // 搜索树可视化组件
    Repeater {
        id: debugTreeRepeater
        model: root.visible ? root.debugTrees : []
        
        delegate: Item {
            property var treeData: modelData
            
            // 搜索边
            Repeater {
                model: showEdgesCheck.checked ? treeData.edges : []
                delegate: MapPolyline {
                    line.width: edgeWidth
                    line.color: edgeColor
                    path: [
                        QtPositioning.coordinate(modelData.from.lat, modelData.from.lon),
                        QtPositioning.coordinate(modelData.to.lat, modelData.to.lon)
                    ]
                }
            }
            
            // 搜索节点
            Repeater {
                model: showNodesCheck.checked ? treeData.nodes : []
                delegate: MapQuickItem {
                    coordinate: QtPositioning.coordinate(modelData.coord.lat, modelData.coord.lon)
                    anchorPoint.x: nodeRect.width / 2
                    anchorPoint.y: nodeRect.height / 2
                    
                    sourceItem: Rectangle {
                        id: nodeRect
                        width: nodeSize
                        height: nodeSize
                        radius: nodeSize / 2
                        color: modelData.isBest ? bestNodeColor : 
                               modelData.isClosed ? nodeColor : "#4000FF00"
                        border.width: 1
                        border.color: "#80FFFFFF"
                        
                        // 节点信息tooltip
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            
                            ToolTip {
                                visible: parent.containsMouse
                                text: "Grid: (" + modelData.gx + "," + modelData.gy + ")\n" +
                                      "F: " + modelData.f.toFixed(1) + "\n" +
                                      "G: " + modelData.g.toFixed(1) + "\n" +
                                      "H: " + modelData.h.toFixed(1) + "\n" +
                                      "Dev: " + modelData.dev.toFixed(1) + "\n" +
                                      "Sig: " + modelData.sig.toFixed(1) + "\n" +
                                      "State: " + (modelData.isClosed ? "Closed" : "Open") +
                                      (modelData.isBest ? " (Best)" : "")
                            }
                        }
                    }
                }
            }
            
            // 最终路径
            MapPolyline {
                visible: showPathCheck.checked
                line.width: pathWidth
                line.color: pathColor
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
            
            // 起点和终点标记
            MapQuickItem {
                coordinate: QtPositioning.coordinate(treeData.originalCoord.lat, treeData.originalCoord.lon)
                anchorPoint.x: startMarker.width / 2
                anchorPoint.y: startMarker.height / 2
                
                sourceItem: Rectangle {
                    id: startMarker
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
            
            MapQuickItem {
                coordinate: QtPositioning.coordinate(treeData.targetCoord.lat, treeData.targetCoord.lon)
                anchorPoint.x: endMarker.width / 2
                anchorPoint.y: endMarker.height / 2
                
                sourceItem: Rectangle {
                    id: endMarker
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
    
    // 数据模型
    property var debugTrees: []
    
    function refreshDebugData() {
        if (debugDataProvider) {
            debugTrees = debugDataProvider.getDebugSearchTrees()
            console.log('[AStarDebug] Loaded', debugTrees.length, 'search trees')
        } else {
            console.warn('[AStarDebug] No debug data provider available')
            debugTrees = []
        }
    }
    
    function show() {
        visible = true
        refreshDebugData()
    }
    
    function hide() {
        visible = false
    }
    
    function toggle() {
        if (visible) {
            hide()
        } else {
            show()
        }
    }
}