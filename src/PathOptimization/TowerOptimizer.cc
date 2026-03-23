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
#include "PathOptimizationManager.h"
#include <QtGlobal>   // for qBound
#include <QFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QDateTime>
#include <QtMath>
#include <QSet>
#include <queue>
#include <unordered_map>
#include <unordered_set>
#include <cstdlib>
#include <limits>
#include <QResource>
#include <QRegularExpression>
QGC_LOGGING_CATEGORY(TowerOptimizerLog, "TowerOptimizerLog")

// 自定义日志输出函数，将C++日志也写入TowerOptimize专用日志文件
void writeTowerOptimizeLog(const QString& message) {
    qCDebug(TowerOptimizerLog) << "[TowerOptimize]" << message;
}

namespace {

QString _normalizeWeatherType(const QString& rawType, double noFlyRadius)
{
    const QString v = rawType.trimmed().toLower();
    if (v == QStringLiteral("suitable") || v == QStringLiteral("safe") || v == QStringLiteral("fit")
            || v == QStringLiteral("适飞")) {
        return QStringLiteral("suitable");
    }
    if (v == QStringLiteral("warning") || v == QStringLiteral("alert")
            || v == QStringLiteral("警戒")) {
        return QStringLiteral("warning");
    }
    if (v == QStringLiteral("no_fly") || v == QStringLiteral("no-fly")
            || v == QStringLiteral("nofly") || v == QStringLiteral("forbidden")
            || v == QStringLiteral("禁飞")) {
        return QStringLiteral("no_fly");
    }
    if (v.isEmpty()) {
        return noFlyRadius > 0.0 ? QStringLiteral("no_fly") : QStringLiteral("suitable");
    }

    // Unknown types default to no_fly to keep safety behavior conservative.
    return QStringLiteral("no_fly");
}

bool _isWarningSensor(const TowerInfo& sensor)
{
    return sensor.weatherType == QStringLiteral("warning");
}

bool _isSuitableSensor(const TowerInfo& sensor)
{
    return sensor.weatherType == QStringLiteral("suitable");
}

double _noFlyRadiusWithBuffer(const TowerInfo& sensor, double bufferMeters)
{
    return qMax(0.0, sensor.noFlyRadius + bufferMeters);
}

double _warningRadius(const TowerInfo& sensor)
{
    if (sensor.influenceRadius > 0.0) {
        return sensor.influenceRadius;
    }
    return qMax(120.0, sensor.noFlyRadius + 200.0);
}

constexpr double kMetersPerDegreeLat = 111320.0;
constexpr double kGreenlandDecayMeters = 180.0;
constexpr double kBuildingDecayMeters = kGreenlandDecayMeters;
constexpr double kWaterDecayMeters = 180.0;
constexpr double kRoadDecayMeters = 90.0;
constexpr double kWeatherSuitableDecayMeters = 180.0;
constexpr double kWeatherCostScale = 450.0;
constexpr double kGreenlandCostScale = 220.0;
constexpr double kBuildingCostScale = kGreenlandCostScale;
constexpr double kWaterCostScale = 220.0;
constexpr double kRoadCostScale = 180.0;
constexpr double kDefaultBuildingLevelHeightMeters = 3.0;

double _parseMetersValue(const QVariant& value, bool* ok = nullptr)
{
    bool localOk = false;
    double parsed = value.toDouble(&localOk);
    if (localOk && qIsFinite(parsed)) {
        if (ok) {
            *ok = true;
        }
        return parsed;
    }

    const QString text = value.toString().trimmed();
    if (!text.isEmpty()) {
        static const QRegularExpression numberPattern(QStringLiteral(R"([+-]?\d+(?:\.\d+)?)"));
        const QRegularExpressionMatch match = numberPattern.match(text);
        if (match.hasMatch()) {
            parsed = match.captured(0).toDouble(&localOk);
            if (localOk && qIsFinite(parsed)) {
                if (ok) {
                    *ok = true;
                }
                return parsed;
            }
        }
    }

    if (ok) {
        *ok = false;
    }
    return 0.0;
}

bool _variantToCoordinate(const QVariant& value, QGeoCoordinate* out)
{
    if (!out) {
        return false;
    }

    if (value.canConvert<QGeoCoordinate>()) {
        const QGeoCoordinate coord = value.value<QGeoCoordinate>();
        if (coord.isValid()) {
            *out = coord;
            return true;
        }
    }

    const QVariantMap pointMap = value.toMap();
    if (pointMap.contains(QStringLiteral("lat")) && pointMap.contains(QStringLiteral("lon"))) {
        QGeoCoordinate coord(pointMap.value(QStringLiteral("lat")).toDouble(),
                             pointMap.value(QStringLiteral("lon")).toDouble(),
                             pointMap.value(QStringLiteral("alt")).toDouble());
        if (coord.isValid()) {
            *out = coord;
            return true;
        }
    }

    const QVariantList pointList = value.toList();
    if (pointList.size() >= 2) {
        QGeoCoordinate coord(pointList[0].toDouble(), pointList[1].toDouble());
        if (pointList.size() >= 3) {
            coord.setAltitude(pointList[2].toDouble());
        }
        if (coord.isValid()) {
            *out = coord;
            return true;
        }
    }

    return false;
}

} // namespace

TowerOptimizer::TowerOptimizer(QObject* parent)
    : QObject(parent)
    // , _terrainQuery(nullptr)  // TODO: Initialize when TerrainQuery is available
{
    qCInfo(TowerOptimizerLog) << "TowerOptimizer created";
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
    
    if (json.contains("astar_new")) {
        QJsonObject astarNew = json["astar_new"].toObject();
        stepSizeMeters = astarNew["stepSizeMeters"].toDouble(stepSizeMeters);
        maxStepSizeMeters = astarNew["maxStepSizeMeters"].toDouble(maxStepSizeMeters);
        minStepSizeMeters = astarNew["minStepSizeMeters"].toDouble(minStepSizeMeters);
        astarNewSearchRadiusMeters = astarNew["searchRadiusMeters"].toDouble(astarNewSearchRadiusMeters);
        maxWaypoints = astarNew["maxWaypoints"].toInt(maxWaypoints);
        weightCollision = astarNew["weightCollision"].toDouble(weightCollision);
        collisionBufferMeters = astarNew["collisionBufferMeters"].toDouble(collisionBufferMeters);
        astarNewMaxIterations = astarNew["maxIterations"].toInt(astarNewMaxIterations);
        
        if (astarNew.contains("signalModel")) {
            QJsonObject sig = astarNew["signalModel"].toObject();
            attenuationExponent = sig["attenExp"].toDouble(attenuationExponent);
            baseDistanceMeters = sig["baseDistance"].toDouble(baseDistanceMeters);
            signalRadiusMeters = sig["sigRadiusMeters"].toDouble(signalRadiusMeters);
            strengthMultiplier = sig["strengthMultiplier"].toDouble(strengthMultiplier);
        }
    }
    
    if (json.contains("collision")) {
        QJsonObject col = json["collision"].toObject();
        enableCollisionCheck = col["enableCollisionCheck"].toBool(enableCollisionCheck);
        minAltitudeAGL = col["minAltitudeAGL"].toDouble(minAltitudeAGL);
        terrainClearance = col["terrainClearance"].toDouble(terrainClearance);
        buildingClearance = col["buildingClearance"].toDouble(buildingClearance);
        weatherCollisionCheck = col["weatherCollisionCheck"].toBool(weatherCollisionCheck);
        weatherBufferMeters = col["weatherBufferMeters"].toDouble(weatherBufferMeters);
    }
}

bool TowerOptimizer::loadTowersFromJson(const QString& jsonFilePath)
{
    QString path = jsonFilePath;

    // Allow QML-style qrc:/ URLs
    if (path.startsWith(QStringLiteral("qrc:/"))) {
        path = QStringLiteral(":") + path.mid(3); // "qrc:/x" -> ":/x"
    }

    qCDebug(TowerOptimizerLog) << "[TowerOptimizer] loadTowersFromJson input =" << jsonFilePath
                               << "normalized =" << path
                               << "QResource valid =" << QResource(path).isValid();

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCWarning(TowerOptimizerLog) << "Failed to open towers file:" << path
                                     << "exists=" << file.exists()
                                     << "error=" << file.errorString();
        return false;
    }

    const QByteArray data = file.readAll();
    const QJsonDocument doc = QJsonDocument::fromJson(data);

    if (!doc.isArray()) {
        qCWarning(TowerOptimizerLog) << "Invalid towers JSON format";
        return false;
    }

    _towers.clear();
    _sensors.clear();

    const QJsonArray array = doc.array();
    for (const QJsonValue& value : array) {
        const QJsonObject obj = value.toObject();

        const double lat = obj["latitude"].toDouble();
        const double lon = obj["longitude"].toDouble();
        const QString name = obj["name"].toString();
        const QString type = obj["type"].toString(QStringLiteral("tower"));

        const QGeoCoordinate coord(lat, lon);
        if (!coord.isValid()) {
            qCWarning(TowerOptimizerLog) << "Invalid coordinate:" << lat << lon;
            continue;
        }

        TowerInfo info(coord, name, type);

        if (type == QStringLiteral("sensor")) {
            info.noFlyRadius = obj["no_fly_radius"].toDouble(600.0);
            info.direction = obj["direction"].toString(QStringLiteral("up"));
            info.weatherType = _normalizeWeatherType(obj["weather_type"].toString(), info.noFlyRadius);
            info.avoidWeight = obj["avoid_weight"].toDouble(1.0);
            info.warningLevel = obj["warning_level"].toInt(1);
            info.influenceRadius = obj["influence_radius"].toDouble(0.0);

            if (_isSuitableSensor(info)) {
                info.noFlyRadius = 0.0;
                info.warningLevel = 0;
                info.avoidWeight = 0.0;
            } else if (_isWarningSensor(info)) {
                info.avoidWeight = qBound(0.0, info.avoidWeight, 3.0);
                info.warningLevel = qBound(1, info.warningLevel, 5);
                if (info.influenceRadius <= 0.0) {
                    info.influenceRadius = qMax(120.0, info.noFlyRadius + 200.0);
                }
            } else { // no_fly
                info.weatherType = QStringLiteral("no_fly");
                info.avoidWeight = qMax(1.0, info.avoidWeight);
                info.warningLevel = qBound(1, info.warningLevel, 5);
                if (info.noFlyRadius <= 0.0) {
                    info.noFlyRadius = qMax(100.0, info.influenceRadius);
                }
                if (info.influenceRadius <= 0.0) {
                    info.influenceRadius = info.noFlyRadius;
                }
            }

            _sensors.append(info);
            qCDebug(TowerOptimizerLog) << "Loaded sensor:" << info.name
                                       << "at" << coord
                                       << "weatherType:" << info.weatherType
                                       << "warningLevel:" << info.warningLevel
                                       << "avoidWeight:" << info.avoidWeight
                                       << "influenceRadius:" << info.influenceRadius << "m"
                                       << "noFlyRadius:" << info.noFlyRadius << "m"
                                       << "direction:" << info.direction;
        } else {
            _towers.append(info);
        }
    }

    qCInfo(TowerOptimizerLog) << "Loaded" << _towers.size() << "towers and"
                              << _sensors.size() << "sensors";
    emit towersLoaded(_towers.size(), _sensors.size());

    return true;
}

bool TowerOptimizer::loadConfigFromJson(const QString& configFilePath)
{
    QString path = configFilePath;

    if (path.startsWith(QStringLiteral("qrc:/"))) {
        path = QStringLiteral(":") + path.mid(3);
    }

    qCDebug(TowerOptimizerLog) << "[TowerOptimizer] loadConfigFromJson input =" << configFilePath
                               << "normalized =" << path
                               << "QResource valid =" << QResource(path).isValid();

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCWarning(TowerOptimizerLog) << "Failed to open config file:" << path
                                     << "exists=" << file.exists()
                                     << "error=" << file.errorString();
        return false;
    }

    const QByteArray data = file.readAll();
    const QJsonDocument doc = QJsonDocument::fromJson(data);

    if (!doc.isObject()) {
        qCWarning(TowerOptimizerLog) << "Invalid config JSON format";
        return false;
    }

    _config.loadFromJson(doc.object());
    qCInfo(TowerOptimizerLog) << "Configuration loaded";
    emit configLoaded();

    return true;
}

bool TowerOptimizer::loadSignalGridFromCsv(const QString& csvFilePath)
{
    QFile file(csvFilePath);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCWarning(TowerOptimizerLog) << "Failed to open signal CSV:" << csvFilePath
                                     << "exists=" << file.exists()
                                     << "error=" << file.errorString();
        _signalSamples.clear();
        _hasSignalGrid = false;
        return false;
    }

    QStringList lines = QString::fromUtf8(file.readAll()).split('\n', Qt::SkipEmptyParts);
    if (lines.size() < 2) {
        qCWarning(TowerOptimizerLog) << "Signal CSV has insufficient rows:" << csvFilePath;
        _signalSamples.clear();
        _hasSignalGrid = false;
        return false;
    }

    auto cleanLine = [](QString line) {
        line = line.trimmed();
        if (line.endsWith('\r')) {
            line.chop(1);
        }
        return line;
    };

    const QString headerLine = cleanLine(lines.first());
    const QStringList headers = headerLine.split(',', Qt::KeepEmptyParts);

    auto findIndex = [&](const QStringList& aliases) -> int {
        for (int i = 0; i < headers.size(); ++i) {
            const QString col = headers[i].trimmed();
            for (const QString& alias : aliases) {
                if (QString::compare(col, alias, Qt::CaseInsensitive) == 0) {
                    return i;
                }
            }
        }
        return -1;
    };

    const int latIdx = findIndex({QStringLiteral("latitude"), QStringLiteral("lat")});
    const int lonIdx = findIndex({QStringLiteral("longitude"), QStringLiteral("lon"), QStringLiteral("lng")});
    const int heightIdx = findIndex({QStringLiteral("height"), QStringLiteral("altitude"), QStringLiteral("alt")});
    const int scoreIdx = findIndex({QStringLiteral("评分"), QStringLiteral("score"), QStringLiteral("Score")});
    const int rsrpIdx = findIndex({QStringLiteral("SS-RSRP"), QStringLiteral("RSRP"), QStringLiteral("ss-rsrp")});

    if (latIdx < 0 || lonIdx < 0 || (scoreIdx < 0 && rsrpIdx < 0)) {
        qCWarning(TowerOptimizerLog) << "Signal CSV missing required columns."
                                     << "latIdx=" << latIdx
                                     << "lonIdx=" << lonIdx
                                     << "scoreIdx=" << scoreIdx
                                     << "rsrpIdx=" << rsrpIdx
                                     << "file=" << csvFilePath;
        _signalSamples.clear();
        _hasSignalGrid = false;
        return false;
    }

    struct RawSignalSample {
        QGeoCoordinate coordinate;
        double rawScore = 0.0;
    };

    QVector<RawSignalSample> rawSamples;
    rawSamples.reserve(lines.size() - 1);

    double minRawScore = std::numeric_limits<double>::max();
    double maxRawScore = std::numeric_limits<double>::lowest();

    for (int i = 1; i < lines.size(); ++i) {
        const QString line = cleanLine(lines[i]);
        if (line.isEmpty()) {
            continue;
        }

        const QStringList cols = line.split(',', Qt::KeepEmptyParts);
        if (cols.size() <= qMax(latIdx, lonIdx)) {
            continue;
        }

        bool okLat = false;
        bool okLon = false;
        const double lat = cols[latIdx].trimmed().toDouble(&okLat);
        const double lon = cols[lonIdx].trimmed().toDouble(&okLon);
        if (!okLat || !okLon) {
            continue;
        }

        double height = 0.0;
        if (heightIdx >= 0 && heightIdx < cols.size()) {
            bool okHeight = false;
            const double parsedHeight = cols[heightIdx].trimmed().toDouble(&okHeight);
            if (okHeight) {
                height = parsedHeight;
            }
        }

        QGeoCoordinate coord(lat, lon, height);
        if (!coord.isValid()) {
            continue;
        }

        bool scoreOk = false;
        double rawScore = 0.0;

        if (scoreIdx >= 0 && scoreIdx < cols.size()) {
            rawScore = cols[scoreIdx].trimmed().toDouble(&scoreOk);
            if (scoreOk) {
                minRawScore = qMin(minRawScore, rawScore);
                maxRawScore = qMax(maxRawScore, rawScore);
            }
        }

        if (!scoreOk && rsrpIdx >= 0 && rsrpIdx < cols.size()) {
            bool okRsrp = false;
            const double rsrp = cols[rsrpIdx].trimmed().toDouble(&okRsrp);
            if (okRsrp) {
                // Fallback normalization for RSRP in [-120, -60] dBm
                rawScore = qBound(0.0, (rsrp + 120.0) / 60.0, 1.0);
                scoreOk = true;
            }
        }

        if (!scoreOk) {
            continue;
        }

        rawSamples.append({coord, rawScore});
    }

    if (rawSamples.isEmpty()) {
        qCWarning(TowerOptimizerLog) << "No valid signal samples parsed from:" << csvFilePath;
        _signalSamples.clear();
        _hasSignalGrid = false;
        return false;
    }

    _signalSamples.clear();
    _signalSamples.reserve(rawSamples.size());

    const bool hasScoreRange = (scoreIdx >= 0) && (maxRawScore > minRawScore + 1e-9);
    for (const RawSignalSample& sample : rawSamples) {
        double scoreNorm = sample.rawScore;
        if (scoreIdx >= 0) {
            if (hasScoreRange) {
                scoreNorm = (sample.rawScore - minRawScore) / (maxRawScore - minRawScore);
            } else {
                // Conservative fallback for already "score-like" values
                scoreNorm = qBound(0.0, sample.rawScore / 100.0, 1.0);
            }
        }
        scoreNorm = qBound(0.0, scoreNorm, 1.0);
        _signalSamples.append({sample.coordinate, scoreNorm});
    }

    _hasSignalGrid = !_signalSamples.isEmpty();
    _signalCache.clear();

    qCInfo(TowerOptimizerLog) << "Loaded signal grid samples:" << _signalSamples.size()
                              << "from" << csvFilePath
                              << "using" << ((scoreIdx >= 0) ? "score" : "rsrp");
    return _hasSignalGrid;
}



void TowerOptimizer::clearAttractors()
{
    _extraAttractors.clear();
    qCInfo(TowerOptimizerLog) << "Attractors cleared";
}

void TowerOptimizer::setAttractors(const QVariantList& points)
{
    _extraAttractors.clear();
    _extraAttractors.reserve(points.size());

    for (const QVariant& v : points) {
        const QVariantMap m = v.toMap();
        const double lat = m.value("lat").toDouble();
        const double lon = m.value("lon").toDouble();
        const QString name = m.value("name").toString();
        const QString type = m.value("type").isValid()
                ? m.value("type").toString()
                : QStringLiteral("region");
        QGeoCoordinate c(lat, lon);
        if (!c.isValid()) {
            continue;
        }

        TowerInfo info(c, name, type);
        _extraAttractors.append(info);
    }

    qCInfo(TowerOptimizerLog) << "Attractors set:" << _extraAttractors.size()
                             << "scale=" << _extraAttractorScale;
    qWarning() << "[Attractors-C++] setAttractors count=" << _extraAttractors.size();
}

void TowerOptimizer::setGreenlandAreas(const QVariantList& areas)
{
    _greenlandAreas = _parseFeaturePaths(areas, true);
    _activeGreenlandAreas.clear();
    qCInfo(TowerOptimizerLog) << "Greenland areas set:" << _greenlandAreas.size();
}

void TowerOptimizer::setWaterAreas(const QVariantList& areas)
{
    _waterAreas = _parseFeaturePaths(areas, true);
    _activeWaterAreas.clear();
    qCInfo(TowerOptimizerLog) << "Water areas set:" << _waterAreas.size();
}

void TowerOptimizer::setBuildingAreas(const QVariantList& areas)
{
    _buildingAreas = _parseFeaturePaths(areas, true);
    _activeBuildingAreas.clear();
    _activeBuildingHeightFeatureCount = 0;
    int heightAwareCount = 0;
    for (const FeaturePath& building : _buildingAreas) {
        if (_buildingHeightAboveGround(building) > 0.0) {
            ++heightAwareCount;
        }
    }
    _buildingHeightFeatureCount = heightAwareCount;
    qCInfo(TowerOptimizerLog) << "Building areas set:" << _buildingAreas.size()
                              << "heightAware=" << heightAwareCount;
}

void TowerOptimizer::setRoads(const QVariantList& roads)
{
    _roadPaths = _parseFeaturePaths(roads, false);
    _activeRoadPaths.clear();
    qCInfo(TowerOptimizerLog) << "Road paths set:" << _roadPaths.size();
}

void TowerOptimizer::setFeatureCorridor(const QVariantList& anchors, double paddingMeters)
{
    const QVector<QGeoCoordinate> corridorAnchors = _parseCoordinateList(anchors);
    _updateActiveFeaturesForCorridor(corridorAnchors, qMax(0.0, paddingMeters));
}

double TowerOptimizer::buildingHeightAt(const QGeoCoordinate& coord)
{
    if (!coord.isValid()) {
        return 0.0;
    }

    const QVector<FeaturePath>& candidates = _activeBuildingAreas.isEmpty() ? _buildingAreas : _activeBuildingAreas;
    return _buildingHeightAt(coord, candidates);
}

double TowerOptimizer::maxBuildingHeightAlongSegment(const QGeoCoordinate& start,
                                                     const QGeoCoordinate& end,
                                                     double sampleSpacingMeters)
{
    if (!start.isValid() || !end.isValid()) {
        return 0.0;
    }

    const QVector<FeaturePath>& candidates = _activeBuildingAreas.isEmpty() ? _buildingAreas : _activeBuildingAreas;
    return _maxBuildingHeightAlongSegment(start, end, sampleSpacingMeters, candidates);
}

int TowerOptimizer::buildingHeightFeatureCount() const
{
    if (!_activeBuildingAreas.isEmpty()) {
        return _activeBuildingHeightFeatureCount;
    }

    return _buildingHeightFeatureCount;
}

double TowerOptimizer::_haversineDistance(const QGeoCoordinate& coord1, const QGeoCoordinate& coord2) const
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

QVector<QGeoCoordinate> TowerOptimizer::_parseCoordinateList(const QVariantList& rawCoords) const
{
    QVector<QGeoCoordinate> coords;
    coords.reserve(rawCoords.size());

    for (const QVariant& pointValue : rawCoords) {
        QGeoCoordinate coord;
        if (_variantToCoordinate(pointValue, &coord)) {
            coords.append(coord);
        }
    }

    return coords;
}

QVector<TowerOptimizer::FeaturePath> TowerOptimizer::_parseFeaturePaths(const QVariantList& rawFeatures, bool closedPaths) const
{
    QVector<FeaturePath> out;
    out.reserve(rawFeatures.size());

    for (int featureIndex = 0; featureIndex < rawFeatures.size(); ++featureIndex) {
        const QVariantMap featureMap = rawFeatures[featureIndex].toMap();
        const QVector<QGeoCoordinate> path = _parseCoordinateList(featureMap.value(QStringLiteral("path")).toList());

        const int minimumPoints = closedPaths ? 3 : 2;
        if (path.size() < minimumPoints) {
            continue;
        }

        FeaturePath feature;
        feature.id = featureMap.value(QStringLiteral("id")).toString();
        if (feature.id.isEmpty()) {
            feature.id = featureMap.value(QStringLiteral("name")).toString();
        }
        if (feature.id.isEmpty()) {
            feature.id = QString::number(featureIndex + 1);
        }
        feature.path = path;
        feature.bounds = _boundsForPath(path);
        feature.closed = closedPaths;
        bool ok = false;
        feature.heightMeters = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("heightMeters")), &ok));
        if (!ok) {
            feature.heightMeters = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("height_m")), &ok));
        }
        if (!ok) {
            feature.heightMeters = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("height")), &ok));
        }

        ok = false;
        feature.minHeightMeters = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("minHeightMeters")), &ok));
        if (!ok) {
            feature.minHeightMeters = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("min_height")), &ok));
        }
        if (!ok) {
            feature.minHeightMeters = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("minHeight")), &ok));
        }

        ok = false;
        feature.levels = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("levels")), &ok));
        if (!ok) {
            feature.levels = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("building:levels")), &ok));
        }
        if (!ok) {
            feature.levels = qMax(0.0, _parseMetersValue(featureMap.value(QStringLiteral("num_floors")), &ok));
        }
        out.append(feature);
    }

    return out;
}

TowerOptimizer::GeoBounds TowerOptimizer::_boundsForPath(const QVector<QGeoCoordinate>& path) const
{
    GeoBounds bounds;
    if (path.isEmpty()) {
        return bounds;
    }

    bounds.valid = true;
    bounds.minLat = bounds.maxLat = path.first().latitude();
    bounds.minLon = bounds.maxLon = path.first().longitude();

    for (const QGeoCoordinate& coord : path) {
        bounds.minLat = qMin(bounds.minLat, coord.latitude());
        bounds.maxLat = qMax(bounds.maxLat, coord.latitude());
        bounds.minLon = qMin(bounds.minLon, coord.longitude());
        bounds.maxLon = qMax(bounds.maxLon, coord.longitude());
    }

    return bounds;
}

TowerOptimizer::GeoBounds TowerOptimizer::_corridorBounds(const QVector<QGeoCoordinate>& anchors, double paddingMeters) const
{
    GeoBounds bounds;
    if (anchors.isEmpty()) {
        return bounds;
    }

    bounds.valid = true;
    bounds.minLat = bounds.maxLat = anchors.first().latitude();
    bounds.minLon = bounds.maxLon = anchors.first().longitude();

    for (const QGeoCoordinate& coord : anchors) {
        bounds.minLat = qMin(bounds.minLat, coord.latitude());
        bounds.maxLat = qMax(bounds.maxLat, coord.latitude());
        bounds.minLon = qMin(bounds.minLon, coord.longitude());
        bounds.maxLon = qMax(bounds.maxLon, coord.longitude());
    }

    const double meanLat = (bounds.minLat + bounds.maxLat) * 0.5;
    const double latPadding = paddingMeters / kMetersPerDegreeLat;
    const double lonPadding = paddingMeters /
            qMax(1.0, kMetersPerDegreeLat * qAbs(qCos(qDegreesToRadians(meanLat))));

    bounds.minLat -= latPadding;
    bounds.maxLat += latPadding;
    bounds.minLon -= lonPadding;
    bounds.maxLon += lonPadding;
    return bounds;
}

bool TowerOptimizer::_boundsIntersect(const GeoBounds& lhs, const GeoBounds& rhs) const
{
    if (!lhs.valid || !rhs.valid) {
        return false;
    }

    return !(lhs.maxLat < rhs.minLat || lhs.minLat > rhs.maxLat ||
             lhs.maxLon < rhs.minLon || lhs.minLon > rhs.maxLon);
}

double TowerOptimizer::_distanceToBoundsMeters(const QGeoCoordinate& coord, const GeoBounds& bounds) const
{
    if (!bounds.valid) {
        return std::numeric_limits<double>::infinity();
    }

    const double clampedLat = qBound(bounds.minLat, coord.latitude(), bounds.maxLat);
    const double clampedLon = qBound(bounds.minLon, coord.longitude(), bounds.maxLon);
    const QGeoCoordinate clampedCoord(clampedLat, clampedLon, coord.altitude());
    return _haversineDistance(coord, clampedCoord);
}

void TowerOptimizer::_updateActiveFeaturesForCorridor(const QVector<QGeoCoordinate>& anchors, double paddingMeters)
{
    const GeoBounds corridor = _corridorBounds(anchors, paddingMeters);
    auto selectActive = [&](const QVector<FeaturePath>& source, QVector<FeaturePath>& target) {
        target.clear();
        if (!corridor.valid) {
            return;
        }

        target.reserve(source.size());
        for (const FeaturePath& feature : source) {
            if (_boundsIntersect(feature.bounds, corridor)) {
                target.append(feature);
            }
        }
    };

    selectActive(_greenlandAreas, _activeGreenlandAreas);
    selectActive(_waterAreas, _activeWaterAreas);
    selectActive(_buildingAreas, _activeBuildingAreas);
    selectActive(_roadPaths, _activeRoadPaths);

    _activeBuildingHeightFeatureCount = 0;
    for (const FeaturePath& building : _activeBuildingAreas) {
        if (_buildingHeightAboveGround(building) > 0.0) {
            ++_activeBuildingHeightFeatureCount;
        }
    }

    qCDebug(TowerOptimizerLog) << "Active features:"
                               << "greenland=" << _activeGreenlandAreas.size()
                               << "water=" << _activeWaterAreas.size()
                               << "building=" << _activeBuildingAreas.size()
                               << "buildingHeightAware=" << _activeBuildingHeightFeatureCount
                               << "roads=" << _activeRoadPaths.size();
}

QPointF TowerOptimizer::_coordToLocalMeters(const QGeoCoordinate& coord, const QGeoCoordinate& origin) const
{
    const double lat0 = origin.latitude();
    const double lon0 = origin.longitude();
    const double metersPerDegLon = qMax(1e-6, kMetersPerDegreeLat * qAbs(qCos(qDegreesToRadians(lat0))));
    const XYCoord xy = _latLonToXY(coord.latitude(), coord.longitude(), lat0, lon0,
                                   kMetersPerDegreeLat, metersPerDegLon);
    return QPointF(xy.x, xy.y);
}

double TowerOptimizer::_pointToSegmentDistanceMeters(const QPointF& p, const QPointF& a, const QPointF& b) const
{
    const double dx = b.x() - a.x();
    const double dy = b.y() - a.y();
    const double len2 = dx * dx + dy * dy;
    if (len2 <= 1e-9) {
        return qSqrt((p.x() - a.x()) * (p.x() - a.x()) + (p.y() - a.y()) * (p.y() - a.y()));
    }

    const double t = qBound(0.0, ((p.x() - a.x()) * dx + (p.y() - a.y()) * dy) / len2, 1.0);
    const double projX = a.x() + t * dx;
    const double projY = a.y() + t * dy;
    const double diffX = p.x() - projX;
    const double diffY = p.y() - projY;
    return qSqrt(diffX * diffX + diffY * diffY);
}

bool TowerOptimizer::_pointInPolygon(const QPointF& p, const QVector<QPointF>& polygon) const
{
    if (polygon.size() < 3) {
        return false;
    }

    bool inside = false;
    for (int i = 0, j = polygon.size() - 1; i < polygon.size(); j = i++) {
        const QPointF& pi = polygon[i];
        const QPointF& pj = polygon[j];
        double denominator = pj.y() - pi.y();
        if (qAbs(denominator) < 1e-9) {
            denominator = (denominator < 0.0) ? -1e-9 : 1e-9;
        }
        const bool intersects = ((pi.y() > p.y()) != (pj.y() > p.y())) &&
                (p.x() < (pj.x() - pi.x()) * (p.y() - pi.y()) / denominator + pi.x());
        if (intersects) {
            inside = !inside;
        }
    }
    return inside;
}

double TowerOptimizer::_distanceToPolygonMeters(const QGeoCoordinate& coord, const FeaturePath& polygon, bool* inside) const
{
    if (inside) {
        *inside = false;
    }

    if (polygon.path.size() < 3) {
        return std::numeric_limits<double>::infinity();
    }

    QVector<QPointF> localPolygon;
    localPolygon.reserve(polygon.path.size());
    for (const QGeoCoordinate& vertex : polygon.path) {
        localPolygon.append(_coordToLocalMeters(vertex, coord));
    }

    const QPointF queryPoint(0.0, 0.0);
    const bool isInside = _pointInPolygon(queryPoint, localPolygon);
    if (inside) {
        *inside = isInside;
    }
    if (isInside) {
        return 0.0;
    }

    double bestDistance = std::numeric_limits<double>::infinity();
    for (int i = 0; i < localPolygon.size(); ++i) {
        const QPointF& a = localPolygon[i];
        const QPointF& b = localPolygon[(i + 1) % localPolygon.size()];
        bestDistance = qMin(bestDistance, _pointToSegmentDistanceMeters(queryPoint, a, b));
    }
    return bestDistance;
}

double TowerOptimizer::_distanceToPolylineMeters(const QGeoCoordinate& coord, const FeaturePath& polyline) const
{
    if (polyline.path.size() < 2) {
        return std::numeric_limits<double>::infinity();
    }

    double bestDistance = std::numeric_limits<double>::infinity();
    for (int i = 0; i < polyline.path.size() - 1; ++i) {
        const QPointF a = _coordToLocalMeters(polyline.path[i], coord);
        const QPointF b = _coordToLocalMeters(polyline.path[i + 1], coord);
        bestDistance = qMin(bestDistance, _pointToSegmentDistanceMeters(QPointF(0.0, 0.0), a, b));
    }
    return bestDistance;
}

TowerOptimizer::UiWeights TowerOptimizer::_currentUiWeights() const
{
    UiWeights weights;
    if (auto mgr = qobject_cast<PathOptimizationManager*>(parent())) {
        weights.distance = qBound(0.0, mgr->distanceWeight(), 1.0);
        weights.signal = qBound(0.0, mgr->signalWeight(), 1.0);
        weights.weather = qBound(0.0, mgr->weatherWeight(), 1.0);
        weights.greenland = qBound(0.0, mgr->greenlandWeight(), 1.0);
        weights.building = qBound(0.0, mgr->buildingWeight(), 1.0);
        weights.water = qBound(0.0, mgr->waterWeight(), 1.0);
        weights.road = qBound(0.0, mgr->roadWeight(), 1.0);
    }
    return weights;
}

double TowerOptimizer::_calculateWeatherInfluenceScore(const QGeoCoordinate& coord) const
{
    double positive = 0.0;
    double negative = 0.0;

    for (const TowerInfo& sensor : _sensors) {
        const double distance = _haversineDistance(coord, sensor.coordinate);

        if (_isSuitableSensor(sensor)) {
            const double radius = qMax(kWeatherSuitableDecayMeters, _warningRadius(sensor));
            positive = qMax(positive, qExp(-distance / qMax(60.0, radius)));
            continue;
        }

        if (_isWarningSensor(sensor)) {
            const double radius = _warningRadius(sensor);
            if (radius > 0.0 && distance < radius) {
                const double normalized = (radius - distance) / qMax(radius, 1.0);
                negative += normalized * qBound(0.5, sensor.avoidWeight, 3.0) * 0.65;
            }
            continue;
        }

        const double noFlyRadius = _noFlyRadiusWithBuffer(sensor, _config.weatherBufferMeters);
        const double haloRadius = noFlyRadius + qMax(120.0, sensor.noFlyRadius * 0.5);
        if (haloRadius > noFlyRadius && distance < haloRadius) {
            const double normalized = (haloRadius - distance) / qMax(haloRadius - noFlyRadius, 1.0);
            negative += normalized * qMax(1.0, sensor.avoidWeight);
        }
    }

    return qBound(-1.0, positive - qMin(1.5, negative), 1.0);
}

bool TowerOptimizer::_checkWeatherSegmentCollision(const QGeoCoordinate& start, const QGeoCoordinate& end) const
{
    if (!start.isValid() || !end.isValid() || !_config.weatherCollisionCheck) {
        return false;
    }

    const double totalDistance = _haversineDistance(start, end);
    if (!qIsFinite(totalDistance) || totalDistance <= 1.0) {
        return false;
    }

    const double azimuth = start.azimuthTo(end);
    const int sampleCount = qMax(2, static_cast<int>(qCeil(totalDistance / 8.0)));

    for (const TowerInfo& sensor : _sensors) {
        if (_isSuitableSensor(sensor) || _isWarningSensor(sensor)) {
            continue;
        }

        const double noFlyRadius = _noFlyRadiusWithBuffer(sensor, _config.weatherBufferMeters);
        if (noFlyRadius <= 0.0) {
            continue;
        }

        if (_haversineDistance(start, sensor.coordinate) < noFlyRadius ||
                _haversineDistance(end, sensor.coordinate) < noFlyRadius) {
            return true;
        }

        for (int i = 1; i < sampleCount; ++i) {
            const double distance = (static_cast<double>(i) / sampleCount) * totalDistance;
            const QGeoCoordinate sample = start.atDistanceAndAzimuth(distance, azimuth);
            if (_haversineDistance(sample, sensor.coordinate) < noFlyRadius) {
                return true;
            }
        }
    }

    return false;
}

double TowerOptimizer::_calculateAreaAttractionScore(const QGeoCoordinate& coord, const QVector<FeaturePath>& areas, double decayMeters) const
{
    double score = 0.0;

    for (const FeaturePath& area : areas) {
        if (_distanceToBoundsMeters(coord, area.bounds) > decayMeters * 1.8) {
            continue;
        }

        bool inside = false;
        const double distance = _distanceToPolygonMeters(coord, area, &inside);
        if (inside) {
            return 1.0;
        }
        if (qIsFinite(distance)) {
            score = qMax(score, qExp(-distance / decayMeters));
        }
    }

    return qBound(0.0, score, 1.0);
}

double TowerOptimizer::_calculateRoadAttractionScore(const QGeoCoordinate& coord) const
{
    double score = 0.0;

    for (const FeaturePath& road : _activeRoadPaths) {
        if (_distanceToBoundsMeters(coord, road.bounds) > kRoadDecayMeters * 2.0) {
            continue;
        }

        const double distance = _distanceToPolylineMeters(coord, road);
        if (qIsFinite(distance)) {
            score = qMax(score, qExp(-distance / kRoadDecayMeters));
        }
    }

    return qBound(0.0, score, 1.0);
}

double TowerOptimizer::_calculateEnvironmentCost(const QGeoCoordinate& coord) const
{
    const UiWeights weights = _currentUiWeights();
    const double weatherScore = _calculateWeatherInfluenceScore(coord);
    const double greenlandScore = _calculateAreaAttractionScore(coord, _activeGreenlandAreas, kGreenlandDecayMeters);
    const double buildingScore = _calculateAreaAttractionScore(coord, _activeBuildingAreas, kBuildingDecayMeters);
    const double waterScore = _calculateAreaAttractionScore(coord, _activeWaterAreas, kWaterDecayMeters);
    const double roadScore = _calculateRoadAttractionScore(coord);

    double cost = 0.0;
    cost -= weights.weather * weatherScore * kWeatherCostScale;
    cost -= weights.greenland * greenlandScore * kGreenlandCostScale;
    cost += weights.building * buildingScore * kBuildingCostScale;
    cost -= weights.water * waterScore * kWaterCostScale;
    cost -= weights.road * roadScore * kRoadCostScale;
    return cost;
}

double TowerOptimizer::_defaultBuildingHeightMeters(double levels) const
{
    if (!qIsFinite(levels) || levels <= 0.0) {
        return 0.0;
    }

    return levels * kDefaultBuildingLevelHeightMeters;
}

double TowerOptimizer::_buildingHeightAboveGround(const FeaturePath& building) const
{
    const double explicitHeight = qMax(0.0, building.heightMeters);
    const double fallbackHeight = _defaultBuildingHeightMeters(building.levels);
    return qMax(explicitHeight, fallbackHeight) + qMax(0.0, building.minHeightMeters);
}

double TowerOptimizer::_buildingHeightAt(const QGeoCoordinate& coord, const QVector<FeaturePath>& buildings) const
{
    if (!coord.isValid() || buildings.isEmpty()) {
        return 0.0;
    }

    double maxHeight = 0.0;
    for (const FeaturePath& building : buildings) {
        const double height = _buildingHeightAboveGround(building);
        if (height <= 0.0) {
            continue;
        }
        if (!building.bounds.valid) {
            continue;
        }
        if (coord.latitude() < building.bounds.minLat || coord.latitude() > building.bounds.maxLat
                || coord.longitude() < building.bounds.minLon || coord.longitude() > building.bounds.maxLon) {
            continue;
        }

        bool inside = false;
        _distanceToPolygonMeters(coord, building, &inside);
        if (inside) {
            maxHeight = qMax(maxHeight, height);
        }
    }

    return maxHeight;
}

double TowerOptimizer::_maxBuildingHeightAlongSegment(const QGeoCoordinate& start,
                                                      const QGeoCoordinate& end,
                                                      double sampleSpacingMeters,
                                                      const QVector<FeaturePath>& buildings) const
{
    if (!start.isValid() || !end.isValid() || buildings.isEmpty()) {
        return 0.0;
    }

    const double distanceMeters = _haversineDistance(start, end);
    const double spacing = qBound(5.0, sampleSpacingMeters, 80.0);
    const int sampleCount = qMax(2, static_cast<int>(qCeil(distanceMeters / spacing)) + 1);

    double maxHeight = 0.0;
    for (int i = 0; i < sampleCount; ++i) {
        const double t = (sampleCount <= 1) ? 0.0 : (static_cast<double>(i) / static_cast<double>(sampleCount - 1));
        const double altitude = start.altitude() + (end.altitude() - start.altitude()) * t;
        const QGeoCoordinate sample(start.latitude() + (end.latitude() - start.latitude()) * t,
                                    start.longitude() + (end.longitude() - start.longitude()) * t,
                                    altitude);
        maxHeight = qMax(maxHeight, _buildingHeightAt(sample, buildings));
    }

    return maxHeight;
}

double TowerOptimizer::_calculateEnvironmentCostAt(int gx, int gy, const QGeoCoordinate& origin)
{
    const QString key = _gridKey(gx, gy);
    if (_environmentCache.contains(key)) {
        return _environmentCache[key];
    }

    const QGeoCoordinate gridCoord = _gridToCoord(gx, gy, origin);
    const double result = _calculateEnvironmentCost(gridCoord);
    _environmentCache[key] = result;
    return result;
}

double TowerOptimizer::_querySignalGridScore(const QGeoCoordinate& coord, double* nearestDistanceMeters)
{
    if (!_hasSignalGrid || _signalSamples.isEmpty()) {
        if (nearestDistanceMeters) {
            *nearestDistanceMeters = std::numeric_limits<double>::infinity();
        }
        return -1.0;
    }

    double d1 = std::numeric_limits<double>::infinity();
    double d2 = std::numeric_limits<double>::infinity();
    double d3 = std::numeric_limits<double>::infinity();
    double s1 = 0.0;
    double s2 = 0.0;
    double s3 = 0.0;

    for (const SignalSample& sample : _signalSamples) {
        const double d2d = _haversineDistance(coord, sample.coordinate);
        const double dz = qAbs(coord.altitude() - sample.coordinate.altitude());
        const double dist = qSqrt(d2d * d2d + dz * dz);

        if (dist < d1) {
            d3 = d2; s3 = s2;
            d2 = d1; s2 = s1;
            d1 = dist; s1 = sample.scoreNorm;
        } else if (dist < d2) {
            d3 = d2; s3 = s2;
            d2 = dist; s2 = sample.scoreNorm;
        } else if (dist < d3) {
            d3 = dist; s3 = sample.scoreNorm;
        }
    }

    if (!qIsFinite(d1)) {
        if (nearestDistanceMeters) {
            *nearestDistanceMeters = std::numeric_limits<double>::infinity();
        }
        return -1.0;
    }

    auto weight = [](double d) {
        return 1.0 / (d + 10.0); // avoid singularity and keep near-point preference
    };

    double weightedScore = weight(d1) * s1;
    double weightSum = weight(d1);

    if (qIsFinite(d2)) {
        weightedScore += weight(d2) * s2;
        weightSum += weight(d2);
    }
    if (qIsFinite(d3)) {
        weightedScore += weight(d3) * s3;
        weightSum += weight(d3);
    }

    if (nearestDistanceMeters) {
        *nearestDistanceMeters = d1;
    }

    return (weightSum > 0.0) ? (weightedScore / weightSum) : -1.0;
}

/*double TowerOptimizer::calculateSignalStrength(const QGeoCoordinate& coord)
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
}*/
/*double TowerOptimizer::calculateSignalStrength(const QGeoCoordinate& coord)
{
    double composite = 0.0;

    auto accumulate = [&](const QVector<TowerInfo>& towers, double scale) {
        for (const TowerInfo& tower : towers) {
            const double distance = _haversineDistance(coord, tower.coordinate);

            if (distance < _config.signalRadiusMeters) {
                const double normDist = distance / _config.baseDistanceMeters;
                const double strength = (_config.strengthMultiplier * scale) /
                                        qPow(normDist + 1.0, _config.attenuationExponent);
                composite += strength;
            }
        }
    };

    accumulate(_towers, 1.0);
    accumulate(_extraAttractors, _extraAttractorScale);

    return composite;
}*/

double TowerOptimizer::calculateSignalStrength(const QGeoCoordinate& coord)
{
    double composite = 0.0;

    double towersSum = 0.0;
    double csvTerm = 0.0;
    double nearestCsvDistance = std::numeric_limits<double>::infinity();

    auto accumulate = [&](const QVector<TowerInfo>& towers, double scale, double& bucket) {
        for (const TowerInfo& tower : towers) {
            const double distance = _haversineDistance(coord, tower.coordinate);
            if (distance < _config.signalRadiusMeters) {
                const double normDist = distance / _config.baseDistanceMeters;
                const double strength = (_config.strengthMultiplier * scale) /
                                        qPow(normDist + 1.0, _config.attenuationExponent);
                composite += strength;
                bucket += strength; // 新增：落到对应统计桶
            }
        }
    };

    accumulate(_towers, 1.0, towersSum);

    if (_hasSignalGrid) {
        const double csvScore = _querySignalGridScore(coord, &nearestCsvDistance);
        if (csvScore >= 0.0) {
            // Minimal-intrusive blend: keep tower model as baseline, add measured score as bonus.
            constexpr double kCsvBlendWeight = 0.8;
            constexpr double kCsvConfidenceDecayMeters = 150.0;
            const double confidence = qExp(-nearestCsvDistance / kCsvConfidenceDecayMeters);
            csvTerm = kCsvBlendWeight * confidence * csvScore;
            composite += csvTerm;
        }
    }

    static int printed = 0;
    if (printed++ < 10) {
        qCDebug(TowerOptimizerLog) << "[Sig]"
                                   << "coord=" << coord
                                   << "towersSum=" << towersSum
                                   << "csvTerm=" << csvTerm
                                   << "csvNearestDist=" << nearestCsvDistance
                                   << "signalRadius=" << _config.signalRadiusMeters;
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
        if (_isSuitableSensor(sensor) || _isWarningSensor(sensor)) {
            continue;
        }

        const double collisionRadius = _noFlyRadiusWithBuffer(sensor, _config.weatherBufferMeters);
        if (collisionRadius <= 0.0) {
            continue;
        }

        const double distance = _haversineDistance(coord, sensor.coordinate);

        qCDebug(TowerOptimizerLog) << "Sensor" << sensor.name
                                   << "type:" << sensor.weatherType
                                   << "distance:" << distance << "m"
                                   << "collision radius:" << collisionRadius << "m"
                                   << "noFlyRadius:" << sensor.noFlyRadius << "m"
                                   << "buffer:" << _config.weatherBufferMeters << "m";

        if (distance < collisionRadius) {
            qCDebug(TowerOptimizerLog) << "Weather no-fly collision near" << sensor.name
                                       << "distance:" << distance << "m < radius:" << collisionRadius << "m";
            emit collisionDetected(coord, QString("Weather no-fly: %1 (dist: %2m)").arg(sensor.name).arg(distance, 0, 'f', 1));
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
        qCDebug(TowerOptimizerLog) << "Terrain collision detected at" << coord
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
    _environmentCache.clear();
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
    qCDebug(TowerOptimizerLog) << "[A*] ENTER"
                               << "current=" << current
                               << "next=" << next
                               << "prevValid=" << prev.isValid()
                               << "alt=" << altitude;
    // A* parameters
    double cellSize = _config.cellSizeMeters;
    int radiusCells = _config.radiusCells;

    // Base weights from config
    double wDev = _config.weightDeviation;
    double wSig = _config.weightSignal;

    int maxIterations = _config.maxIterations;

    QVector<QGeoCoordinate> corridorAnchors;
    corridorAnchors.append(current);
    corridorAnchors.append(next);
    if (prev.isValid()) {
        corridorAnchors.append(prev);
    }
    _updateActiveFeaturesForCorridor(corridorAnchors, cellSize * radiusCells + 320.0);
    _clearCaches();

    const UiWeights uiWeights = _currentUiWeights();

    wDev *= uiWeights.distance;
    wSig *= uiWeights.signal;

    qCDebug(TowerOptimizerLog) << "A* UI weights:"
                               << "distance=" << uiWeights.distance
                               << "signal=" << uiWeights.signal
                               << "weather=" << uiWeights.weather
                               << "greenland=" << uiWeights.greenland
                               << "building=" << uiWeights.building
                               << "water=" << uiWeights.water
                               << "road=" << uiWeights.road
                               << "=> wDev=" << wDev
                               << "wSig=" << wSig;
    
    // Separation constraints
    double minSeparation = _config.minSeparationMeters;
    // Calculate original distances for ratio checking
    double origDistToNext = _haversineDistance(current, next);
    double origDistToPrev = prev.isValid() ? _haversineDistance(current, prev) : 0.0;
    
    qCDebug(TowerOptimizerLog) << "Starting A* optimization for waypoint at"
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
    start->f = start->g + wDev * start->dev + start->h - wSig * start->sig
             + _calculateEnvironmentCostAt(0, 0, current);
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
            qCDebug(TowerOptimizerLog) << "Early termination: signal improved by"
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
            
            // 检查距离比例（放宽到40%-200%以允许更远的绕行路径）
            double nextRatio = distToNext / origDistToNext;
            if (nextRatio < 0.4 || nextRatio > 2.0) {
                continue;  // 距离比例超出范围，跳过
            }
            
            // 如果有prev waypoint，也检查
            if (prev.isValid() && origDistToPrev > 0) {
                double distToPrev = _haversineDistance(candidateCoord, prev);
                if (distToPrev < minSeparation) {
                    continue;  // 太近，跳过
                }
                
                double prevRatio = distToPrev / origDistToPrev;
                if (prevRatio < 0.4 || prevRatio > 2.0) {
                    continue;  // 距离比例超出范围，跳过
                }
            }
            
            // Calculate costs
            double stepCost = (dx[dir] == 0 || dy[dir] == 0) ? cellSize : cellSize * 1.41421356;
            double g = currentNode->g + stepCost;
            double dev = _calculateDeviationCost(ngx, ngy, cellSize);
            double sig = _calculateSignalAt(ngx, ngy, current);
            double h = _calculateHeuristic(ngx, ngy, current, next);

            double f = g + wDev * dev + h - wSig * sig
                     + _calculateEnvironmentCostAt(ngx, ngy, current);
            
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
    
    qCDebug(TowerOptimizerLog) << "A* completed after" << iterations << "iterations";
    qCDebug(TowerOptimizerLog) << "[A*] DONE iterations=" << iterations
                               << "best gx,gy=" << bestSoFar->gx << bestSoFar->gy
                               << "best f=" << bestSoFar->f
                               << "best sig=" << bestSoFar->sig
                               << "best dev=" << bestSoFar->dev;
    // Get best coordinate
    QGeoCoordinate result = _gridToCoord(bestSoFar->gx, bestSoFar->gy, current);
    result.setAltitude(altitude);
    
    // Cleanup
    qDeleteAll(allNodes);
    qCDebug(TowerOptimizerLog) << "[A*] RESULT coord=" << result;
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
                                                      double metersPerDegLon) const
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
                                            double altitude) const
{
    double lat = lat0 + (y / metersPerDegLat);
    double lon = lon0 + (x / metersPerDegLon);
    return QGeoCoordinate(lat, lon, altitude);
}

int TowerOptimizer::_findNearestNode(const QVector<RRTNode>& nodes, double x, double y) const
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
    const UiWeights uiWeights = _currentUiWeights();
    
    double minSeparation = _config.minSeparationMeters;
    QVector<QGeoCoordinate> corridorAnchors;
    corridorAnchors.append(current);
    corridorAnchors.append(next);
    if (prev.isValid()) {
        corridorAnchors.append(prev);
    }
    _updateActiveFeaturesForCorridor(corridorAnchors, searchRadiusMeters + 320.0);
    
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
    start.f = start.g + (wDev * uiWeights.distance) * start.dev + start.h
            - (wSig * uiWeights.signal) * start.sig + _calculateEnvironmentCost(current);
    nodes.append(start);
    
    RRTNode best = start;
    
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
        if (nextRatio < 0.4 || nextRatio > 2.0) {
            continue;
        }
        
        if (prev.isValid() && origDistToPrev > 0) {
            double distToPrev = _haversineDistance(newCoord, prev);
            if (distToPrev < minSeparation) {
                continue;
            }
            
            double prevRatio = distToPrev / origDistToPrev;
            if (prevRatio < 0.4 || prevRatio > 2.0) {
                continue;
            }
        }
        
        // Calculate costs
        double dev = _haversineDistance(newCoord, current);
        double sig = calculateSignalStrength(newCoord);
        double h = distToNext;
        double g = nearest.g + step;
        double f = g + (wDev * uiWeights.distance) * dev + h
                 - (wSig * uiWeights.signal) * sig + _calculateEnvironmentCost(newCoord);
        
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
        
        // Update best node - 优先考虑综合代价f（包含信号强度），而不是只看距离
        // f = g + wDev*dev + h - wSig*sig，所以f越小越好（信号越强，f越小）
        if (f < best.f) {
            best = newNode;
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

QVector<QGeoCoordinate> TowerOptimizer::_optimizePathAStarNew(const QVector<QGeoCoordinate>& originalPath, double altitude)
{
    writeTowerOptimizeLog(QString("Starting A* New optimization with %1 waypoints").arg(originalPath.size()));

    if (originalPath.size() < 2) {
        writeTowerOptimizeLog("Path too short for optimization");
        return originalPath;
    }

    // 使用原始路径的起点，确保它不被移动
    QGeoCoordinate start = originalPath.first();

    // 如果高度无效，使用起点的高度
    if (qIsNaN(altitude) || altitude <= 0) {
        altitude = start.altitude();
        if (qIsNaN(altitude) || altitude <= 0) {
            altitude = 100.0; // 默认高度
        }
    }

    writeTowerOptimizeLog(QString("Multi-stage A* New search starting from %1 altitude: %2").arg(start.toString()).arg(altitude));
    writeTowerOptimizeLog(QString("Will visit %1 waypoints in sequence").arg(originalPath.size()));

    // 检查每个路径点的collision并打印
    for (int i = 0; i < originalPath.size(); ++i) {
        const QGeoCoordinate& pt = originalPath[i];
        const bool collision = checkCollision(pt, altitude);

        if (!collision) {
            writeTowerOptimizeLog(QString("Path waypoint %1 is collision free.").arg(i));
        } else {
            writeTowerOptimizeLog(QString("Path waypoint %1 collides with active constraints").arg(i));
        }
    }

    // 逐步通过原始路径的每个点
    QVector<QGeoCoordinate> globalPath;
    QGeoCoordinate currentStart = start;

    for (int i = 1; i < originalPath.size(); i++) {
        QGeoCoordinate currentGoal = originalPath[i];

        writeTowerOptimizeLog(QString("Stage %1: searching from %2 to %3").arg(i).arg(currentStart.toString()).arg(currentGoal.toString()));

        // 使用A*算法规划从当前起点到当前目标的路径
        QVector<QGeoCoordinate> stagePath = _planPathAStarNew(currentStart, currentGoal, altitude, _config.maxWaypoints);

        if (stagePath.size() > 0) {
            // 将阶段路径添加到总路径中（跳过第一个点，避免重复）
            for (int j = (i == 1 ? 0 : 1); j < stagePath.size(); j++) {
                globalPath.append(stagePath[j]);
            }

            // 更新下一个阶段的起点为当前目标
            currentStart = currentGoal;

            writeTowerOptimizeLog(QString("Stage %1 completed with %2 points").arg(i).arg(stagePath.size()));
        } else {
            writeTowerOptimizeLog(QString("Stage %1 failed, using direct path").arg(i));
            // 如果A*失败，使用直接路径
            if (i == 1) {
                globalPath.append(currentStart);
            }
            globalPath.append(currentGoal);
            currentStart = currentGoal;
        }
    }

    if (globalPath.size() > 0) {
        // 确保起点与原始路径完全一致
        globalPath[0] = start;  // 强制使用原始起点

        writeTowerOptimizeLog(QString("Multi-stage A* New optimization completed. Path length: %1 waypoints").arg(globalPath.size()));
        writeTowerOptimizeLog(QString("Final path goes through %1 original waypoints").arg(originalPath.size()));

        QString pathLog = "Final path coordinates:";
        for (int i = 0; i < globalPath.size(); ++i) {
            qCDebug(TowerOptimizerLog) << QString("%1: %2").arg(i).arg(globalPath[i].toString());
        }
        writeTowerOptimizeLog(pathLog);
        return globalPath;
    } else {
        writeTowerOptimizeLog("Multi-stage A* New optimization failed, returning original path");
        return originalPath;
    }
}

QVector<QGeoCoordinate> TowerOptimizer::_planPathAStarNew(const QGeoCoordinate& start, const QGeoCoordinate& goal, 
                                                          double altitude, int maxSteps)
{
    Q_UNUSED(maxSteps);
    writeTowerOptimizeLog(QString("Start: %1").arg(start.toString()));
    writeTowerOptimizeLog(QString("Goal: %2").arg(goal.toString()));
    writeTowerOptimizeLog(QString("Altitude: %3").arg(altitude));
    writeTowerOptimizeLog(QString("Max steps: %4").arg(maxSteps));

    QVector<QGeoCoordinate> corridorAnchors;
    corridorAnchors.append(start);
    corridorAnchors.append(goal);
    _updateActiveFeaturesForCorridor(corridorAnchors, qMax(_config.maxStepSizeMeters * 2.0, 450.0));
    const UiWeights uiWeights = _currentUiWeights();
    const double signalCostScale = qMax(400.0, _config.weightSignal * 0.08);
    
    // 简单的节点结构
    struct Node {
        QGeoCoordinate coord;
        double cost;  // 总成本
        int parent;   // 父节点索引
        int index;    // 节点索引
        
        Node() : cost(0), parent(-1) {}
        bool operator>(const Node& other) const { return cost > other.cost; }
    };
    
    QVector<Node> nodes;
    std::priority_queue<Node, std::vector<Node>, std::greater<Node>> openSet;
    QSet<QString> visited;
    
    // 添加起点
    Node startNode;
    startNode.coord = start;
    startNode.cost = 0;
    startNode.parent = -1;
    startNode.index = 0;
    nodes.append(startNode);
    openSet.push(startNode);
    
    int iterations = 0;
    bool goalReached = false;
    int goalNodeIdx = -1;
    
    writeTowerOptimizeLog(QString("Max iterations: %1").arg(_config.astarNewMaxIterations));
    
    while (!openSet.empty() && iterations < _config.astarNewMaxIterations) {
        iterations++;
        
        if (iterations % 50 == 0) {  // 减少日志频率
            writeTowerOptimizeLog(QString("Iteration %1: openSet size: %2, nodes: %3").arg(iterations).arg(openSet.size()).arg(nodes.size()));
        }
        
        Node current = openSet.top();
        writeTowerOptimizeLog(QString("Current node: lat=%1, lon=%2, cost=%3, parent=%4, index=%5")
                              .arg(current.coord.latitude(), 0, 'f', 8)
                              .arg(current.coord.longitude(), 0, 'f', 8)
                              .arg(current.cost)
                              .arg(current.parent)
                              .arg(current.index));

        openSet.pop();
        
        QString currentKey = QString("%1,%2").arg(current.coord.latitude(), 0, 'f', 6)
                                            .arg(current.coord.longitude(), 0, 'f', 6);
        
        if (visited.contains(currentKey)) {
            continue;
        }
        visited.insert(currentKey);
        
        // 检查是否到达目标（使用更宽松的条件）
        double distanceToGoal = _haversineDistance(current.coord, goal);
        if (distanceToGoal < _config.stepSizeMeters * 1.0
                && !_checkWeatherSegmentCollision(current.coord, goal)) {  // 减少到3倍步长
            writeTowerOptimizeLog(QString("Reached goal in %1 iterations, distance: %2 m").arg(iterations).arg(distanceToGoal));
            writeTowerOptimizeLog(QString("Goal node: lat=%1, lon=%2")
                              .arg(goal.latitude(), 0, 'f', 8)
                              .arg(goal.longitude(), 0, 'f', 8));
            goalReached = true;
            goalNodeIdx = current.index;
            break;
        }
        
        // 生成候选点 - 优先向目标方向搜索，但允许明显的侧向绕行
        double goalDirection = current.coord.azimuthTo(goal);
        int validCandidates = 0;

        // 城市级绕障需要明显更细的步长；否则 300-500m 航段会直接跨过整片建筑/禁飞区。
        const double effectiveMinStep = qMax(18.0, qMin(_config.minStepSizeMeters, 25.0));
        double stepSize = distanceToGoal / 5.0;

        if (stepSize < effectiveMinStep) {
            stepSize = effectiveMinStep;
        } else if (stepSize > _config.maxStepSizeMeters) {
            stepSize = _config.maxStepSizeMeters;
        }

        // 生成候选点：前向、侧向、反向回旋都允许，避免卡死在障碍前方。
        QVector<double> directions;
        const QVector<double> directionOffsets = {
            0.0,
            25.0, -25.0,
            50.0, -50.0,
            75.0, -75.0,
            100.0, -100.0,
            125.0, -125.0,
            150.0, -150.0,
            175.0, -175.0
        };
        for (double offset : directionOffsets) {
            directions.append(goalDirection + offset);
        }
        
        for (double angle : directions) {
            if (angle >= 360.0) angle -= 360.0;
            if (angle < 0.0) angle += 360.0;
            
            QGeoCoordinate candidate = current.coord.atDistanceAndAzimuth(stepSize, angle);
            candidate.setAltitude(altitude);
            
            QString candidateKey = QString("%1,%2").arg(candidate.latitude(), 0, 'f', 6)
                                                  .arg(candidate.longitude(), 0, 'f', 6);
            
            if (visited.contains(candidateKey)) {
                continue;
            }
            
            bool hasCollision = false;

            if (_config.weatherCollisionCheck) {
                for (const TowerInfo& sensor : _sensors) {
                    if (_isSuitableSensor(sensor) || _isWarningSensor(sensor)) {
                        continue;
                    }

                    const double noFlyRadius = _noFlyRadiusWithBuffer(sensor, _config.collisionBufferMeters);
                    if (noFlyRadius <= 0.0) {
                        continue;
                    }

                    if (_haversineDistance(candidate, sensor.coordinate) < noFlyRadius) {
                        hasCollision = true;
                        break;
                    }
                }
            }

            if (!hasCollision && _checkWeatherSegmentCollision(current.coord, candidate)) {
                hasCollision = true;
            }

            if (!hasCollision && altitude > 0.0 && checkTerrainCollision(candidate, altitude)) {
                hasCollision = true;
            }

            if (hasCollision) {
                continue;
            }
            
            // 计算成本：距离 + 信号强度 + 启发式（到目标的距离）
            double distanceCost = _haversineDistance(current.coord, candidate) * uiWeights.distance;
            double signalCost = -calculateSignalStrength(candidate) * signalCostScale * uiWeights.signal;
            double heuristicCost = _haversineDistance(candidate, goal) * 2;  // 启发式成本
            double environmentCost = _calculateEnvironmentCost(candidate);
            double totalCost = current.cost + distanceCost + signalCost + heuristicCost + environmentCost;
            
            // 创建新节点
            Node newNode;
            newNode.coord = candidate;
            newNode.cost = totalCost;
            newNode.parent = current.index;
            newNode.index = nodes.size();
            nodes.append(newNode);
            openSet.push(newNode);
            validCandidates++;
        }
        
        if (iterations % 50 == 0) {
            // writeTowerOptimizeLog(QString("Found %1 valid candidates").arg(validCandidates));
        }
    }
    
    writeTowerOptimizeLog(QString("A* New search completed. Total iterations: %1, nodes: %2, goalReached: %3").arg(iterations).arg(nodes.size()).arg(goalReached));
    
    // 构建路径
    QVector<QGeoCoordinate> path;
    if (goalReached && goalNodeIdx >= 0) {
        writeTowerOptimizeLog("Building path from goal node");
        
        // 从目标节点回溯到起点
        QVector<int> pathIndices;
        int currentIdx = goalNodeIdx;
        
        while (currentIdx >= 0 && currentIdx < nodes.size()) {
            pathIndices.prepend(currentIdx);
            currentIdx = nodes[currentIdx].parent;
        }
        
        // 构建坐标路径
        for (int idx : pathIndices) {
            path.append(nodes[idx].coord);
            writeTowerOptimizeLog(QString("Path node: lat=%1, lon=%2")
                              .arg(nodes[idx].coord.latitude(), 0, 'f', 8)
                              .arg(nodes[idx].coord.longitude(), 0, 'f', 8));
        }
        path.append(goal);
        
        writeTowerOptimizeLog(QString("Path reconstruction completed. Final path length: %1").arg(path.size()));
    } else {
        writeTowerOptimizeLog("Goal not reached, creating simple path");
        
        // 创建简单的直线路径
        path.append(start);
        path.append(goal);
    }
    
    writeTowerOptimizeLog(QString("A* New path planning completed. Path length: %1 iterations: %2 goalReached: %3").arg(path.size()).arg(iterations).arg(goalReached));
    
    return path;
}

QVector<QGeoCoordinate> TowerOptimizer::optimizePathAStarNew(const QVector<QGeoCoordinate>& originalPath, double altitude)
{
    writeTowerOptimizeLog(QString("Public method: optimizePathAStarNew called with %1 waypoints, altitude: %2")
                          .arg(originalPath.size()).arg(altitude));

    return _optimizePathAStarNew(originalPath, altitude);
}
