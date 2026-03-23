#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path
from typing import Iterable, List, Sequence


DEFAULT_FLOOR_HEIGHT_METERS = 3.0


def _parse_meter_value(value) -> float | None:
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


def _copy_height_fields(record: dict) -> dict:
    out: dict = {}

    height_m = _parse_meter_value(record.get("heightMeters"))
    if height_m is None:
        height_m = _parse_meter_value(record.get("height_m"))
    if height_m is None:
        height_m = _parse_meter_value(record.get("height"))

    min_height_m = _parse_meter_value(record.get("minHeightMeters"))
    if min_height_m is None:
        min_height_m = _parse_meter_value(record.get("min_height"))

    levels = _parse_meter_value(record.get("levels"))
    if levels is None:
        levels = _parse_meter_value(record.get("building:levels"))
    if levels is None:
        levels = _parse_meter_value(record.get("num_floors"))

    if height_m is not None and height_m > 0:
        out["heightMeters"] = height_m
    if min_height_m is not None and min_height_m > 0:
        out["minHeightMeters"] = min_height_m
    if levels is not None and levels > 0:
        out["levels"] = levels
        if "heightMeters" not in out:
            out["heightMeters"] = levels * DEFAULT_FLOOR_HEIGHT_METERS

    if record.get("heightSource"):
        out["heightSource"] = record["heightSource"]
    if record.get("heightProvider"):
        out["heightProvider"] = record["heightProvider"]

    confidence = _parse_meter_value(record.get("heightConfidence"))
    if confidence is not None and confidence > 0:
        out["heightConfidence"] = confidence

    return out


def _ring_area_m2(coords: Sequence[Sequence[float]]) -> float:
    if len(coords) < 4:
        return 0.0

    lons = [pt[0] for pt in coords]
    lats = [pt[1] for pt in coords]
    lat0 = math.radians(sum(lats) / len(lats))
    meters_per_deg_lon = 111320.0 * math.cos(lat0)
    meters_per_deg_lat = 111320.0

    points_xy = [
        ((lon - lons[0]) * meters_per_deg_lon, (lat - lats[0]) * meters_per_deg_lat)
        for lon, lat in coords
    ]

    area = 0.0
    for (x1, y1), (x2, y2) in zip(points_xy, points_xy[1:]):
        area += x1 * y2 - x2 * y1
    return abs(area) * 0.5


def _normalize_ring(coords: Sequence[Sequence[float]]) -> List[List[float]] | None:
    out: List[List[float]] = []

    for pt in coords:
        if len(pt) < 2:
            continue
        lon = float(pt[0])
        lat = float(pt[1])
        if out and abs(out[-1][0] - lat) < 1e-10 and abs(out[-1][1] - lon) < 1e-10:
            continue
        out.append([lat, lon])

    if len(out) >= 2:
        first = out[0]
        last = out[-1]
        if abs(first[0] - last[0]) < 1e-10 and abs(first[1] - last[1]) < 1e-10:
            out.pop()

    if len(out) < 3:
        return None

    return out


def _iter_exterior_rings(geometry: dict) -> Iterable[Sequence[Sequence[float]]]:
    if not geometry:
        return

    geom_type = geometry.get("type")
    coordinates = geometry.get("coordinates") or []

    if geom_type == "Polygon":
        if coordinates and coordinates[0]:
            yield coordinates[0]
        return

    if geom_type == "MultiPolygon":
        for polygon in coordinates:
            if polygon and polygon[0]:
                yield polygon[0]


def _centroid_lon(path_latlon: Sequence[Sequence[float]]) -> float:
    return sum(pt[1] for pt in path_latlon) / len(path_latlon)


def _load_current_display_west(current_json: Path, lon_cut: float) -> List[dict]:
    current = json.loads(current_json.read_text(encoding="utf-8"))
    out: List[dict] = []
    next_id = 1

    for record in current:
        path = record.get("path") or []
        if len(path) < 3:
            continue
        if _centroid_lon(path) >= lon_cut:
            continue
        item = {"bdid": next_id, "path": path}
        item.update(_copy_height_fields(record))
        out.append(item)
        next_id += 1

    return out


def _load_overture_buildings(
    overture_geojson: Path,
    min_area_m2: float = 0.0,
    min_lon: float | None = None,
) -> List[dict]:
    geojson = json.loads(overture_geojson.read_text(encoding="utf-8"))
    out: List[dict] = []
    next_id = 1

    for feature in geojson.get("features", []):
        geometry = feature.get("geometry") or {}
        properties = feature.get("properties") or {}
        for ring in _iter_exterior_rings(geometry):
            area_m2 = _ring_area_m2(ring)
            if area_m2 < min_area_m2:
                continue

            path = _normalize_ring(ring)
            if not path:
                continue

            if min_lon is not None and _centroid_lon(path) < min_lon:
                continue

            item = {"bdid": next_id, "path": path}
            item.update(_copy_height_fields(properties))
            out.append(item)
            next_id += 1

    return out


def _write_json(path: Path, data: Sequence[dict]) -> None:
    path.write_text(
        json.dumps(list(data), ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def _merge_display_buildings(
    display_data: Sequence[dict],
    merge_distance_m: float,
    simplify_tolerance_m: float,
    min_area_m2: float,
) -> List[dict]:
    if merge_distance_m <= 0.0:
        out: List[dict] = []
        for i, record in enumerate(display_data):
            item = {"bdid": i + 1, "path": record["path"]}
            item.update(_copy_height_fields(record))
            out.append(item)
        return out

    try:
        from shapely.geometry import Polygon
        from shapely.ops import unary_union
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise RuntimeError("display merge requested but shapely is not installed") from exc

    all_points = [pt for record in display_data for pt in record.get("path", [])]
    if not all_points:
        return []

    lat0 = sum(pt[0] for pt in all_points) / len(all_points)
    lon0 = sum(pt[1] for pt in all_points) / len(all_points)
    meters_per_deg_lat = 111320.0
    meters_per_deg_lon = 111320.0 * math.cos(math.radians(lat0))

    def to_xy(lat: float, lon: float) -> tuple[float, float]:
        return ((lon - lon0) * meters_per_deg_lon, (lat - lat0) * meters_per_deg_lat)

    def to_latlon(x: float, y: float) -> List[float]:
        return [lat0 + y / meters_per_deg_lat, lon0 + x / meters_per_deg_lon]

    polygons = []
    for record in display_data:
        path = record.get("path") or []
        if len(path) < 3:
            continue
        polygon = Polygon([to_xy(lat, lon) for lat, lon in path])
        if not polygon.is_valid:
            polygon = polygon.buffer(0)
        if polygon.is_empty:
            continue
        if polygon.geom_type == "Polygon":
            polygons.append(polygon)
        else:
            polygons.extend(part for part in polygon.geoms if not part.is_empty and part.area >= 1.0)

    if not polygons:
        return []

    merged = unary_union([poly.buffer(merge_distance_m, join_style=2) for poly in polygons]).buffer(
        -merge_distance_m, join_style=2
    )
    merged_parts = [merged] if merged.geom_type == "Polygon" else list(merged.geoms)

    out: List[dict] = []
    next_id = 1
    for polygon in merged_parts:
        if polygon.is_empty or polygon.area < min_area_m2:
            continue

        simplified = polygon
        if simplify_tolerance_m > 0.0:
            simplified = polygon.simplify(simplify_tolerance_m, preserve_topology=True)
            if simplified.is_empty:
                continue

        simplified_parts = [simplified] if simplified.geom_type == "Polygon" else list(simplified.geoms)
        for part in simplified_parts:
            if part.is_empty or part.area < min_area_m2:
                continue

            coords = list(part.exterior.coords)
            path = [to_latlon(x, y) for x, y in coords[:-1]]
            if len(path) < 3:
                continue
            out.append({"bdid": next_id, "path": path})
            next_id += 1

    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate QGC building display/optimizer datasets from Overture + existing display data."
    )
    parser.add_argument(
        "--current-json",
        default="docs/osm_extract/buildings.json",
        help="Existing QGC building JSON used for west-side display preservation.",
    )
    parser.add_argument(
        "--overture-geojson",
        default="/tmp/overture_buildings.geojson",
        help="Overture building GeoJSON downloaded for the target bbox.",
    )
    parser.add_argument(
        "--display-out",
        default="resources/buildings_dense.json",
        help="Output QGC display dataset JSON.",
    )
    parser.add_argument(
        "--optimizer-out",
        default="resources/buildings_optimizer.json",
        help="Output QGC optimizer dataset JSON.",
    )
    parser.add_argument(
        "--display-lon-cut",
        type=float,
        default=113.289,
        help="Display dataset uses current buildings west of this longitude and Overture east of it.",
    )
    parser.add_argument(
        "--display-east-min-area",
        type=float,
        default=60.0,
        help="Minimum Overture building exterior-ring area in m^2 for display on the east side.",
    )
    parser.add_argument(
        "--display-merge-distance",
        type=float,
        default=0.0,
        help="If > 0, merge nearby display buildings using this buffer/unbuffer distance in meters.",
    )
    parser.add_argument(
        "--display-simplify-tolerance",
        type=float,
        default=0.0,
        help="Optional geometry simplify tolerance in meters after display merge.",
    )
    parser.add_argument(
        "--display-merge-min-area",
        type=float,
        default=25.0,
        help="Minimum merged display polygon area in m^2 to keep after merge.",
    )
    args = parser.parse_args()

    current_json = Path(args.current_json)
    overture_geojson = Path(args.overture_geojson)
    display_out = Path(args.display_out)
    optimizer_out = Path(args.optimizer_out)

    west_display = _load_current_display_west(current_json, args.display_lon_cut)
    east_display = _load_overture_buildings(
        overture_geojson,
        min_area_m2=args.display_east_min_area,
        min_lon=args.display_lon_cut,
    )

    display_data: List[dict] = []
    next_display_id = 1
    for record in west_display + east_display:
        display_data.append({"bdid": next_display_id, "path": record["path"]})
        next_display_id += 1

    merged_display_data = _merge_display_buildings(
        display_data,
        merge_distance_m=args.display_merge_distance,
        simplify_tolerance_m=args.display_simplify_tolerance,
        min_area_m2=args.display_merge_min_area,
    )

    optimizer_data = _load_overture_buildings(overture_geojson)

    _write_json(display_out, merged_display_data)
    _write_json(optimizer_out, optimizer_data)

    print(
        "display_count=",
        len(merged_display_data),
        "display_raw=",
        len(display_data),
        "west_current=",
        len(west_display),
        "east_overture=",
        len(east_display),
    )
    print("optimizer_count=", len(optimizer_data))
    print("display_out=", display_out)
    print("optimizer_out=", optimizer_out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
