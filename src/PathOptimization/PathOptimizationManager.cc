/****************************************************************************
 *
 * (c) 2009-2024 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

#include "PathOptimizationManager.h"
#include <QtGlobal>
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

    


void PathOptimizationManager::setDistanceWeight(double w)
{
    // qFuzzyCompare：用于比较浮点数，避免 1.0000000 和 1.0000001 这种误差导致“无意义重复更新”
    if (qFuzzyCompare(_distanceWeight, w)) {
        return;
    }

    // 更新成员变量（真正存储权重的地方）
    _distanceWeight = w;

    // 发出信号：告诉 QML/其他监听者“distanceWeight 变了”
    emit distanceWeightChanged();

    // 如果你希望一调权重就立即重新规划，可以在这里触发重算
    // _towerOptimizer.recompute();  // 示例：具体调用看你同学的算法接口
}

void PathOptimizationManager::setSignalWeight(double w)
{
    if (qFuzzyCompare(_signalWeight, w)) {
        return;
    }

    _signalWeight = w;
    emit signalWeightChanged();

    // 同上：必要时触发重算
}
