#!/usr/bin/env python3
"""
Enrich an existing QGC building display dataset with height fields while
keeping the current display footprint/count unchanged.

The script assigns source building heights to display polygons by locating
source-building centroids inside the display polygons, then keeps the tallest
matched source for each display polygon.

Supported source formats:
- QGC JSON: [{bdid, path:[[lat, lon], ...], heightMeters?, minHeightMeters?, levels?}]
- Overture/GeoJSON FeatureCollection with Polygon or MultiPolygon geometry

Usage example:
python tools/enrich_buildings_with_height.py \
  --display resources/buildings_dense.json \
  --source docs/osm_extract_height/buildings.json \
  --source /tmp/overture_building_bbox.geojson \
  --source /tmp/overture_building_part_bbox.geojson \
  --output resources/buildings_dense.json
"""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


DEFAULT_FLOOR_HEIGHT_METERS = 3.0
GRID_DEGREES = 0.0012
ESTIMATE_SEARCH_RADIUS_METERS = 260.0
ESTIMATE_MIN_LEVELS = 2


def _parse_meter_value(value) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        parsed = float(value)
        return parsed if math.isfinite(parsed) else None

    match = re.search(r"[+-]?\d+(?:\.\d+)?", str(value))
    if not match:
        return None

    parsed = float(match.group(0))
    return parsed if math.isfinite(parsed) else None


def _normalize_height_fields(record: Dict) -> Tuple[float, float, float]:
    height_m = _parse_meter_value(record.get("heightMeters"))
    if height_m is None:
        height_m = _parse_meter_value(record.get("height_m"))
    if height_m is None:
        height_m = _parse_meter_value(record.get("height"))

    min_height_m = _parse_meter_value(record.get("minHeightMeters"))
    if min_height_m is None:
        min_height_m = _parse_meter_value(record.get("min_height"))
    if min_height_m is None:
        min_height_m = _parse_meter_value(record.get("minHeight"))

    levels = _parse_meter_value(record.get("levels"))
    if levels is None:
        levels = _parse_meter_value(record.get("building:levels"))
    if levels is None:
        levels = _parse_meter_value(record.get("num_floors"))

    if height_m is None and levels is not None and levels > 0:
        height_m = levels * DEFAULT_FLOOR_HEIGHT_METERS

    return max(0.0, height_m or 0.0), max(0.0, min_height_m or 0.0), max(0.0, levels or 0.0)


def _bbox_for_path(path_latlon: Sequence[Sequence[float]]) -> Tuple[float, float, float, float]:
    lats = [pt[0] for pt in path_latlon]
    lons = [pt[1] for pt in path_latlon]
    return min(lats), min(lons), max(lats), max(lons)


def _polygon_centroid(path_latlon: Sequence[Sequence[float]]) -> Tuple[float, float]:
    if len(path_latlon) < 3:
        lat = sum(pt[0] for pt in path_latlon) / max(1, len(path_latlon))
        lon = sum(pt[1] for pt in path_latlon) / max(1, len(path_latlon))
        return lat, lon

    points = [(pt[1], pt[0]) for pt in path_latlon]
    area2 = 0.0
    cx = 0.0
    cy = 0.0
    for i in range(len(points)):
        x1, y1 = points[i]
        x2, y2 = points[(i + 1) % len(points)]
        cross = x1 * y2 - x2 * y1
        area2 += cross
        cx += (x1 + x2) * cross
        cy += (y1 + y2) * cross

    if abs(area2) < 1e-12:
        lat = sum(pt[0] for pt in path_latlon) / len(path_latlon)
        lon = sum(pt[1] for pt in path_latlon) / len(path_latlon)
        return lat, lon

    lon = cx / (3.0 * area2)
    lat = cy / (3.0 * area2)
    return lat, lon


def _polygon_area_m2(path_latlon: Sequence[Sequence[float]]) -> float:
    if len(path_latlon) < 3:
        return 0.0

    lat0 = math.radians(sum(pt[0] for pt in path_latlon) / len(path_latlon))
    lon0 = sum(pt[1] for pt in path_latlon) / len(path_latlon)
    meters_per_deg_lon = 111320.0 * math.cos(lat0)
    meters_per_deg_lat = 111320.0

    points_xy = [
        ((lon - lon0) * meters_per_deg_lon, (lat - path_latlon[0][0]) * meters_per_deg_lat)
        for lat, lon in path_latlon
    ]

    area = 0.0
    for i in range(len(points_xy)):
        x1, y1 = points_xy[i]
        x2, y2 = points_xy[(i + 1) % len(points_xy)]
        area += x1 * y2 - x2 * y1

    return abs(area) * 0.5


def _meters_between(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    lat0 = math.radians((lat1 + lat2) * 0.5)
    dx = (lon2 - lon1) * 111320.0 * math.cos(lat0)
    dy = (lat2 - lat1) * 111320.0
    return math.hypot(dx, dy)


def _record_total_height(record: Dict) -> float:
    height_m, min_height_m, levels = _normalize_height_fields(record)
    return max(0.0, height_m) + max(0.0, min_height_m)


def _source_priority(source_name: str, height_source: str = "explicit") -> int:
    if height_source == "estimated":
        return 0

    source_lower = (source_name or "").lower()
    if "cmab" in source_lower:
        return 3
    if "overture" in source_lower:
        return 2
    if source_lower.endswith(".json") or source_lower.endswith(".geojson"):
        return 2
    return 1


def _base_height_for_area(area_m2: float) -> float:
    if area_m2 < 100.0:
        return 6.0
    if area_m2 < 220.0:
        return 9.0
    if area_m2 < 450.0:
        return 12.0
    if area_m2 < 800.0:
        return 15.0
    if area_m2 < 1400.0:
        return 18.0
    if area_m2 < 2400.0:
        return 24.0
    if area_m2 < 4000.0:
        return 30.0
    return 36.0


def _height_cap_for_area(area_m2: float) -> float:
    if area_m2 < 100.0:
        return 12.0
    if area_m2 < 220.0:
        return 18.0
    if area_m2 < 450.0:
        return 24.0
    if area_m2 < 800.0:
        return 30.0
    if area_m2 < 1400.0:
        return 42.0
    if area_m2 < 2400.0:
        return 60.0
    if area_m2 < 4000.0:
        return 90.0
    return 150.0


def _build_known_height_index(display_records: Sequence[Dict]) -> Tuple[List[Dict], Dict[Tuple[int, int], List[int]]]:
    known: List[Dict] = []
    grid: Dict[Tuple[int, int], List[int]] = defaultdict(list)

    for record in display_records:
        total_height = _record_total_height(record)
        path_latlon = record.get("path") or []
        if total_height <= 0.0 or len(path_latlon) < 3:
            continue

        centroid_lat, centroid_lon = _polygon_centroid(path_latlon)
        area_m2 = _polygon_area_m2(path_latlon)
        known_idx = len(known)
        known.append({
            "centroidLat": centroid_lat,
            "centroidLon": centroid_lon,
            "areaM2": area_m2,
            "totalHeight": total_height,
        })
        cell = (math.floor(centroid_lat / GRID_DEGREES), math.floor(centroid_lon / GRID_DEGREES))
        grid[cell].append(known_idx)

    return known, grid


def _estimate_missing_heights(display_records: Sequence[Dict]) -> int:
    known, known_grid = _build_known_height_index(display_records)
    if not known:
        return 0

    estimated_count = 0
    search_cells = max(1, math.ceil((ESTIMATE_SEARCH_RADIUS_METERS / 111320.0) / GRID_DEGREES))

    for record in display_records:
        if _record_total_height(record) > 0.0:
            record["heightSource"] = str(record.get("heightSource") or "explicit")
            continue

        path_latlon = record.get("path") or []
        if len(path_latlon) < 3:
            continue

        centroid_lat, centroid_lon = _polygon_centroid(path_latlon)
        area_m2 = _polygon_area_m2(path_latlon)
        base_height = _base_height_for_area(area_m2)
        cap_height = _height_cap_for_area(area_m2)

        cell_lat = math.floor(centroid_lat / GRID_DEGREES)
        cell_lon = math.floor(centroid_lon / GRID_DEGREES)

        weighted_height = 0.0
        total_weight = 0.0

        for dy in range(-search_cells, search_cells + 1):
            for dx in range(-search_cells, search_cells + 1):
                for known_idx in known_grid.get((cell_lat + dy, cell_lon + dx), []):
                    neighbor = known[known_idx]
                    distance_m = _meters_between(
                        centroid_lat,
                        centroid_lon,
                        neighbor["centroidLat"],
                        neighbor["centroidLon"],
                    )
                    if distance_m > ESTIMATE_SEARCH_RADIUS_METERS:
                        continue

                    area_ratio = max(area_m2, 25.0) / max(neighbor["areaM2"], 25.0)
                    area_weight = math.exp(-abs(math.log(area_ratio)) / 0.9)
                    distance_weight = math.exp(-math.pow(distance_m / ESTIMATE_SEARCH_RADIUS_METERS, 1.35))
                    weight = area_weight * distance_weight
                    if weight < 0.03:
                        continue

                    weighted_height += weight * neighbor["totalHeight"]
                    total_weight += weight

        estimated_height = base_height
        if total_weight > 0.0:
            local_height = weighted_height / total_weight
            blend = min(0.55, total_weight / (total_weight + 2.5))
            estimated_height = base_height * (1.0 - blend) + local_height * blend

        estimated_height = max(base_height, min(estimated_height, cap_height))
        estimated_levels = max(ESTIMATE_MIN_LEVELS, int(round(estimated_height / DEFAULT_FLOOR_HEIGHT_METERS)))
        estimated_height = round(estimated_levels * DEFAULT_FLOOR_HEIGHT_METERS, 3)

        record["heightMeters"] = estimated_height
        record["levels"] = estimated_levels
        record["heightSource"] = "estimated"
        estimated_count += 1

    return estimated_count


def _point_in_polygon(lat: float, lon: float, path_latlon: Sequence[Sequence[float]]) -> bool:
    inside = False
    j = len(path_latlon) - 1
    for i in range(len(path_latlon)):
        yi, xi = path_latlon[i][0], path_latlon[i][1]
        yj, xj = path_latlon[j][0], path_latlon[j][1]
        intersects = ((yi > lat) != (yj > lat)) and (
            lon < (xj - xi) * (lat - yi) / ((yj - yi) or 1e-12) + xi
        )
        if intersects:
            inside = not inside
        j = i
    return inside


def _grid_range(min_value: float, max_value: float) -> range:
    start = math.floor(min_value / GRID_DEGREES)
    end = math.floor(max_value / GRID_DEGREES)
    return range(start, end + 1)


def _iter_geojson_rings(geometry: Dict) -> Iterable[List[List[float]]]:
    geom_type = geometry.get("type")
    coordinates = geometry.get("coordinates") or []
    if geom_type == "Polygon":
        if coordinates and coordinates[0]:
            yield [[float(latlon[1]), float(latlon[0])] for latlon in coordinates[0][:-1]]
        return

    if geom_type == "MultiPolygon":
        for polygon in coordinates:
            if polygon and polygon[0]:
                yield [[float(latlon[1]), float(latlon[0])] for latlon in polygon[0][:-1]]


def _load_qgc_json(path: Path) -> Iterable[Dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    for record in data:
        path_latlon = record.get("path") or []
        if len(path_latlon) < 3:
            continue
        height_m, min_height_m, levels = _normalize_height_fields(record)
        if height_m <= 0.0 and min_height_m <= 0.0 and levels <= 0.0:
            continue
        yield {
            "path": path_latlon,
            "heightMeters": height_m,
            "minHeightMeters": min_height_m,
            "levels": levels,
            "source": path.name,
        }


def _load_geojson(path: Path) -> Iterable[Dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    for feature in data.get("features", []):
        props = feature.get("properties") or {}
        height_m, min_height_m, levels = _normalize_height_fields(props)
        if height_m <= 0.0 and min_height_m <= 0.0 and levels <= 0.0:
            continue
        for ring in _iter_geojson_rings(feature.get("geometry") or {}):
            if len(ring) < 3:
                continue
            yield {
                "path": ring,
                "heightMeters": height_m,
                "minHeightMeters": min_height_m,
                "levels": levels,
                "source": path.name,
            }


def _load_sources(paths: Sequence[Path]) -> List[Dict]:
    out: List[Dict] = []
    for path in paths:
        if path.suffix.lower() == ".geojson":
            out.extend(_load_geojson(path))
        else:
            out.extend(_load_qgc_json(path))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Enrich QGC display buildings with height metadata.")
    parser.add_argument("--display", required=True, help="Base QGC display buildings JSON.")
    parser.add_argument("--source", action="append", required=True, help="Height source JSON/GeoJSON. Can be repeated.")
    parser.add_argument("--output", required=True, help="Output QGC display buildings JSON.")
    parser.add_argument(
        "--estimate-missing",
        action="store_true",
        help="Estimate conservative building heights for display polygons that still have no explicit height metadata.",
    )
    args = parser.parse_args()

    display_path = Path(args.display)
    source_paths = [Path(p) for p in args.source]
    output_path = Path(args.output)

    display_records = json.loads(display_path.read_text(encoding="utf-8"))
    sources = _load_sources(source_paths)

    grid: Dict[Tuple[int, int], List[int]] = defaultdict(list)
    display_meta: List[Dict] = []

    for idx, record in enumerate(display_records):
        path_latlon = record.get("path") or []
        if len(path_latlon) < 3:
            display_meta.append({"bbox": None, "path": path_latlon})
            continue
        min_lat, min_lon, max_lat, max_lon = _bbox_for_path(path_latlon)
        display_meta.append({
            "bbox": (min_lat, min_lon, max_lat, max_lon),
            "path": path_latlon,
            "bestTopHeight": (_parse_meter_value(record.get("minHeightMeters")) or 0.0)
                            + (_parse_meter_value(record.get("heightMeters")) or 0.0),
            "bestPriority": _source_priority(
                str(record.get("heightProvider") or ""),
                str(record.get("heightSource") or ("explicit" if _record_total_height(record) > 0.0 else "")),
            ),
        })
        for gy in _grid_range(min_lat, max_lat):
            for gx in _grid_range(min_lon, max_lon):
                grid[(gy, gx)].append(idx)

    matched_sources = 0
    updated_display = 0
    explicit_display = 0
    source_counts: Dict[str, int] = defaultdict(int)

    for record in display_records:
        if _record_total_height(record) > 0.0:
            record["heightSource"] = str(record.get("heightSource") or "explicit")

    for source in sources:
        path_latlon = source["path"]
        center_lat, center_lon = _polygon_centroid(path_latlon)
        cell = (math.floor(center_lat / GRID_DEGREES), math.floor(center_lon / GRID_DEGREES))
        candidates = grid.get(cell, [])
        if not candidates:
            continue

        top_height = source["minHeightMeters"] + source["heightMeters"]
        if top_height <= 0.0:
            continue
        source_priority = _source_priority(source["source"], "explicit")

        for display_idx in candidates:
            meta = display_meta[display_idx]
            bbox = meta.get("bbox")
            if not bbox:
                continue
            min_lat, min_lon, max_lat, max_lon = bbox
            if not (min_lat <= center_lat <= max_lat and min_lon <= center_lon <= max_lon):
                continue
            if not _point_in_polygon(center_lat, center_lon, meta["path"]):
                continue

            record = display_records[display_idx]
            if source_priority > meta["bestPriority"] or top_height > meta["bestTopHeight"] + 1e-6:
                record["heightMeters"] = round(source["heightMeters"], 3)
                if source["minHeightMeters"] > 0.0:
                    record["minHeightMeters"] = round(source["minHeightMeters"], 3)
                elif "minHeightMeters" in record:
                    record.pop("minHeightMeters", None)
                if source["levels"] > 0.0:
                    record["levels"] = round(source["levels"], 3)
                elif "levels" in record:
                    record.pop("levels", None)
                record["heightSource"] = "explicit"
                record["heightProvider"] = source["source"]
                meta["bestTopHeight"] = top_height
                meta["bestPriority"] = source_priority
            elif top_height > 0.0 and "heightMeters" not in record:
                record["heightMeters"] = round(source["heightMeters"], 3)
                if source["minHeightMeters"] > 0.0:
                    record["minHeightMeters"] = round(source["minHeightMeters"], 3)
                if source["levels"] > 0.0:
                    record["levels"] = round(source["levels"], 3)
                record["heightSource"] = "explicit"
                record["heightProvider"] = source["source"]

            matched_sources += 1
            source_counts[source["source"]] += 1
            break

    estimated_display = _estimate_missing_heights(display_records) if args.estimate_missing else 0

    for record in display_records:
        total_height = _record_total_height(record)
        if total_height > 0.0:
            updated_display += 1
            if record.get("heightSource") == "estimated":
                continue
            explicit_display += 1

    output_path.write_text(
        json.dumps(display_records, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )

    print("display_count=", len(display_records))
    print("height_aware_display=", updated_display)
    print("explicit_height_aware_display=", explicit_display)
    print("estimated_height_aware_display=", estimated_display)
    print("matched_sources=", matched_sources)
    print("source_matches=", json.dumps(source_counts, ensure_ascii=False, sort_keys=True))
    print("output=", output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
