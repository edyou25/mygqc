#!/usr/bin/env python3
"""
Extract a lat/lon bbox from CMAB shapefiles and convert it to a QGC-style
building JSON:

[
  {
    "bdid": 1,
    "path": [[lat, lon], ...],
    "heightMeters": 32.5
  }
]

The CMAB Guangdong package ships shapefiles in Web Mercator (EPSG:3857), so
this script transforms coordinates back to WGS84 and only keeps polygons that
intersect the requested bbox.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

try:
    import shapefile
except ImportError as exc:  # pragma: no cover - environment dependent
    raise SystemExit(
        "Missing dependency `pyshp`. Install it with: python3 -m pip install --user pyshp"
    ) from exc


EARTH_RADIUS_METERS = 6378137.0


def parse_bbox(text: str) -> Tuple[float, float, float, float]:
    parts = [float(part.strip()) for part in text.split(",")]
    if len(parts) != 4:
        raise ValueError("bbox must be: min_lat,min_lon,max_lat,max_lon")

    min_lat, min_lon, max_lat, max_lon = parts
    if min_lat > max_lat:
        min_lat, max_lat = max_lat, min_lat
    if min_lon > max_lon:
        min_lon, max_lon = max_lon, min_lon
    return min_lat, min_lon, max_lat, max_lon


def latlon_to_web_mercator(lat: float, lon: float) -> Tuple[float, float]:
    x = EARTH_RADIUS_METERS * math.radians(lon)
    y = EARTH_RADIUS_METERS * math.log(math.tan(math.pi * 0.25 + math.radians(lat) * 0.5))
    return x, y


def web_mercator_to_latlon(x: float, y: float) -> Tuple[float, float]:
    lon = math.degrees(x / EARTH_RADIUS_METERS)
    lat = math.degrees(2.0 * math.atan(math.exp(y / EARTH_RADIUS_METERS)) - math.pi * 0.5)
    return lat, lon


def shape_intersects_bbox(shape_bbox: Sequence[float], merc_bbox: Sequence[float]) -> bool:
    xmin, ymin, xmax, ymax = shape_bbox
    qxmin, qymin, qxmax, qymax = merc_bbox
    return not (xmax < qxmin or xmin > qxmax or ymax < qymin or ymin > qymax)


def iter_polygon_parts(shape: shapefile.Shape) -> Iterable[List[Tuple[float, float]]]:
    points = shape.points
    parts = list(shape.parts) + [len(points)]
    for start, end in zip(parts, parts[1:]):
        ring = points[start:end]
        if len(ring) < 4:
            continue
        yield ring


def ring_to_latlon_path(ring_xy: Sequence[Tuple[float, float]]) -> List[List[float]]:
    out: List[List[float]] = []
    for x, y in ring_xy:
        lat, lon = web_mercator_to_latlon(x, y)
        if out and abs(out[-1][0] - lat) < 1e-10 and abs(out[-1][1] - lon) < 1e-10:
            continue
        out.append([lat, lon])

    if len(out) >= 2 and abs(out[0][0] - out[-1][0]) < 1e-10 and abs(out[0][1] - out[-1][1]) < 1e-10:
        out.pop()
    return out


def load_height(record_dict: dict) -> float:
    for key in ("Height", "height", "pred_h_r"):
        value = record_dict.get(key)
        if value is None:
            continue
        try:
            height = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(height) and height > 0:
            return height
    return 0.0


def extract_region(input_dir: Path, bbox_latlon: Sequence[float]) -> List[dict]:
    min_lat, min_lon, max_lat, max_lon = bbox_latlon
    min_x, min_y = latlon_to_web_mercator(min_lat, min_lon)
    max_x, max_y = latlon_to_web_mercator(max_lat, max_lon)
    merc_bbox = (min_x, min_y, max_x, max_y)

    out: List[dict] = []
    next_id = 1

    shapefiles = sorted(input_dir.glob("*.shp"))
    for shp_path in shapefiles:
        reader = shapefile.Reader(str(shp_path))
        if not shape_intersects_bbox(reader.bbox, merc_bbox):
            continue

        field_names = [field[0] for field in reader.fields[1:]]
        for shape_record in reader.iterShapeRecords():
            if not shape_intersects_bbox(shape_record.shape.bbox, merc_bbox):
                continue

            record_dict = (
                shape_record.record.as_dict()
                if hasattr(shape_record.record, "as_dict")
                else dict(zip(field_names, shape_record.record))
            )
            height_m = load_height(record_dict)
            if height_m <= 0.0:
                continue

            merged_id = record_dict.get("merged_id")
            for part_index, ring_xy in enumerate(iter_polygon_parts(shape_record.shape)):
                part_bbox = (
                    min(pt[0] for pt in ring_xy),
                    min(pt[1] for pt in ring_xy),
                    max(pt[0] for pt in ring_xy),
                    max(pt[1] for pt in ring_xy),
                )
                if not shape_intersects_bbox(part_bbox, merc_bbox):
                    continue

                path = ring_to_latlon_path(ring_xy)
                if len(path) < 3:
                    continue

                out.append({
                    "bdid": next_id,
                    "cmabMergedId": merged_id,
                    "cmabSourceFile": shp_path.name,
                    "cmabPartIndex": part_index,
                    "path": path,
                    "heightMeters": round(height_m, 3),
                })
                next_id += 1

    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract a bbox from CMAB shapefiles.")
    parser.add_argument(
        "--input-dir",
        required=True,
        help="Directory containing extracted CMAB .shp/.dbf/.shx files.",
    )
    parser.add_argument(
        "--bbox",
        required=True,
        help="Lat/lon bbox: min_lat,min_lon,max_lat,max_lon",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output QGC-style JSON file.",
    )
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_path = Path(args.output)
    bbox = parse_bbox(args.bbox)

    buildings = extract_region(input_dir, bbox)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(buildings, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )

    print("input_dir=", input_dir)
    print("bbox=", bbox)
    print("output=", output_path)
    print("building_count=", len(buildings))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
