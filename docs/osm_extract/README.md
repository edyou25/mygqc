# OSM 区域数据提取结果

## 区域边界（按输入点顺序）

1. `23.1076536, 113.2501964`
2. `23.0667990, 113.2490714`
3. `23.0656005, 113.3211486`
4. `23.1072648, 113.3208514`

## 生成结果

- `greenlands.json`：绿地（QGC 格式：`[{gid, path:[[lat,lon], ...]}]`）
- `waters.json`：水体（QGC 格式：`[{wid, path:[[lat,lon], ...]}]`）
- `buildings.json`：建筑（QGC 格式：`[{bdid, path:[[lat,lon], ...], heightMeters?, minHeightMeters?, levels?}]`）
- `roads.geojson`：路网（GeoJSON，`FeatureCollection + LineString`）
- `qgc_settings_snippet.ini`：可直接粘贴到 `QGroundControl.ini` 的配置片段（绿地/水体/建筑）
- `summary.json`：本次提取统计

## 接入到当前项目

### 1) 绿地/水体/建筑

将 `qgc_settings_snippet.ini` 对应内容，粘贴到：

- `~/.config/QGroundControl.org/QGroundControl.ini`

对应分组：

- `[Greenland]` 的 `greenlandsJson` / `nextId`
- `[Water]` 的 `watersJson` / `nextId`
- `[BuildingDense]` 的 `buildingsJson` / `nextId`

### 2) 路网

本项目默认从资源 `qrc:/roads/export.geojson` 读取，因此需要：

1. 用 `docs/osm_extract/roads.geojson` 替换项目根目录的 `export.geojson`
2. 重新编译 QGC

示例：

```bash
cp docs/osm_extract/roads.geojson export.geojson
cmake --build build -j"$(nproc)"
```

## 复用脚本（换区域可重复执行）

```bash
python3 tools/extract_osm_region.py \
  --points "23.1076536,113.2501964;23.0667990,113.2490714;23.0656005,113.3211486;23.1072648,113.3208514" \
  --out-dir docs/osm_extract
```

如果 OSM/Overture 原始数据里带有 `height`、`min_height`、`building:levels`、`num_floors` 等字段，
脚本会自动归一化成 `heightMeters` / `minHeightMeters` / `levels` 并写进 `buildings.json`。
