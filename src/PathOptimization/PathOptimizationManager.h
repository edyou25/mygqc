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
public:
    static PathOptimizationManager* instance();
    
    TowerOptimizer* towerOptimizer() { return &_towerOptimizer; }
    
    // Convenience methods for QML
    Q_INVOKABLE bool loadDefaultTowers();
    Q_INVOKABLE bool loadDefaultConfig();
    double distanceWeight() const { return _distanceWeight; }
    double signalWeight() const { return _signalWeight; }

public slots:
    void setDistanceWeight(double w);
    void setSignalWeight(double w);

signals:
    void distanceWeightChanged();
    void signalWeightChanged();

private:
    explicit PathOptimizationManager(QObject* parent = nullptr);
    ~PathOptimizationManager() override = default;
    
    TowerOptimizer _towerOptimizer;
    
    static PathOptimizationManager* _instance;
    double _distanceWeight = 1.0;
    double _signalWeight   = 1.0;
};

