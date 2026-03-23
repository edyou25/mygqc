/****************************************************************************
 *
 * (c) 2009-2024 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

#pragma once

#include "QGCLoggingCategory.h"

#include <QObject>
#include <QGeoCoordinate>
#include <QJsonObject>
#include <QJsonArray>
#include <QPointF>
#include <QVector>
#include <QVariant>
Q_DECLARE_LOGGING_CATEGORY(TowerOptimizerLog)

/// Tower location for signal strength optimization
struct TowerInfo {
    QGeoCoordinate coordinate;
    QString name;
    QString type;  // "tower" or "sensor"
    double noFlyRadius = 0.0;  // for sensors only
    QString direction;  // "up" or "down" for sensors
    QString weatherType = "no_fly"; // "suitable" | "warning" | "no_fly"
    double avoidWeight = 1.0;       // warning/no_fly avoidance weight [0,1+]
    int warningLevel = 1;           // warning severity level
    double influenceRadius = 0.0;   // warning influence radius in meters
    
    TowerInfo() = default;
    TowerInfo(const QGeoCoordinate& coord, const QString& n = QString(), const QString& t = "tower")
        : coordinate(coord), name(n), type(t) {}
};

/// Search node for A* algorithm
struct AStarNode {
    int gx = 0;           // Grid x offset
    int gy = 0;           // Grid y offset
    double g = 0.0;       // Cost from start
    double h = 0.0;       // Heuristic cost to goal
    double f = 0.0;       // Total cost (g + h)
    double deviation = 0.0;   // Deviation from original
    double signal = 0.0;      // Signal strength
    AStarNode* parent = nullptr;
    
    bool operator<(const AStarNode& other) const {
        return f > other.f;  // For min-heap
    }
};

/// Configuration for optimization algorithms
struct OptimizationConfig {
    // A* parameters
    double cellSizeMeters = 30.0;
    int radiusCells = 10;
    double weightDeviation = 0.25;
    double weightSignal = 18000.0;
    int maxIterations = 8000;
    
    // RRT parameters
    double searchRadiusMeters = 300.0;
    int maxSamples = 1000;
    double stepMeters = 30.0;
    double goalBias = 0.3;
    
    // A* New parameters
    double stepSizeMeters = 100.0;
    double maxStepSizeMeters = 500.0;
    double minStepSizeMeters = 50.0;
    double astarNewSearchRadiusMeters = 5000.0;
    int maxWaypoints = 100;
    double weightCollision = 10000.0;
    double collisionBufferMeters = 150.0;
    int astarNewMaxIterations = 5000;
    
    // Signal model
    double attenuationExponent = 1.2;
    double baseDistanceMeters = 300.0;
    double signalRadiusMeters = 12000.0;
    double strengthMultiplier = 1.0;
    
    // Separation constraints
    double minSeparationMeters = 5.0;
    double safeSeparationMeters = 15.0;
    
    // Collision detection
    bool enableCollisionCheck = true;
    double minAltitudeAGL = 30.0;
    double terrainClearance = 10.0;
    double buildingClearance = 5.0;
    bool weatherCollisionCheck = true;
    double weatherBufferMeters = 5.0;
    
    void loadFromJson(const QJsonObject& json);
};

/// Path optimization using tower signal strength and collision avoidance
class TowerOptimizer : public QObject
{
    Q_OBJECT
    
public:
    explicit TowerOptimizer(QObject* parent = nullptr);
    ~TowerOptimizer() override;
    
    // Load tower and sensor data from JSON
    Q_INVOKABLE bool loadTowersFromJson(const QString& jsonFilePath);
    Q_INVOKABLE bool loadConfigFromJson(const QString& configFilePath);
    Q_INVOKABLE bool loadSignalGridFromCsv(const QString& csvFilePath);
    
    // Optimization methods (to be implemented)
    // Note: Will need MissionController* once fully implemented
    Q_INVOKABLE bool optimizeMissionAStar();
    Q_INVOKABLE bool optimizeMissionRRT();
    Q_INVOKABLE QVector<QGeoCoordinate> optimizePathAStarNew(const QVector<QGeoCoordinate>& originalPath, double altitude = 100.0);
    
    // Test methods for single waypoint optimization
    Q_INVOKABLE QGeoCoordinate optimizeSingleWaypoint(const QGeoCoordinate& current,
                                                        const QGeoCoordinate& next,
                                                        const QGeoCoordinate& prev,
                                                        double altitude = 100.0);
    
    Q_INVOKABLE QGeoCoordinate optimizeSingleWaypointRRT(const QGeoCoordinate& current,
                                                          const QGeoCoordinate& next,
                                                          const QGeoCoordinate& prev,
                                                          double altitude = 100.0);
    
    // Collision detection
    Q_INVOKABLE bool checkCollision(const QGeoCoordinate& coord, double altitudeAMSL = 0.0);
    Q_INVOKABLE bool checkWeatherCollision(const QGeoCoordinate& coord);
    Q_INVOKABLE bool checkTerrainCollision(const QGeoCoordinate& coord, double altitudeAMSL);
    
    // Signal strength calculation
    Q_INVOKABLE double calculateSignalStrength(const QGeoCoordinate& coord);

    // Extra "attractor" points injected from QML (e.g. Greenland/Water centers)
    // points: [ {lat: <double>, lon: <double>, name: <string>, type: <string>}, ... ]
    Q_INVOKABLE void setAttractors(const QVariantList& points);
    Q_INVOKABLE void clearAttractors();
    Q_INVOKABLE void setGreenlandAreas(const QVariantList& areas);
    Q_INVOKABLE void setWaterAreas(const QVariantList& areas);
    Q_INVOKABLE void setBuildingAreas(const QVariantList& areas);
    Q_INVOKABLE void setRoads(const QVariantList& roads);
    Q_INVOKABLE void setFeatureCorridor(const QVariantList& anchors, double paddingMeters);
    Q_INVOKABLE double buildingHeightAt(const QGeoCoordinate& coord);
    Q_INVOKABLE double maxBuildingHeightAlongSegment(const QGeoCoordinate& start,
                                                     const QGeoCoordinate& end,
                                                     double sampleSpacingMeters = 25.0);
    Q_INVOKABLE int buildingHeightFeatureCount() const;
    
    // Getters
    const QVector<TowerInfo>& towers() const { return _towers; }
    const QVector<TowerInfo>& sensors() const { return _sensors; }
    const OptimizationConfig& config() const { return _config; }
    
signals:
    void towersLoaded(int towerCount, int sensorCount);
    void configLoaded();
    void optimizationProgress(int current, int total);
    void optimizationComplete(bool success, const QString& message);
    void collisionDetected(const QGeoCoordinate& coord, const QString& reason);
    
private:
    // A* Node structure
    struct AStarNode {
        int gx, gy;           // Grid coordinates
        double g;             // Cost from start
        double h;             // Heuristic to goal
        double f;             // Total cost (g + h + other factors)
        double dev;           // Deviation from original
        double sig;           // Signal strength
        AStarNode* parent;    // Parent node for path reconstruction
        
        AStarNode() : gx(0), gy(0), g(0), h(0), f(0), dev(0), sig(0), parent(nullptr) {}
        
        // For priority queue (min-heap)
        bool operator>(const AStarNode& other) const {
            return f > other.f;
        }
    };
    
    // RRT Node structure
    struct RRTNode {
        double x, y;          // Position in meters (relative to origin)
        int parentIdx;        // Parent node index (-1 for root)
        double g;             // Path cost from start
        double h;             // Heuristic to goal
        double f;             // Total cost
        double dev;           // Deviation from original
        double sig;           // Signal strength
        
        RRTNode() : x(0), y(0), parentIdx(-1), g(0), h(0), f(0), dev(0), sig(0) {}
    };

    struct SignalSample {
        QGeoCoordinate coordinate;
        double scoreNorm = 0.0; // Normalized to [0,1]
    };

    struct GeoBounds {
        double minLat = 0.0;
        double minLon = 0.0;
        double maxLat = 0.0;
        double maxLon = 0.0;
        bool valid = false;
    };

    struct FeaturePath {
        QString id;
        QVector<QGeoCoordinate> path;
        GeoBounds bounds;
        bool closed = false;
        double heightMeters = 0.0;
        double minHeightMeters = 0.0;
        double levels = 0.0;
    };

    struct UiWeights {
        double distance = 0.5;
        double signal = 0.5;
        double weather = 0.5;
        double greenland = 0.5;
        double building = 0.5;
        double water = 0.5;
        double road = 0.5;
    };
    
    // Tower data
    QVector<TowerInfo> _towers;
    QVector<TowerInfo> _sensors;
    OptimizationConfig _config;
    QVector<TowerInfo> _extraAttractors;
    double _extraAttractorScale = 0.3;   // 绿地/水体吸引力：真 tower 的 0.3 倍
    QVector<FeaturePath> _greenlandAreas;
    QVector<FeaturePath> _waterAreas;
    QVector<FeaturePath> _buildingAreas;
    QVector<FeaturePath> _roadPaths;
    QVector<FeaturePath> _activeGreenlandAreas;
    QVector<FeaturePath> _activeWaterAreas;
    QVector<FeaturePath> _activeBuildingAreas;
    QVector<FeaturePath> _activeRoadPaths;
    int _buildingHeightFeatureCount = 0;
    int _activeBuildingHeightFeatureCount = 0;
    // Cache for optimization
    QHash<QString, double> _signalCache;
    QHash<QString, double> _environmentCache;
    QHash<QString, double> _heuristicCache;
    QHash<QString, double> _terrainCache;  // Cache for terrain heights
    QVector<SignalSample> _signalSamples;
    bool _hasSignalGrid = false;
    
    // Terrain query interface (TODO: Add when TerrainQuery is available)
    // TerrainQueryInterface* _terrainQuery;
    
    // Helper methods
    QGeoCoordinate _gridToCoord(int gx, int gy, const QGeoCoordinate& origin);
    double _haversineDistance(const QGeoCoordinate& coord1, const QGeoCoordinate& coord2) const;
    double _calculateHeuristic(int gx, int gy, const QGeoCoordinate& origin, 
                               const QGeoCoordinate& next);
    double _calculateDeviationCost(int gx, int gy, double cellSize);
    double _calculateSignalAt(int gx, int gy, const QGeoCoordinate& origin);
    double _calculateEnvironmentCostAt(int gx, int gy, const QGeoCoordinate& origin);
    double _querySignalGridScore(const QGeoCoordinate& coord, double* nearestDistanceMeters = nullptr);
    QVector<QGeoCoordinate> _parseCoordinateList(const QVariantList& rawCoords) const;
    QVector<FeaturePath> _parseFeaturePaths(const QVariantList& rawFeatures, bool closedPaths) const;
    GeoBounds _boundsForPath(const QVector<QGeoCoordinate>& path) const;
    GeoBounds _corridorBounds(const QVector<QGeoCoordinate>& anchors, double paddingMeters) const;
    bool _boundsIntersect(const GeoBounds& lhs, const GeoBounds& rhs) const;
    double _distanceToBoundsMeters(const QGeoCoordinate& coord, const GeoBounds& bounds) const;
    void _updateActiveFeaturesForCorridor(const QVector<QGeoCoordinate>& anchors, double paddingMeters);
    QPointF _coordToLocalMeters(const QGeoCoordinate& coord, const QGeoCoordinate& origin) const;
    double _pointToSegmentDistanceMeters(const QPointF& p, const QPointF& a, const QPointF& b) const;
    bool _pointInPolygon(const QPointF& p, const QVector<QPointF>& polygon) const;
    double _distanceToPolygonMeters(const QGeoCoordinate& coord, const FeaturePath& polygon, bool* inside = nullptr) const;
    double _distanceToPolylineMeters(const QGeoCoordinate& coord, const FeaturePath& polyline) const;
    UiWeights _currentUiWeights() const;
    double _calculateWeatherInfluenceScore(const QGeoCoordinate& coord) const;
    bool _checkWeatherSegmentCollision(const QGeoCoordinate& start, const QGeoCoordinate& end) const;
    double _calculateAreaAttractionScore(const QGeoCoordinate& coord, const QVector<FeaturePath>& areas, double decayMeters) const;
    double _calculateRoadAttractionScore(const QGeoCoordinate& coord) const;
    double _calculateEnvironmentCost(const QGeoCoordinate& coord) const;
    double _defaultBuildingHeightMeters(double levels) const;
    double _buildingHeightAboveGround(const FeaturePath& building) const;
    double _buildingHeightAt(const QGeoCoordinate& coord, const QVector<FeaturePath>& buildings) const;
    double _maxBuildingHeightAlongSegment(const QGeoCoordinate& start,
                                          const QGeoCoordinate& end,
                                          double sampleSpacingMeters,
                                          const QVector<FeaturePath>& buildings) const;
    
    // A* implementation helpers
    void _clearCaches();
    QString _gridKey(int gx, int gy) const;
    
    // A* optimization for single waypoint
    QGeoCoordinate _optimizeWaypointAStar(const QGeoCoordinate& current, 
                                          const QGeoCoordinate& next,
                                          const QGeoCoordinate& prev,
                                          double altitude);
    
    // RRT optimization for single waypoint
    QGeoCoordinate _optimizeWaypointRRT(const QGeoCoordinate& current,
                                        const QGeoCoordinate& next,
                                        const QGeoCoordinate& prev,
                                        double altitude);
    
    // A* New optimization - 50m fixed step path planning
    QVector<QGeoCoordinate> _optimizePathAStarNew(const QVector<QGeoCoordinate>& originalPath,
                                                  double altitude);
    QVector<QGeoCoordinate> _planPathAStarNew(const QGeoCoordinate& start, const QGeoCoordinate& goal, 
                                              double altitude, int maxSteps);
    
    // Terrain helper methods
    double _getCachedTerrainHeight(const QGeoCoordinate& coord);
    double _estimateTerrainHeight(const QGeoCoordinate& coord);
    
    // RRT helper methods
    struct XYCoord { double x, y; };
    XYCoord _latLonToXY(double lat, double lon, double lat0, double lon0, double metersPerDegLat, double metersPerDegLon) const;
    QGeoCoordinate _xyToLatLon(double x, double y, double lat0, double lon0, double metersPerDegLat, double metersPerDegLon, double altitude) const;
    int _findNearestNode(const QVector<RRTNode>& nodes, double x, double y) const;
    
    // Terrain query integration (TODO)
    bool _queryTerrainHeight(const QGeoCoordinate& coord, double& terrainHeight);
};
