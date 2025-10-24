/****************************************************************************
 *
 * (c) 2009-2024 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

#include "TowerOptimizer.h"
#include "QGC.h"
// #include "TerrainQuery.h"  // TODO: Add terrain query integration when available

#include <QFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QDateTime>
#include <QtMath>
#include <queue>
#include <unordered_map>
#include <unordered_set>
#include <cstdlib>

QGC_LOGGING_CATEGORY(TowerOptimizerLog, "TowerOptimizerLog")

TowerOptimizer::TowerOptimizer(QObject* parent)
    : QObject(parent)
    // , _terrainQuery(nullptr)  // TODO: Initialize when TerrainQuery is available
{
    qCDebug(TowerOptimizerLog) << "TowerOptimizer created";
}

TowerOptimizer::~TowerOptimizer()
{
}

void OptimizationConfig::loadFromJson(const QJsonObject& json)
{
    if (json.contains("astar")) {
        QJsonObject astar = json["astar"].toObject();
        cellSizeMeters = astar["cellSizeMeters"].toDouble(cellSizeMeters);
        radiusCells = astar["radiusCells"].toInt(radiusCells);
        weightDeviation = astar["weightDeviation"].toDouble(weightDeviation);
        weightSignal = astar["weightSignal"].toDouble(weightSignal);
        maxIterations = astar["maxIterations"].toInt(maxIterations);
        
        if (astar.contains("separation")) {
            QJsonObject sep = astar["separation"].toObject();
            minSeparationMeters = sep["minMeters"].toDouble(minSeparationMeters);
            safeSeparationMeters = sep["safeMeters"].toDouble(safeSeparationMeters);
        }
        
        if (astar.contains("signalModel")) {
            QJsonObject sig = astar["signalModel"].toObject();
            attenuationExponent = sig["attenuationExponent"].toDouble(attenuationExponent);
            baseDistanceMeters = sig["baseDistanceMeters"].toDouble(baseDistanceMeters);
            signalRadiusMeters = sig["signalRadiusMeters"].toDouble(signalRadiusMeters);
            strengthMultiplier = sig["strengthMultiplier"].toDouble(strengthMultiplier);
        }
    }
    
    if (json.contains("collision")) {
        QJsonObject col = json["collision"].toObject();
        enableCollisionCheck = col["enableCollisionCheck"].toBool(enableCollisionCheck);
        minAltitudeAGL = col["minAltitudeAGL"].toDouble(minAltitudeAGL);
        terrainClearance = col["terrainClearance"].toDouble(terrainClearance);
        weatherCollisionCheck = col["weatherCollisionCheck"].toBool(weatherCollisionCheck);
        weatherBufferMeters = col["weatherBufferMeters"].toDouble(weatherBufferMeters);
    }
}

bool TowerOptimizer::loadTowersFromJson(const QString& jsonFilePath)
{
    QFile file(jsonFilePath);
    if (!file.open(QIODevice::ReadOnly)) {
        qCWarning(TowerOptimizerLog) << "Failed to open towers file:" << jsonFilePath;
        return false;
    }
    
    QByteArray data = file.readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    
    if (!doc.isArray()) {
        qCWarning(TowerOptimizerLog) << "Invalid towers JSON format";
        return false;
    }
    
    _towers.clear();
    _sensors.clear();
    
    QJsonArray array = doc.array();
    for (const QJsonValue& value : array) {
        QJsonObject obj = value.toObject();
        
        double lat = obj["latitude"].toDouble();
        double lon = obj["longitude"].toDouble();
        QString name = obj["name"].toString();
        QString type = obj["type"].toString("tower");
        
        QGeoCoordinate coord(lat, lon);
        if (!coord.isValid()) {
            qCWarning(TowerOptimizerLog) << "Invalid coordinate:" << lat << lon;
            continue;
        }
        
        TowerInfo info(coord, name, type);
        
        if (type == "sensor") {
            info.noFlyRadius = obj["no_fly_radius"].toDouble(600.0);
            info.direction = obj["direction"].toString("up");
            _sensors.append(info);
            qCInfo(TowerOptimizerLog) << "Loaded sensor:" << info.name 
                                      << "at" << coord 
                                      << "noFlyRadius:" << info.noFlyRadius << "m"
                                      << "direction:" << info.direction;
        } else {
            _towers.append(info);
            qCInfo(TowerOptimizerLog) << "Loaded tower:" << info.name << "at" << coord;
        }
    }
    
    qCInfo(TowerOptimizerLog) << "Loaded" << _towers.size() << "towers and" 
                              << _sensors.size() << "sensors";
    emit towersLoaded(_towers.size(), _sensors.size());
    
    return true;
}

bool TowerOptimizer::loadConfigFromJson(const QString& configFilePath)
{
    QFile file(configFilePath);
    if (!file.open(QIODevice::ReadOnly)) {
        qCWarning(TowerOptimizerLog) << "Failed to open config file:" << configFilePath;
        return false;
    }
    
    QByteArray data = file.readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    
    if (!doc.isObject()) {
        qCWarning(TowerOptimizerLog) << "Invalid config JSON format";
        return false;
    }
    
    _config.loadFromJson(doc.object());
    qCInfo(TowerOptimizerLog) << "Configuration loaded";
    emit configLoaded();
    
    return true;
}

double TowerOptimizer::_haversineDistance(const QGeoCoordinate& coord1, const QGeoCoordinate& coord2)
{
    constexpr double R = 6371000.0; // Earth radius in meters
    
    double lat1 = qDegreesToRadians(coord1.latitude());
    double lat2 = qDegreesToRadians(coord2.latitude());
    double dLat = qDegreesToRadians(coord2.latitude() - coord1.latitude());
    double dLon = qDegreesToRadians(coord2.longitude() - coord1.longitude());
    
    double a = qSin(dLat/2) * qSin(dLat/2) +
               qCos(lat1) * qCos(lat2) *
               qSin(dLon/2) * qSin(dLon/2);
    double c = 2 * qAtan2(qSqrt(a), qSqrt(1-a));
    
    return R * c;
}

double TowerOptimizer::calculateSignalStrength(const QGeoCoordinate& coord)
{
    double composite = 0.0;
    
    for (const TowerInfo& tower : _towers) {
        double distance = _haversineDistance(coord, tower.coordinate);
        
        if (distance < _config.signalRadiusMeters) {
            double normDist = distance / _config.baseDistanceMeters;
            double strength = _config.strengthMultiplier / 
                            qPow(normDist + 1.0, _config.attenuationExponent);
            composite += strength;
        }
    }
    
    return composite;
}

bool TowerOptimizer::checkWeatherCollision(const QGeoCoordinate& coord)
{
    if (!_config.weatherCollisionCheck) {
        qCDebug(TowerOptimizerLog) << "Weather collision check disabled";
        return false;
    }
    
    qCDebug(TowerOptimizerLog) << "Checking weather collision for coord" << coord 
                               << "with" << _sensors.size() << "sensors";
    
    for (const TowerInfo& sensor : _sensors) {
        double distance = _haversineDistance(coord, sensor.coordinate);
        double collisionRadius = sensor.noFlyRadius + _config.weatherBufferMeters;
        
        qCDebug(TowerOptimizerLog) << "Sensor" << sensor.name 
                                   << "distance:" << distance << "m"
                                   << "collision radius:" << collisionRadius << "m"
                                   << "noFlyRadius:" << sensor.noFlyRadius << "m"
                                   << "buffer:" << _config.weatherBufferMeters << "m";
        
        if (distance < collisionRadius) {
            qCWarning(TowerOptimizerLog) << "Weather collision detected near" << sensor.name
                                        << "distance:" << distance << "m < radius:" << collisionRadius << "m";
            emit collisionDetected(coord, QString("Weather: %1 (dist: %2m)").arg(sensor.name).arg(distance, 0, 'f', 1));
            return true;
        }
    }
    
    qCDebug(TowerOptimizerLog) << "No weather collision detected";
    return false;
}

bool TowerOptimizer::checkTerrainCollision(const QGeoCoordinate& coord, double altitudeAMSL)
{
    if (!_config.enableCollisionCheck) {
        return false;
    }
    
    // 使用TerrainQuery获取真实地形高度
    double terrainHeight = 0.0;
    bool terrainDataAvailable = false;
    
    // 尝试获取地形数据
    // TODO: 当TerrainQuery可用时，实现真实的地形查询
    // if (_terrainQuery) {
    //     // 同步查询地形高度（简化版本）
    //     QList<QGeoCoordinate> coords;
    //     coords.append(coord);
    //     
    //     // 这里需要实现同步地形查询
    //     // 由于TerrainQuery是异步的，我们使用缓存或简化的方法
    //     terrainHeight = _getCachedTerrainHeight(coord);
    //     terrainDataAvailable = true;
    // }
    
    // 如果没有地形数据，使用保守估计
    if (!terrainDataAvailable) {
        // 根据坐标估算地形高度（简化模型）
        terrainHeight = _estimateTerrainHeight(coord);
        qCDebug(TowerOptimizerLog) << "Using estimated terrain height:" << terrainHeight << "m for coord" << coord;
    }
    
    double agl = altitudeAMSL - terrainHeight;
    double requiredAGL = _config.minAltitudeAGL + _config.terrainClearance;
    
    if (agl < requiredAGL) {
        qCWarning(TowerOptimizerLog) << "Terrain collision detected at" << coord 
                                    << "AGL:" << agl << "m (required:" << requiredAGL << "m)"
                                    << "terrain:" << terrainHeight << "m AMSL:" << altitudeAMSL << "m";
        emit collisionDetected(coord, QString("Terrain: AGL %1m < %2m").arg(agl, 0, 'f', 1).arg(requiredAGL, 0, 'f', 1));
        return true;
    }
    
    return false;
}

bool TowerOptimizer::checkCollision(const QGeoCoordinate& coord, double altitudeAMSL)
{
    qCDebug(TowerOptimizerLog) << "Checking collision for coord" << coord 
                               << "altitude AMSL:" << altitudeAMSL << "m";
    
    // 检查天气碰撞
    if (checkWeatherCollision(coord)) {
        qCDebug(TowerOptimizerLog) << "Weather collision detected, returning true";
        return true;
    }
    
    // 检查地形碰撞
    if (altitudeAMSL > 0.0 && checkTerrainCollision(coord, altitudeAMSL)) {
        qCDebug(TowerOptimizerLog) << "Terrain collision detected, returning true";
        return true;
    }
    
    qCDebug(TowerOptimizerLog) << "No collision detected";
    return false;
}

QGeoCoordinate TowerOptimizer::_gridToCoord(int gx, int gy, const QGeoCoordinate& origin)
{
    constexpr double metersPerDegLat = 111320.0;
    double cosLat = qCos(qDegreesToRadians(origin.latitude()));
    double metersPerDegLon = metersPerDegLat * cosLat;
    
    double dxMeters = gx * _config.cellSizeMeters;
    double dyMeters = gy * _config.cellSizeMeters;
    
    double dLat = dyMeters / metersPerDegLat;
    double dLon = dxMeters / metersPerDegLon;
    
    return QGeoCoordinate(origin.latitude() + dLat, 
                          origin.longitude() + dLon,
                          origin.altitude());
}

double TowerOptimizer::_calculateHeuristic(int gx, int gy, const QGeoCoordinate& origin,
                                           const QGeoCoordinate& next)
{
    QString key = _gridKey(gx, gy);
    if (_heuristicCache.contains(key)) {
        return _heuristicCache[key];
    }
    
    QGeoCoordinate gridCoord = _gridToCoord(gx, gy, origin);
    double distToNext = _haversineDistance(gridCoord, next);
    double origDist = _haversineDistance(origin, next);
    
    // Penalize deviation from original path direction
    double result = qAbs(distToNext - origDist) * 0.5;
    _heuristicCache[key] = result;
    return result;
}

double TowerOptimizer::_calculateDeviationCost(int gx, int gy, double cellSize)
{
    // Fast Euclidean distance in grid space
    return qSqrt(gx * gx + gy * gy) * cellSize;
}

double TowerOptimizer::_calculateSignalAt(int gx, int gy, const QGeoCoordinate& origin)
{
    QString key = _gridKey(gx, gy);
    if (_signalCache.contains(key)) {
        return _signalCache[key];
    }
    
    QGeoCoordinate gridCoord = _gridToCoord(gx, gy, origin);
    double result = calculateSignalStrength(gridCoord);
    _signalCache[key] = result;
    return result;
}

void TowerOptimizer::_clearCaches()
{
    _signalCache.clear();
    _heuristicCache.clear();
}

QString TowerOptimizer::_gridKey(int gx, int gy) const
{
    return QString("%1,%2").arg(gx).arg(gy);
}

QGeoCoordinate TowerOptimizer::_optimizeWaypointAStar(const QGeoCoordinate& current,
                                                       const QGeoCoordinate& next,
                                                       const QGeoCoordinate& prev,
                                                       double altitude)
{
    // Clear caches for fresh calculation
    _clearCaches();
    
    // A* parameters
    double cellSize = _config.cellSizeMeters;
    int radiusCells = _config.radiusCells;
    double wDev = _config.weightDeviation;
    double wSig = _config.weightSignal;
    int maxIterations = _config.maxIterations;
    
    // Separation constraints
    double minSeparation = _config.minSeparationMeters;
    double safeSeparation = _config.safeSeparationMeters;
    
    // Calculate original distances for ratio checking
    double origDistToNext = _haversineDistance(current, next);
    double origDistToPrev = prev.isValid() ? _haversineDistance(current, prev) : 0.0;
    
    qCInfo(TowerOptimizerLog) << "Starting A* optimization for waypoint at" 
                               << current.latitude() << current.longitude()
                               << "with distance constraints:"
                               << "next=" << origDistToNext << "m"
                               << "prev=" << origDistToPrev << "m";
    
    // Priority queue (min-heap) for open set
    auto comp = [](AStarNode* a, AStarNode* b) { return a->f > b->f; };
    std::priority_queue<AStarNode*, std::vector<AStarNode*>, decltype(comp)> openQueue(comp);
    
    QHash<QString, AStarNode*> open;    // For O(1) lookup
    QHash<QString, bool> closed;
    QList<AStarNode*> allNodes;         // For cleanup
    
    // Start node at origin (0,0) in grid space
    AStarNode* start = new AStarNode();
    start->gx = 0;
    start->gy = 0;
    start->g = 0;
    start->dev = 0;
    start->sig = _calculateSignalAt(0, 0, current);
    start->h = _calculateHeuristic(0, 0, current, next);
    start->f = start->g + wDev * start->dev + start->h - wSig * start->sig;
    start->parent = nullptr;
    
    QString startKey = _gridKey(0, 0);
    open[startKey] = start;
    openQueue.push(start);
    allNodes.append(start);
    
    AStarNode* bestSoFar = start;
    int iterations = 0;
    
    // 8-direction neighbors
    const int dx[] = {1, -1, 0, 0, 1, 1, -1, -1};
    const int dy[] = {0, 0, 1, -1, 1, -1, 1, -1};
    
    while (!openQueue.empty() && iterations < maxIterations) {
        iterations++;
        
        // Get node with lowest f
        AStarNode* currentNode = openQueue.top();
        openQueue.pop();
        
        QString currentKey = _gridKey(currentNode->gx, currentNode->gy);
        
        // Skip if already closed
        if (closed.contains(currentKey)) {
            continue;
        }
        
        closed[currentKey] = true;
        open.remove(currentKey);
        
        // Track best node
        if (currentNode->f < bestSoFar->f) {
            bestSoFar = currentNode;
        }
        
        // Early termination check
        double origSig = _calculateSignalAt(0, 0, current);
        double sigImprovement = (origSig > 0) ? ((currentNode->sig - origSig) / origSig) : 0;
        double maxSearchRadius = cellSize * radiusCells;
        
        if (sigImprovement > 0.2 && currentNode->dev < maxSearchRadius * 0.3) {
            qCInfo(TowerOptimizerLog) << "Early termination: signal improved by" 
                                      << (sigImprovement * 100) << "% at iteration" << iterations;
            bestSoFar = currentNode;
            break;
        }
        
        // Expand neighbors
        for (int dir = 0; dir < 8; dir++) {
            int ngx = currentNode->gx + dx[dir];
            int ngy = currentNode->gy + dy[dir];
            
            // Check bounds
            if (ngx < -radiusCells || ngx > radiusCells || 
                ngy < -radiusCells || ngy > radiusCells) {
                continue;
            }
            
            QString neighborKey = _gridKey(ngx, ngy);
            
            // Skip if closed
            if (closed.contains(neighborKey)) {
                continue;
            }
            
            // *** 添加间距约束检查 ***
            // 计算候选位置
            QGeoCoordinate candidateCoord = _gridToCoord(ngx, ngy, current);
            
            // *** 碰撞检测 ***
            if (_config.enableCollisionCheck && checkCollision(candidateCoord, altitude)) {
                continue;  // 碰撞，跳过
            }
            
            // 检查与next waypoint的距离
            double distToNext = _haversineDistance(candidateCoord, next);
            if (distToNext < minSeparation) {
                continue;  // 太近，跳过
            }
            
            // 检查距离比例（60%-140%）
            double nextRatio = distToNext / origDistToNext;
            if (nextRatio < 0.6 || nextRatio > 1.4) {
                continue;  // 距离比例超出范围，跳过
            }
            
            // 如果有prev waypoint，也检查
            if (prev.isValid() && origDistToPrev > 0) {
                double distToPrev = _haversineDistance(candidateCoord, prev);
                if (distToPrev < minSeparation) {
                    continue;  // 太近，跳过
                }
                
                double prevRatio = distToPrev / origDistToPrev;
                if (prevRatio < 0.6 || prevRatio > 1.4) {
                    continue;  // 距离比例超出范围，跳过
                }
            }
            
            // Calculate costs
            double stepCost = (dx[dir] == 0 || dy[dir] == 0) ? cellSize : cellSize * 1.41421356;
            double g = currentNode->g + stepCost;
            double dev = _calculateDeviationCost(ngx, ngy, cellSize);
            double sig = _calculateSignalAt(ngx, ngy, current);
            double h = _calculateHeuristic(ngx, ngy, current, next);
            double f = g + wDev * dev + h - wSig * sig;
            
            // Check if already in open set
            if (open.contains(neighborKey)) {
                AStarNode* existing = open[neighborKey];
                if (f < existing->f) {
                    // Update existing node
                    existing->g = g;
                    existing->dev = dev;
                    existing->sig = sig;
                    existing->h = h;
                    existing->f = f;
                    existing->parent = currentNode;
                }
            } else {
                // Create new node
                AStarNode* newNode = new AStarNode();
                newNode->gx = ngx;
                newNode->gy = ngy;
                newNode->g = g;
                newNode->dev = dev;
                newNode->sig = sig;
                newNode->h = h;
                newNode->f = f;
                newNode->parent = currentNode;
                
                open[neighborKey] = newNode;
                openQueue.push(newNode);
                allNodes.append(newNode);
            }
        }
    }
    
    qCInfo(TowerOptimizerLog) << "A* completed after" << iterations << "iterations";
    
    // Get best coordinate
    QGeoCoordinate result = _gridToCoord(bestSoFar->gx, bestSoFar->gy, current);
    result.setAltitude(altitude);
    
    // Cleanup
    qDeleteAll(allNodes);
    
    return result;
}

QGeoCoordinate TowerOptimizer::optimizeSingleWaypoint(const QGeoCoordinate& current,
                                                       const QGeoCoordinate& next,
                                                       const QGeoCoordinate& prev,
                                                       double altitude)
{
    if (!current.isValid() || !next.isValid()) {
        qCWarning(TowerOptimizerLog) << "Invalid coordinates provided to optimizeSingleWaypoint";
        return current;
    }
    
    if (_towers.isEmpty()) {
        qCWarning(TowerOptimizerLog) << "No towers loaded, returning original coordinate";
        return current;
    }
    
    return _optimizeWaypointAStar(current, next, prev, altitude);
}

// Note: Full A* implementation would go here
// This is a skeleton - full implementation needed
bool TowerOptimizer::optimizeMissionAStar()
{
    qCInfo(TowerOptimizerLog) << "A* optimization not yet fully implemented in C++";
    qCInfo(TowerOptimizerLog) << "Use optimizeSingleWaypoint() for single waypoint optimization";
    return false;
}

bool TowerOptimizer::optimizeMissionRRT()
{
    qCInfo(TowerOptimizerLog) << "RRT optimization not yet fully implemented in C++";
    return false;
}

// ============================================================================
// RRT Implementation
// ============================================================================

TowerOptimizer::XYCoord TowerOptimizer::_latLonToXY(double lat, double lon, 
                                                      double lat0, double lon0,
                                                      double metersPerDegLat, 
                                                      double metersPerDegLon)
{
    XYCoord result;
    result.y = (lat - lat0) * metersPerDegLat;
    result.x = (lon - lon0) * metersPerDegLon;
    return result;
}

QGeoCoordinate TowerOptimizer::_xyToLatLon(double x, double y, 
                                            double lat0, double lon0,
                                            double metersPerDegLat, 
                                            double metersPerDegLon,
                                            double altitude)
{
    double lat = lat0 + (y / metersPerDegLat);
    double lon = lon0 + (x / metersPerDegLon);
    return QGeoCoordinate(lat, lon, altitude);
}

int TowerOptimizer::_findNearestNode(const QVector<RRTNode>& nodes, double x, double y)
{
    if (nodes.isEmpty()) {
        return -1;
    }
    
    int nearestIdx = 0;
    double minDist2 = 1e18;
    
    for (int i = 0; i < nodes.size(); ++i) {
        double dx = x - nodes[i].x;
        double dy = y - nodes[i].y;
        double dist2 = dx * dx + dy * dy;
        
        if (dist2 < minDist2) {
            minDist2 = dist2;
            nearestIdx = i;
        }
    }
    
    return nearestIdx;
}

QGeoCoordinate TowerOptimizer::_optimizeWaypointRRT(const QGeoCoordinate& current,
                                                     const QGeoCoordinate& next,
                                                     const QGeoCoordinate& prev,
                                                     double altitude)
{
    // RRT parameters
    double searchRadiusMeters = _config.searchRadiusMeters;
    int maxSamples = _config.maxSamples;
    double stepMeters = _config.stepMeters;
    double goalBias = _config.goalBias;
    double wDev = _config.weightDeviation;
    double wSig = _config.weightSignal;
    
    double minSeparation = _config.minSeparationMeters;
    double safeSeparation = _config.safeSeparationMeters;
    
    qCInfo(TowerOptimizerLog) << "Starting RRT optimization for waypoint at"
                               << current.latitude() << current.longitude()
                               << "with" << maxSamples << "samples";
    
    // Calculate original distances for ratio checking
    double origDistToNext = _haversineDistance(current, next);
    double origDistToPrev = prev.isValid() ? _haversineDistance(current, prev) : 0.0;
    
    // Coordinate transformation setup
    double lat0 = current.latitude();
    double lon0 = current.longitude();
    double metersPerDegLat = 111320.0;
    double metersPerDegLon = metersPerDegLat * qCos(lat0 * M_PI / 180.0);
    
    // Convert goal to XY
    XYCoord goalXY = _latLonToXY(next.latitude(), next.longitude(), 
                                  lat0, lon0, metersPerDegLat, metersPerDegLon);
    
    // Initialize RRT tree
    QVector<RRTNode> nodes;
    
    // Start node at origin
    RRTNode start;
    start.x = 0;
    start.y = 0;
    start.parentIdx = -1;
    start.g = 0;
    start.dev = 0;
    start.sig = calculateSignalStrength(current);
    start.h = origDistToNext;
    start.f = start.g + wDev * start.dev + start.h - wSig * start.sig;
    nodes.append(start);
    
    RRTNode best = start;
    int bestIdx = 0;
    
    // Random number generator
    std::srand(static_cast<unsigned>(QDateTime::currentMSecsSinceEpoch()));
    
    // RRT main loop
    for (int iter = 0; iter < maxSamples; ++iter) {
        // Sample a point
        double sampleX, sampleY;
        double randVal = static_cast<double>(std::rand()) / RAND_MAX;
        
        if (randVal < goalBias) {
            // Bias toward goal with some noise
            double noiseRange = 0.2 * searchRadiusMeters;
            double noiseX = (static_cast<double>(std::rand()) / RAND_MAX * 2.0 - 1.0) * noiseRange;
            double noiseY = (static_cast<double>(std::rand()) / RAND_MAX * 2.0 - 1.0) * noiseRange;
            sampleX = goalXY.x + noiseX;
            sampleY = goalXY.y + noiseY;
        } else {
            // Random sampling in search radius
            sampleX = (static_cast<double>(std::rand()) / RAND_MAX * 2.0 - 1.0) * searchRadiusMeters;
            sampleY = (static_cast<double>(std::rand()) / RAND_MAX * 2.0 - 1.0) * searchRadiusMeters;
        }
        
        // Find nearest node
        int nearestIdx = _findNearestNode(nodes, sampleX, sampleY);
        if (nearestIdx < 0) continue;
        
        const RRTNode& nearest = nodes[nearestIdx];
        
        // Steer toward sample
        double dirX = sampleX - nearest.x;
        double dirY = sampleY - nearest.y;
        double norm = qSqrt(dirX * dirX + dirY * dirY);
        
        if (norm < 1e-6) continue;
        
        double step = qMin(stepMeters, norm);
        double newX = nearest.x + (dirX / norm) * step;
        double newY = nearest.y + (dirY / norm) * step;
        
        // Clamp to search radius
        newX = qBound(-searchRadiusMeters, newX, searchRadiusMeters);
        newY = qBound(-searchRadiusMeters, newY, searchRadiusMeters);
        
        // Convert to lat/lon
        QGeoCoordinate newCoord = _xyToLatLon(newX, newY, lat0, lon0, 
                                               metersPerDegLat, metersPerDegLon, altitude);
        
        // *** 碰撞检测 ***
        if (_config.enableCollisionCheck && checkCollision(newCoord, altitude)) {
            continue;  // 碰撞，跳过
        }
        
        // Check distance constraints
        double distToNext = _haversineDistance(newCoord, next);
        if (distToNext < minSeparation) {
            continue;
        }
        
        double nextRatio = distToNext / origDistToNext;
        if (nextRatio < 0.6 || nextRatio > 1.4) {
            continue;
        }
        
        if (prev.isValid() && origDistToPrev > 0) {
            double distToPrev = _haversineDistance(newCoord, prev);
            if (distToPrev < minSeparation) {
                continue;
            }
            
            double prevRatio = distToPrev / origDistToPrev;
            if (prevRatio < 0.6 || prevRatio > 1.4) {
                continue;
            }
        }
        
        // Calculate costs
        double dev = _haversineDistance(newCoord, current);
        double sig = calculateSignalStrength(newCoord);
        double h = distToNext;
        double g = nearest.g + step;
        double f = g + wDev * dev + h - wSig * sig;
        
        // Create new node
        RRTNode newNode;
        newNode.x = newX;
        newNode.y = newY;
        newNode.parentIdx = nearestIdx;
        newNode.g = g;
        newNode.dev = dev;
        newNode.sig = sig;
        newNode.h = h;
        newNode.f = f;
        
        nodes.append(newNode);
        
        // Update best node
        if (h < best.h || (qAbs(h - best.h) < 1e-6 && f < best.f)) {
            best = newNode;
            bestIdx = nodes.size() - 1;
        }
    }
    
    qCInfo(TowerOptimizerLog) << "RRT completed with" << nodes.size() << "nodes"
                               << ", best node has h=" << best.h
                               << ", sig=" << best.sig;
    
    // Convert best node back to coordinate
    QGeoCoordinate result = _xyToLatLon(best.x, best.y, lat0, lon0,
                                         metersPerDegLat, metersPerDegLon, altitude);
    
    return result;
}

QGeoCoordinate TowerOptimizer::optimizeSingleWaypointRRT(const QGeoCoordinate& current,
                                                          const QGeoCoordinate& next,
                                                          const QGeoCoordinate& prev,
                                                          double altitude)
{
    if (!current.isValid() || !next.isValid()) {
        qCWarning(TowerOptimizerLog) << "Invalid coordinates provided to optimizeSingleWaypointRRT";
        return current;
    }
    
    if (_towers.isEmpty()) {
        qCWarning(TowerOptimizerLog) << "No towers loaded, returning original coordinate";
        return current;
    }
    
    return _optimizeWaypointRRT(current, next, prev, altitude);
}

double TowerOptimizer::_getCachedTerrainHeight(const QGeoCoordinate& coord)
{
    QString key = QString("%1,%2").arg(coord.latitude(), 0, 'f', 6).arg(coord.longitude(), 0, 'f', 6);
    
    if (_terrainCache.contains(key)) {
        return _terrainCache[key];
    }
    
    // 如果没有缓存，使用估算值并缓存
    double estimatedHeight = _estimateTerrainHeight(coord);
    _terrainCache[key] = estimatedHeight;
    
    return estimatedHeight;
}

double TowerOptimizer::_estimateTerrainHeight(const QGeoCoordinate& coord)
{
    // 简化的地形高度估算模型
    // 基于坐标的简单数学函数来模拟地形变化
    
    double lat = coord.latitude();
    double lon = coord.longitude();
    
    // 基础高度（海平面）
    double baseHeight = 0.0;
    
    // 简单的正弦波地形模型（用于测试）
    // 实际应用中应该使用真实的地形数据
    double terrainVariation = 50.0 * qSin(lat * 10.0) * qCos(lon * 10.0);
    
    // 添加一些随机变化
    double randomVariation = 20.0 * qSin(lat * 100.0) * qCos(lon * 100.0);
    
    double estimatedHeight = baseHeight + terrainVariation + randomVariation;
    
    // 确保高度在合理范围内
    estimatedHeight = qMax(0.0, qMin(estimatedHeight, 1000.0));
    
    return estimatedHeight;
}

