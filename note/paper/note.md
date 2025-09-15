好的，已根据您的要求修改表格格式，将被引量以括号形式标注在论文标题后面。

### 无人机航迹点优化研究发展时间线

| 时间阶段 | 核心焦点与演进 | 代表性研究 | 关键技术特点 |
| :--- | :--- | :--- | :--- |
| **2009-2015**<br>**萌芽与探索期** | **基础路径规划**<br>关注“如何从A点飞到B点”的基本问题，核心是避障和几何路径生成，环境建模相对简单。 | 1. Path planning of unmanned aerial vehicles using B-splines and particle swarm optimization (2009, 被引 173)<br>2. Comparison of parallel genetic algorithm and particle swarm optimization for real-time UAV path planning (2012, 被引 1252)<br>3. UAV path planning for passive emitter localization (2012, 被引 220)<br>4. Path planning for UAVs for maximum information collection (2013, 被引 149)<br>5. Path planning for single unmanned aerial vehicle by separately evolving waypoints (2015, 被引 154) | **传统优化算法**为主：<br>• **元启发式算法**（粒子群优化PSO、遗传算法GA）<br>• **采样搜索算法**（A*, RRT）<br>• **B样条**用于路径平滑 |
| **2017-2019**<br>**通信驱动兴起期** | **通信感知轨迹优化**<br>研究重心发生重大转变，从纯几何路径转向**无人机通信**。轨迹优化成为提升通信性能（如能耗、速率）的核心手段。 | 1. Energy-efficient UAV communication with trajectory optimization (2017, 被引 2339)<br>2. Mobile edge computing via a UAV-mounted cloudlet: Optimization of bit allocation and path planning (2017, 被引 908)<br>3. Cellular-enabled UAV communication: A connectivity-constrained trajectory optimization perspective (2018, 被引 452)<br>4. Energy efficient UAV communication with energy harvesting (2019, 被引 271)<br>5. Online UAV path planning for joint detection and tracking of multiple radio-tagged objects (2019, 被引 97) | **联合优化**成为核心范式：<br>• **轨迹 + 通信资源**（功率、带宽分配）联合优化<br>• **凸优化**、**连续凸近似(SCA)** 等**数学规划方法**成为主流 |
| **2020-2022**<br>**深化与多元化期** | **多目标、多机、复杂场景**<br>研究问题变得更加复杂和实际，强调多目标权衡、多无人机协同、三维复杂环境以及与人工智能的融合。 | 1. Multi-objective drone path planning for search and rescue with quality-of-service requirements (2020, 被引 126)<br>2. Radio map-based 3D path planning for cellular-connected UAV (2020, 被引 214)<br>3. 3D trajectory optimization for energy-efficient UAV communication: A control design perspective (2021, 被引 131)<br>4. Path planning for cellular-connected UAV: A DRL solution with quantum-inspired experience replay (2022, 被引 102)<br>5. Comparison between A* and RRT algorithms for 3D UAV path planning (2022, 被引 171) | **技术多元化**：<br>• **多目标优化**（MOEA）<br>• **深度强化学习（DRL）** 解决复杂问题<br>• **3D路径规划**成为标配<br>• **传统算法**在复杂场景下的新应用 |
| **2022-2024**<br>**(当前) 前沿与展望期** | **智能协同与实时动态**<br>聚焦于**多智能体协同**、**在线实时规划**、以及与**更前沿技术**（如RIS、MEC）的深度融合，应对高度动态的环境。 | 1. Drone swarm path planning for mobile edge computing in industrial internet of things (2022, 被引 60)<br>2. Path planning for the dynamic UAV-aided wireless systems using monte carlo tree search (2022, 被引 36)<br>3. Distributed stochastic algorithm based on enhanced genetic algorithm for path planning of multi-UAV cooperative area search (2023, 被引 84)<br>4. Multi-UAV coverage path planning: A distributed online cooperation method (2023, 被引 73)<br>5. Dynamic multi-UAV path planning for multi-target search and connectivity (2024, 被引 21) | **分布式与在线算法**：<br>• **分布式协同决策**<br>• **在线/实时规划**应对动态变化<br>• **混合模型**（如DRL+元启发式）<br>• **跨层优化**（路径+通信+计算） |

---

### 核心研究趋势总结

1.  **研究目标演进**：
    *   **从“连通性”到“任务效能”**：早期关注避障和最短路径，现在更注重在完成特定任务（如搜索救援、边缘计算）时的整体性能优化。
    *   **从“单目标”到“多目标”**：从最小化能耗或时间，发展为同时权衡能耗、时间、通信质量、覆盖完整性等多个目标。

2.  **技术方法演进**：
    *   **从“传统优化”到“人工智能”**：虽然PSO、GA等元启发式算法至今仍在广泛应用，但**数学规划方法**（用于通信轨迹优化）和**深度强化学习（DRL）**（用于复杂动态环境决策）已成为新的研究热点。
    *   **从“集中式”到“分布式”**：为适应多无人机集群（Swarm）应用，研究重点转向分布式、去中心化的在线协同规划算法。

3.  **应用场景演进**：
    *   **从“理想模型”到“真实环境”**：考虑了3D城市环境、障碍物、无线电地图、动态目标等更复杂的真实世界约束。
    *   **从“孤立平台”到“系统融合”**：无人机不再是独立的飞行器，而是与**移动边缘计算（MEC）**、**物联网（IoT）**、**智能反射面（RIS）**、**5G/6G蜂窝网络**深度融合的空中节点，路径规划需与通信、计算资源进行**联合优化**。