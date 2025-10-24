/****************************************************************************
 *
 * (c) 2009-2020 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

#include "FlightPathSegment.h"
#include "QGC.h"
#include "PathOptimizationManager.h"

QGC_LOGGING_CATEGORY(FlightPathSegmentLog, "FlightPathSegmentLog")

FlightPathSegment::FlightPathSegment(SegmentType segmentType, const QGeoCoordinate& coord1, double amslCoord1Alt, const QGeoCoordinate& coord2, double amslCoord2Alt, bool queryTerrainData, QObject* parent)
    : QObject           (parent)
    , _coord1           (coord1)
    , _coord2           (coord2)
    , _coord1AMSLAlt     (amslCoord1Alt)
    , _coord2AMSLAlt     (amslCoord2Alt)
    , _queryTerrainData (queryTerrainData)
    , _segmentType      (segmentType)
{
    _delayedTerrainPathQueryTimer.setSingleShot(true);
    _delayedTerrainPathQueryTimer.setInterval(200);
    _delayedTerrainPathQueryTimer.callOnTimeout(this, &FlightPathSegment::_sendTerrainPathQuery);
    _updateTotalDistance();

    qCDebug(FlightPathSegmentLog) << this << "new" << coord1 << coord2 << amslCoord1Alt << amslCoord2Alt << _totalDistance;

    _sendTerrainPathQuery();
    _updateWeatherCollision(); // 初始化时检查天气碰撞
}

void FlightPathSegment::setCoordinate1(const QGeoCoordinate &coordinate)
{
    if (_coord1 != coordinate) {
        _coord1 = coordinate;
        emit coordinate1Changed(_coord1);
        _delayedTerrainPathQueryTimer.start();
        _updateTotalDistance();
        _updateWeatherCollision();
    }
}

void FlightPathSegment::setCoordinate2(const QGeoCoordinate &coordinate)
{
    if (_coord2 != coordinate) {
        _coord2 = coordinate;
        emit coordinate2Changed(_coord2);
        _delayedTerrainPathQueryTimer.start();
        _updateTotalDistance();
        _updateWeatherCollision();
    }
}

void FlightPathSegment::setCoord1AMSLAlt(double alt)
{
    if (!QGC::fuzzyCompare(alt, _coord1AMSLAlt)) {
        _coord1AMSLAlt = alt;
        emit coord1AMSLAltChanged();
        _updateTerrainCollision();
        _updateWeatherCollision();
    }
}

void FlightPathSegment::setCoord2AMSLAlt(double alt)
{
    if (!QGC::fuzzyCompare(alt, _coord2AMSLAlt)) {
        _coord2AMSLAlt = alt;
        emit coord2AMSLAltChanged();
        _updateTerrainCollision();
        _updateWeatherCollision();
    }
}

void FlightPathSegment::setSpecialVisual(bool specialVisual)
{
    if (_specialVisual != specialVisual) {
        _specialVisual = specialVisual;
        emit specialVisualChanged(specialVisual);
    }
}

void FlightPathSegment::_sendTerrainPathQuery(void)
{
    if (_queryTerrainData && _coord1.isValid() && _coord2.isValid()) {
        qCDebug(FlightPathSegmentLog) << this << "_sendTerrainPathQuery";
        // Clear any previous query
        if (_currentTerrainPathQuery) {
            // We are already waiting on another query. We don't care about those results any more.
            disconnect(_currentTerrainPathQuery, &TerrainPathQuery::terrainDataReceived, this, &FlightPathSegment::_terrainDataReceived);
            _currentTerrainPathQuery = nullptr;
        }

        // Clear old terrain data
        _amslTerrainHeights.clear();
        _distanceBetween = 0;
        _finalDistanceBetween = 0;
        emit distanceBetweenChanged(0);
        emit finalDistanceBetweenChanged(0);
        emit amslTerrainHeightsChanged();

        _currentTerrainPathQuery = new TerrainPathQuery(true /* autoDelete */);
        connect(_currentTerrainPathQuery, &TerrainPathQuery::terrainDataReceived, this, &FlightPathSegment::_terrainDataReceived);
        _currentTerrainPathQuery->requestData(_coord1, _coord2);
    }
}

void FlightPathSegment::_terrainDataReceived(bool success, const TerrainPathQuery::PathHeightInfo_t& pathHeightInfo)
{
    qCDebug(FlightPathSegmentLog) << this << "_terrainDataReceived" << success << pathHeightInfo.heights.count();
    if (success) {
        if (!QGC::fuzzyCompare(pathHeightInfo.distanceBetween, _distanceBetween)) {
            _distanceBetween = pathHeightInfo.distanceBetween;
            emit distanceBetweenChanged(_distanceBetween);
        }
        if (!QGC::fuzzyCompare(pathHeightInfo.finalDistanceBetween, _finalDistanceBetween)) {
            _finalDistanceBetween = pathHeightInfo.finalDistanceBetween;
            emit finalDistanceBetweenChanged(_finalDistanceBetween);
        }

        _amslTerrainHeights.clear();
        for (const double& amslTerrainHeight: pathHeightInfo.heights) {
            _amslTerrainHeights.append(amslTerrainHeight);
        }
        emit amslTerrainHeightsChanged();
    }

    _currentTerrainPathQuery->deleteLater();
    _currentTerrainPathQuery = nullptr;

    _updateTerrainCollision();
}

void FlightPathSegment::_updateTotalDistance(void)
{
    double newTotalDistance = 0;
    if (_coord1.isValid() && _coord2.isValid()) {
        newTotalDistance = _coord1.distanceTo(_coord2);
    }

    if (!QGC::fuzzyCompare(newTotalDistance, _totalDistance)) {
        _totalDistance = newTotalDistance;
        emit totalDistanceChanged(_totalDistance);
    }
}

void FlightPathSegment::_updateTerrainCollision(void)
{
    bool newTerrainCollision = false;

    if (_segmentType != SegmentTypeTerrainFrame) {
        double slope =      (_coord2AMSLAlt - _coord1AMSLAlt) / _totalDistance;
        double yIntercept = _coord1AMSLAlt;

        double x = 0;
        for (int i=0; i<_amslTerrainHeights.count(); i++) {
            bool ignoreCollision = false;
            if (_segmentType == SegmentTypeTakeoff && x < _collisionIgnoreMeters) {
                ignoreCollision = true;
            } else if (_segmentType == SegmentTypeLand && x > _totalDistance - _collisionIgnoreMeters) {
                ignoreCollision = true;
            }

            if (!ignoreCollision) {
                double y = _amslTerrainHeights[i].value<double>();
                if (y > (slope * x) + yIntercept) {
                    newTerrainCollision = true;
                    break;
                }
            }

            if (i == _amslTerrainHeights.count() - 2) {
                x += _finalDistanceBetween;
            } else {
                x += _distanceBetween;
            }
        }
    }

    qCDebug(FlightPathSegmentLog) << this << "_updateTerrainCollision new:old" << newTerrainCollision << _terrainCollision;

    if (newTerrainCollision != _terrainCollision) {
        _terrainCollision = newTerrainCollision;
        emit terrainCollisionChanged(_terrainCollision);
        _updateHasCollision();
    }
}

void FlightPathSegment::_updateWeatherCollision(void)
{
    bool newWeatherCollision = false;
    
    qCDebug(FlightPathSegmentLog) << this << "_updateWeatherCollision called for path" << _coord1 << "to" << _coord2;
    
    // 检查路径是否穿越天气禁飞区
    // 从PathOptimizationManager获取传感器数据
    
    if (_coord1.isValid() && _coord2.isValid()) {
        // 获取TowerOptimizer实例
        PathOptimizationManager* manager = PathOptimizationManager::instance();
        if (manager) {
            qCDebug(FlightPathSegmentLog) << this << "PathOptimizationManager found, checking weather collision";
            
            // 检查起点是否在禁飞区内
            if (manager->towerOptimizer()->checkWeatherCollision(_coord1)) {
                newWeatherCollision = true;
                qCDebug(FlightPathSegmentLog) << this << "Weather collision at start point" << _coord1;
            }
            
            // 检查终点是否在禁飞区内
            if (!newWeatherCollision && manager->towerOptimizer()->checkWeatherCollision(_coord2)) {
                newWeatherCollision = true;
                qCDebug(FlightPathSegmentLog) << this << "Weather collision at end point" << _coord2;
            }
            
            // 检查路径上的多个点（更密集的采样）
            if (!newWeatherCollision && _totalDistance > 0) {
                double azimuth = _coord1.azimuthTo(_coord2);
                int numSamples = qMax(3, static_cast<int>(_totalDistance / 100.0)); // 每100米一个采样点
                
                qCDebug(FlightPathSegmentLog) << this << "Checking" << numSamples << "sample points along path";
                
                for (int i = 1; i < numSamples; i++) {
                    double distance = (static_cast<double>(i) / numSamples) * _totalDistance;
                    QGeoCoordinate samplePoint = _coord1.atDistanceAndAzimuth(distance, azimuth);
                    if (manager->towerOptimizer()->checkWeatherCollision(samplePoint)) {
                        newWeatherCollision = true;
                        qCDebug(FlightPathSegmentLog) << this << "Weather collision at sample point" << samplePoint << "distance:" << distance;
                        break;
                    }
                }
            }
        } else {
            qCWarning(FlightPathSegmentLog) << "PathOptimizationManager not available for weather collision check";
        }
    } else {
        qCDebug(FlightPathSegmentLog) << this << "Invalid coordinates for weather collision check";
    }
    
    qCDebug(FlightPathSegmentLog) << this << "_updateWeatherCollision result: new=" << newWeatherCollision << "old=" << _weatherCollision;
    
    if (newWeatherCollision != _weatherCollision) {
        _weatherCollision = newWeatherCollision;
        emit weatherCollisionChanged(_weatherCollision);
        _updateHasCollision();
        qCDebug(FlightPathSegmentLog) << this << "Weather collision state changed to" << _weatherCollision;
    }
}

void FlightPathSegment::_updateHasCollision(void)
{
    bool newHasCollision = _terrainCollision || _weatherCollision;
    emit hasCollisionChanged(newHasCollision);
}
