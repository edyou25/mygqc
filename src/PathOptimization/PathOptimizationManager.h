/****************************************************************************
 *
 * (c) 2009-2024 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

#pragma once

#include "TowerOptimizer.h"
#include <QObject>

/// Singleton manager for path optimization, accessible from QML
class PathOptimizationManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(TowerOptimizer* towerOptimizer READ towerOptimizer CONSTANT)
    Q_PROPERTY(double distanceWeight READ distanceWeight WRITE setDistanceWeight NOTIFY distanceWeightChanged)
    Q_PROPERTY(double signalWeight   READ signalWeight   WRITE setSignalWeight   NOTIFY signalWeightChanged)
    Q_PROPERTY(double weatherWeight READ weatherWeight WRITE setWeatherWeight NOTIFY weatherWeightChanged)
    Q_PROPERTY(double greenlandWeight READ greenlandWeight WRITE setGreenlandWeight NOTIFY greenlandWeightChanged)
    Q_PROPERTY(double buildingWeight READ buildingWeight WRITE setBuildingWeight NOTIFY buildingWeightChanged)
    Q_PROPERTY(double waterWeight READ waterWeight WRITE setWaterWeight NOTIFY waterWeightChanged)
    Q_PROPERTY(double roadWeight READ roadWeight WRITE setRoadWeight NOTIFY roadWeightChanged)
public:
    static PathOptimizationManager* instance();
    
    TowerOptimizer* towerOptimizer() { return &_towerOptimizer; }
    
    // Convenience methods for QML
    Q_INVOKABLE bool loadDefaultTowers();
    Q_INVOKABLE bool loadDefaultConfig();
    Q_INVOKABLE bool loadDefaultSignalGrid();
    double distanceWeight() const { return _distanceWeight; }
    double signalWeight() const { return _signalWeight; }
    double weatherWeight() const { return _weatherWeight; }
    double greenlandWeight() const { return _greenlandWeight; }
    double buildingWeight() const { return _buildingWeight; }
    double waterWeight() const { return _waterWeight; }
    double roadWeight() const { return _roadWeight; }

public slots:
    void setDistanceWeight(double w);
    void setSignalWeight(double w);
    void setWeatherWeight(double w);
    void setGreenlandWeight(double w);
    void setBuildingWeight(double w);
    void setWaterWeight(double w);
    void setRoadWeight(double w);

signals:
    void distanceWeightChanged();
    void signalWeightChanged();
    void weatherWeightChanged();
    void greenlandWeightChanged();
    void buildingWeightChanged();
    void waterWeightChanged();
    void roadWeightChanged();

private:
    explicit PathOptimizationManager(QObject* parent = nullptr);
    ~PathOptimizationManager() override = default;
    
    TowerOptimizer _towerOptimizer;
    
    static PathOptimizationManager* _instance;
    double _distanceWeight = 0.5;
    double _signalWeight   = 0.5;
    double _weatherWeight  = 0.5;
    double _greenlandWeight = 0.5;
    double _buildingWeight = 0.5;
    double _waterWeight    = 0.5;
    double _roadWeight     = 0.5;
};
