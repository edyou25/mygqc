# 航路优化评估要素：开源数据清单与“信号文件融合”落地方案

> 更新时间：2026-03-09  
> 适用范围：当前 `TowerOptimize` / `PathOptimization` 方案（QGC 分支）

## 1) 先说清楚当前实现状态（避免对外口径失真）

当前代码中，通信“信号强度”主逻辑仍是**基于塔点距离衰减模型**，而不是直接读取你提供的 `sig-ps.csv` / `interpolated_grid_fullcube.csv`：

- C++ 信号计算函数：[`TowerOptimizer.cc`](/home/hw/qgroundcontrol/src/PathOptimization/TowerOptimizer.cc:297)
- JS 侧 A* 信号函数（同样按塔点距离算）：[`TowerOptimize.js`](/home/hw/qgroundcontrol/src/PlanView/TowerOptimize.js:252)
- 塔点/传感器来源：[`resources/towers.json`](/home/hw/qgroundcontrol/resources/towers.json:1)
- 目前地形碰撞仍有 TODO（估算高程回退）：[`TowerOptimizer.cc`](/home/hw/qgroundcontrol/src/PathOptimization/TowerOptimizer.cc:374), [`TowerOptimize.js`](/home/hw/qgroundcontrol/src/PlanView/TowerOptimize.js:1360)

你给的信号文件目前是“可用但未接入主评分链路”：

- [`sig-ps.csv`](/home/hw/qgroundcontrol/docs/tower/sig-ps.csv:1)（字段：`latitude, longitude, height, SS-RSRP, SS-RSRQ, SS-SINR`）
- [`interpolated_grid_fullcube.csv`](/home/hw/qgroundcontrol/docs/tower/interpolated_grid_fullcube.csv:1)（含 `评分` 和 `服务等级`）

## 2) 评估要素对应开源数据：哪些可用、地址、许可

| 评估要素 | 推荐开源数据 | 开源地址 | 许可与商用注意 |
|---|---|---|---|
| 道路网络（路线可达性、路径平滑） | OpenStreetMap 道路 `highway=*` | https://planet.openstreetmap.org/ / https://www.openstreetmap.org/copyright | ODbL 1.0，需署名；若发布“改进后的数据库”需遵守 share-alike |
| 建筑物（障碍/风险） | Microsoft Global ML Building Footprints | https://github.com/microsoft/GlobalMLBuildingFootprints | 官方说明为 ODbL，可商用但要遵守 ODbL 要求 |
| 水域/湿地/地表类型（风险权重） | ESA WorldCover | https://esa-worldcover.org/en/data-access | CC BY 4.0，免费、需署名 |
| 地形高程（AGL/爬升约束/地形碰撞） | Copernicus DEM (GLO-30/GLO-90) | https://registry.opendata.aws/copernicus-dem/ | 免费公开，按 Copernicus 许可条款使用 |
| 气象场（风雨能见度等） | NOAA GFS（开放） | https://registry.opendata.aws/noaa-gfs-bdp-pds/ | NOAA NODD 开放；请求署名，禁止暗示 NOAA 背书 |
| 天气 API 快速集成 | Open-Meteo | https://open-meteo.com/en/licence | 数据 CC BY 4.0（需署名）；免费层有非商用限制，商用走付费层 |
| 基站位置/小区库（信号先验） | OpenCelliD | https://opencellid.org/ / https://wiki.opencellid.org/wiki/Database_format | CC BY-SA 4.0；有 token/下载频率限制（每日更新、下载次数限制） |
| 空域限制（低空禁飞） | openAIP（可作补充） | https://www.openaip.net/ | 官方公开信息显示 CC BY-NC 4.0，商业闭环需谨慎 |

## 2.1 逐项映射：当前评估要素里，哪些已经是开源数据

| 评估要素 | 当前实现数据来源 | 当前是否开源 | 可替换/补充开源数据（地址） | 落地说明 |
|---|---|---|---|---|
| 航点序列（任务输入） | 任务规划 UI / mission 文件 | 否（业务数据） | 不适用 | 这是用户任务数据，不属于“开源底图”范畴 |
| 信号先验（塔点吸引） | `resources/towers.json` | 通常否（项目自有） | OpenCelliD（https://opencellid.org/） | 用开源基站库补盲区，仍建议保留项目自有塔站 |
| 信号实测（RSRP/RSRQ/SINR） | `sig-ps.csv` / `interpolated_grid_fullcube.csv` | 取决于采集方授权 | 若需公开替代可用 OpenSignal 类开放研究数据（可得性不稳定） | 你现在这两份更像“私有实测资产”，价值比通用开源更高 |
| 禁飞区（传感器圆形缓冲） | `towers.json` 里的 `sensor/noFlyRadius` | 否（项目规则） | openAIP（https://www.openaip.net/） | openAIP 可做补充，但有非商用许可约束 |
| 地形净空（AGL） | 当前为估算函数（非真实 DEM） | 否 | Copernicus DEM（https://dataspace.copernicus.eu/）、AWS 镜像（https://registry.opendata.aws/copernicus-dem/） | 应尽快替换为真实 DEM 查询，避免“估算地形”风险 |
| 障碍物（建筑） | 当前未接入 | - | OSM 建筑 + Microsoft Building Footprints | 可转栅格障碍惩罚，提升城市低空路径可靠性 |
| 地表类型（水面/林地） | 当前未接入 | - | ESA WorldCover（https://esa-worldcover.org/en/data-access） | 可做风险权重层，不建议做硬约束 |
| 天气场（风/降雨） | 当前主要用 sensor 禁飞近似 | 部分否 | NOAA GFS（https://registry.opendata.aws/noaa-gfs-bdp-pds/）/ Open-Meteo（https://open-meteo.com/en/licence） | 建议区分“硬禁飞”与“软风险加权” |
| 权重参数（wDev/wSig 等） | `TowerOptimize_config.json` + UI 滑块 | 否（项目配置） | 不适用 | 参数属于算法策略，不是外部数据 |

## 3) 你现在最需要的“对外口径”（不虚假，但专业）

不建议说“我们已经用实测信号栅格做了主优化”，如果当前版本没有完成。  
建议口径：

1. 当前版：  
   “系统采用通信设施先验与传播衰减模型评估链路质量，并结合禁飞区与地形约束进行航路优化。”
2. 升级版（接入后）：  
   “系统在塔站先验基础上，融合实测/插值信号栅格（RSRP/RSRQ/SINR）进行多目标优化，动态平衡链路质量与飞行安全。”

## 4) 如果真要用信号文件：怎么融合到算法里（可落地）

## 4.1 数据层（Signal Field）

目标：把“散点或体素信号”变成可查询的 `signal(x,y,z)`。

1. 统一坐标与高度基准：  
   `lat/lon + altitude` 一律转换到同一垂直基准（建议 AMSL），避免混用相对高。
2. 指标清洗：  
   建议先过滤异常值，例如：`RSRP[-140,-40]`, `RSRQ[-30,-3]`, `SINR[-20,35]`。
3. 建立查询结构：  
   `sig-ps.csv` 用 3D KD-Tree/体素哈希；`interpolated_grid_fullcube.csv` 直接用规则网格 + 三线性插值。
4. 质量分数定义（建议）：
   - `n_rsrp = clamp((RSRP + 120) / 60, 0, 1)`
   - `n_rsrq = clamp((RSRQ + 20) / 17, 0, 1)`
   - `n_sinr = clamp((SINR + 10) / 30, 0, 1)`
   - `S_meas = 0.5*n_rsrp + 0.2*n_rsrq + 0.3*n_sinr`

## 4.2 融合层（先验 + 实测）

不要一次性替换，建议混合：

- `S_tower`：现有塔点衰减模型（已在跑）
- `S_meas`：信号文件查询值
- `conf`：实测置信度（由最近样本距离、样本密度、插值残差决定）
- `S_fused = conf * S_meas + (1 - conf) * S_tower`

这样做的好处：  
有实测覆盖时“用实测主导”；无覆盖/高不确定时“平滑回退到塔点模型”。

### 建议把 `conf` 显式量化（避免“拍脑袋权重”）

- `conf_dist = exp(-d_nearest / k_distance_m)`，`d_nearest` 为最近信号样本距离
- `conf_density = clamp(n_radius / n_ref, 0, 1)`，`n_radius` 为邻域样本数
- `conf_residual = exp(-rmse_interp / k_rmse)`（若有插值残差）
- `conf = clamp(0.5*conf_dist + 0.3*conf_density + 0.2*conf_residual, 0, 1)`

## 4.3 算法层（A* / RRT 的代价函数）

当前 A* 形式（简化）：

`f = g + wDev*deviation + h - wSig*signal + collisionPenalty`

落地改法：

1. 把 `signal` 替换为 `S_fused`。  
2. 增加不确定性惩罚：`+ wUnc * (1 - conf)`。  
3. 保留硬约束不变（最小间距、比例约束、禁飞区、地形净空），避免“为信号而冒险”。

## 4.4 工程改造点（你这份代码里）

1. 新增 `SignalField` 模块（CSV 加载 + 3D 查询）  
   目录建议：`src/PathOptimization/SignalField.{h,cc}`
2. 在 `TowerOptimizer` 中挂接：
   - `loadSignalGridFromCsv(path)`  
   - `calculateSignalStrength()` 内优先查 `SignalField`，再与塔点模型融合  
   参考位置：[`TowerOptimizer.cc`](/home/hw/qgroundcontrol/src/PathOptimization/TowerOptimizer.cc:297)
3. 在 `PathOptimizationManager` 暴露 QML 接口：
   - `Q_INVOKABLE bool loadSignalGrid(QString path)`  
   参考位置：[`PathOptimizationManager.h`](/home/hw/qgroundcontrol/src/PathOptimization/PathOptimizationManager.h:28)
4. 在配置文件补参数：
   - `signalFusion.alpha_default`
   - `signalFusion.k_distance_m`
   - `signalFusion.uncertaintyWeight`
   文件：[`TowerOptimize_config.json`](/home/hw/qgroundcontrol/resources/TowerOptimize_config.json:1)

## 4.5 两份信号文件分别怎么用（按你现有文件）

1. `sig-ps.csv`（离散采样点）  
   作为“原始观测层”，用 3D KD-Tree 做近邻查询；优点是保真，缺点是局部稀疏。
2. `interpolated_grid_fullcube.csv`（规则网格）  
   作为“连续场层”，按 `grid_x/grid_y/grid_z` 构建 3D 数组并三线性插值；优点是查询快、覆盖连续。
3. 查询优先级（建议）  
   先查网格层（快）；若局部置信度低或网格缺失，再回退离散采样点层；最后回退 `S_tower`。
4. `评分` 字段的使用建议  
   若 `评分` 已是可信综合指标，可直接归一化得到 `S_meas`；否则用 RSRP/RSRQ/SINR 重新计算 `S_meas` 并把 `评分` 作为校验项。

## 4.6 代价函数改造建议（可直接给开发）

建议把 A* / RRT 的信号项统一改成：

- `SignalBenefit = wSig * S_fused`
- `UncertaintyCost = wUnc * (1 - conf)`
- `f = g + wDev*dev + h - SignalBenefit + collisionPenalty + UncertaintyCost`

其中 `wUnc` 建议从 `0.1 * wSig` 起步调参。

## 4.7 验证指标（建议对外可展示）

1. 链路质量：平均 `RSRP/RSRQ/SINR` 或 `S_fused` 提升幅度  
2. 安全性：禁飞区穿越次数、地形净空违例次数  
3. 可执行性：路径长度变化、航时变化、点间距违例数  
4. 稳定性：不同天气/时段重复规划的一致性

## 5) 对外口径建议（可直接复述）

### 5.1 当前可说（真实且专业）

“系统采用通信设施先验模型评估链路质量，并结合禁飞区约束与地形净空约束进行航路优化；在信号高置信覆盖区域支持实测信号融合增强。”

### 5.2 不建议说

- “我们完全用实测信号驱动主优化”（如果实际上还没全量接入）
- “地形风险是实景 DEM 精确建模”（如果当前仍有估算回退）

## 6) 结论（可直接复述）

1. 你现在这套算法并不弱，但“信号主评分”还是先验塔点模型。  
2. 你已经有可用信号文件（`sig-ps.csv` + `interpolated_grid_fullcube.csv`），完全可以做成“实测融合版”。  
3. 最稳妥做法不是替换，而是“先验 + 实测 + 置信度”的混合评分。  
4. 对外沟通建议强调“分阶段能力”：先验可用、实测融合在工程化接入中或已接入（按事实说）。

---

## 参考来源（开源地址与许可）

- OpenStreetMap 版权与许可（ODbL）：https://www.openstreetmap.org/copyright  
- OSM Planet 下载：https://planet.openstreetmap.org/  
- Microsoft Global Building Footprints（ODbL）：https://github.com/microsoft/GlobalMLBuildingFootprints  
- ESA WorldCover 数据访问与许可（CC BY 4.0）：https://esa-worldcover.org/en/data-access  
- Copernicus DEM（AWS Registry）：https://registry.opendata.aws/copernicus-dem/  
- NOAA GFS（AWS Registry，开放使用说明）：https://registry.opendata.aws/noaa-gfs-bdp-pds/  
- Open-Meteo 许可（CC BY 4.0）：https://open-meteo.com/en/licence  
- OpenCelliD 下载与数据格式：https://opencellid.org/downloads / https://wiki.opencellid.org/wiki/Database_format  
- OpenCelliD 署名许可（CC BY-SA 4.0）：https://wiki.opencellid.org/wiki/Attribution  
- openAIP 主页（许可说明见站内 Data License）：https://www.openaip.net/
