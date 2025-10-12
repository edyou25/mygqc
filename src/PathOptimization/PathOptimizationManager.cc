/****************************************************************************
 *
 * (c) 2009-2024 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

#include "PathOptimizationManager.h"

PathOptimizationManager* PathOptimizationManager::_instance = nullptr;

PathOptimizationManager::PathOptimizationManager(QObject* parent)
    : QObject(parent)
    , _towerOptimizer(this)
{
}

PathOptimizationManager* PathOptimizationManager::instance()
{
    if (!_instance) {
        _instance = new PathOptimizationManager(nullptr);
    }
    return _instance;
}

bool PathOptimizationManager::loadDefaultTowers()
{
    return _towerOptimizer.loadTowersFromJson(":/data/towers.json");
}

bool PathOptimizationManager::loadDefaultConfig()
{
    return _towerOptimizer.loadConfigFromJson(":/resources/TowerOptimize_config.json");
}

