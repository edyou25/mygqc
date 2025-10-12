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
    
public:
    static PathOptimizationManager* instance();
    
    TowerOptimizer* towerOptimizer() { return &_towerOptimizer; }
    
    // Convenience methods for QML
    Q_INVOKABLE bool loadDefaultTowers();
    Q_INVOKABLE bool loadDefaultConfig();
    
private:
    explicit PathOptimizationManager(QObject* parent = nullptr);
    ~PathOptimizationManager() override = default;
    
    TowerOptimizer _towerOptimizer;
    
    static PathOptimizationManager* _instance;
};

