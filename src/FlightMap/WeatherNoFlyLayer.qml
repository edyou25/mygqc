// WeatherNoFlyLayer.qml
// Renders circular no-fly zones for towers/sensors
// Mimics SignalStrengthLayer pattern for reliability

import QtQuick 2.12
import QtLocation 5.3
import QtPositioning 5.3
import QGroundControl 1.0

Item {
    id: root
    
    // Inputs provided by Loader in FlightMap.qml
    property var map: null
    property var towerModel: null
    
    // Config
    readonly property int defaultTowerRadius: 500
    readonly property int defaultSensorRadius: 600
    
    visible: !!towerModel && towerModel.count > 0 && map
    
    Canvas {
        id: canvas
        anchors.fill: parent
        
        onPaint: {
            if (!root.map || !towerModel || towerModel.count === 0) return
            var ctx = getContext('2d')
            
            // Reset and clear canvas completely
            ctx.reset()
            ctx.clearRect(0,0,width,height)
            
            console.log('[WeatherNoFlyLayer] Painting', towerModel.count, 'zones', 'canvas size:', width, 'x', height)
            
            // Draw only sensor no-fly zones (skip towers)
            for (var i = 0; i < towerModel.count; i++) {
                var tower = towerModel.get(i)
                
                // Only draw circles for sensors
                if (tower.type !== 'sensor') {
                    continue
                }
                
                var coord = QtPositioning.coordinate(tower.latitude, tower.longitude)
                
                // Convert geo coordinate to screen position
                var screenPos = root.map.fromCoordinate(coord, false)
                
                // Get radius in meters, convert to screen pixels
                var radiusMeters = tower.no_fly_radius || root.defaultSensorRadius
                
                // Approximate: 1 degree latitude ≈ 111,320 meters
                // Calculate offset coordinate at radius distance
                var latOffset = radiusMeters / 111320
                var radiusCoord = QtPositioning.coordinate(tower.latitude + latOffset, tower.longitude)
                var radiusScreenPos = root.map.fromCoordinate(radiusCoord, false)
                var radiusPixels = Math.abs(radiusScreenPos.y - screenPos.y)
                
                // Draw filled circle with border for sensor
                ctx.fillStyle = 'rgba(255, 0, 0, 0.35)'
                ctx.beginPath()
                ctx.arc(screenPos.x, screenPos.y, radiusPixels, 0, 2 * Math.PI)
                ctx.fill()
                
                // Border
                ctx.strokeStyle = 'rgba(255, 0, 0, 1.0)'
                ctx.lineWidth = 3
                ctx.beginPath()
                ctx.arc(screenPos.x, screenPos.y, radiusPixels, 0, 2 * Math.PI)
                ctx.stroke()
                
                // Draw text in center showing height and direction
                var height = tower.height || 0
                var direction = tower.direction || 'up'
                var directionSymbol = (direction === 'up') ? '↑' : '↓'
                var directionText = (direction === 'up') ? '向上禁飞' : '向下禁飞'
                
                // Background box for text
                ctx.font = 'bold 20px Arial'
                var line1 = directionSymbol + ' ' + directionText
                var line2 = height + 'm'
                var line1Width = ctx.measureText(line1).width
                var line2Width = ctx.measureText(line2).width
                var maxTextWidth = Math.max(line1Width, line2Width)
                var textHeight = 50
                var padding = 12
                
                ctx.fillStyle = 'rgba(255, 255, 255, 0.9)'
                ctx.fillRect(screenPos.x - maxTextWidth/2 - padding, 
                            screenPos.y - textHeight/2, 
                            maxTextWidth + padding*2, 
                            textHeight)
                
                // Border for text box
                ctx.strokeStyle = 'rgba(255, 0, 0, 1.0)'
                ctx.lineWidth = 2
                ctx.strokeRect(screenPos.x - maxTextWidth/2 - padding, 
                              screenPos.y - textHeight/2, 
                              maxTextWidth + padding*2, 
                              textHeight)
                
                // Draw text lines
                ctx.fillStyle = 'rgba(255, 0, 0, 1.0)'
                ctx.textAlign = 'center'
                ctx.textBaseline = 'middle'
                ctx.fillText(line1, screenPos.x, screenPos.y - 10)
                ctx.fillText(line2, screenPos.x, screenPos.y + 12)
                
                console.log('[WeatherNoFlyLayer] Drew no-fly zone for sensor', tower.name, 'at', screenPos.x, screenPos.y, 'radius', radiusPixels, 'px', 'height:', height, 'direction:', direction)
            }
        }
        
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
    
    // Update when map changes - like SignalStrengthLayer
    Connections { 
        target: map
        function onCenterChanged() { canvas.requestPaint() }
    }
    Connections { 
        target: map
        function onZoomLevelChanged() { canvas.requestPaint() }
    }
    Connections { 
        target: towerModel
        function onCountChanged() { canvas.requestPaint() }
    }
    onTowerModelChanged: canvas.requestPaint()
}
