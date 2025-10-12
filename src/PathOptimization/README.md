# Path Optimization Module

路径优化模块 - 将原本在JavaScript中的优化算法移至C++后端

## 架构设计

### C++后端
- `TowerOptimizer`: 核心优化算法类
  - A*路径搜索
  - RRT随机树搜索
  - 信号强度计算
  - 碰撞检测（天气禁飞区 + 地形）

- `PathOptimizationManager`: QML单例管理器
  - 暴露TowerOptimizer给QML
  - 加载配置和数据

### QML前端
- `TowerOptimize.js`: 简化为QML桥接层
  - 调用C++后端API
  - 处理QML特定逻辑

## 优势

1. **性能提升**: C++编译代码执行速度更快
2. **内存管理**: 更好的内存控制和优化
3. **地形集成**: 可以直接调用TerrainQuery C++ API
4. **类型安全**: 编译时类型检查
5. **代码复用**: C++代码可以在其他模块中复用

## 使用方法

### 从QML调用

```qml
import QGroundControl 1.0

// 获取单例
property var pathOptManager: PathOptimizationManager

// 加载配置
pathOptManager.loadDefaultTowers()
pathOptManager.loadDefaultConfig()

// 执行优化
pathOptManager.towerOptimizer.optimizeMissionAStar(missionController)

// 检查碰撞
var hasCollision = pathOptManager.towerOptimizer.checkCollision(coordinate, altitude)
```

### 从C++调用

```cpp
#include "PathOptimizationManager.h"

PathOptimizationManager* manager = PathOptimizationManager::instance();
TowerOptimizer* optimizer = manager->towerOptimizer();

// 加载数据
optimizer->loadTowersFromJson(":/resources/towers.json");
optimizer->loadConfigFromJson(":/resources/TowerOptimize_config.json");

// 计算信号强度
double signal = optimizer->calculateSignalStrength(coord);

// 检查碰撞
bool collision = optimizer->checkCollision(coord, altitude);
```

## 待完成

- [ ] 完整实现A*算法（当前只是骨架）
- [ ] 完整实现RRT算法
- [ ] 集成TerrainQuery获取真实地形高度
- [ ] 添加单元测试
- [ ] 性能基准测试

## 文件结构

```
PathOptimization/
├── CMakeLists.txt
├── README.md
├── TowerOptimizer.h          # 优化算法核心
├── TowerOptimizer.cc
├── PathOptimizationManager.h  # QML单例管理器
└── PathOptimizationManager.cc
```

## 配置文件

配置文件位于 `qgc/resources/TowerOptimize_config.json`

主要参数：
- `astar`: A*算法参数
- `rrt`: RRT算法参数  
- `collision`: 碰撞检测参数
- `signalModel`: 信号强度模型参数

