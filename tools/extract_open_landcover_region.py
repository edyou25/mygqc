#!/usr/bin/env python3
"""
Extract extra greenland/water polygons from open land-cover datasets and
append them to the existing QGC-style OSM extracts.

Sources used:
- ESA WorldCover (10m)
- JRC Global Surface Water
- Esri 10-Meter Land Cover (10-class)

Output format:
- greenlands.json: [{gid, path:[[lat, lon], ...]}]
- waters.json:     [{wid, path:[[lat, lon], ...]}]
- summary_open_landcover.json
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

import numpy as np
import planetary_computer
import rasterio
from pyproj import Transformer
from pystac_client import Client
from rasterio.features import geometry_mask, shapes
from rasterio.transform import array_bounds
from rasterio.warp import Resampling, reproject
from rasterio.windows import Window, from_bounds
from shapely.geometry import GeometryCollection, MultiPolygon, Polygon, box, mapping, shape
from shapely.ops import transform, unary_union


STAC_URL = "https://planetarycomputer.microsoft.com/api/stac/v1"

# ESA WorldCover classes
WC_GREEN_CLASSES = {10, 20, 30, 95}
WC_WATER_CLASSES = {80, 90}

# Esri 10m LULC classes:
# 1 water, 2 trees, 3 grass, 4 flooded veg, 5 crops, 6 scrub,
# 7 built area, 8 bare, 9 snow/ice, 10 clouds
ESRI_GREEN_CLASSES = {2, 3, 6}
ESRI_WATER_CLASSES = {1, 4}


def parse_points(text: str) -> List[Tuple[float, float]]:
    pts: List[Tuple[float, float]] = []
    for item in text.split(";"):
        item = item.strip()
        if not item:
            continue
        lat_s, lon_s = item.split(",", 1)
        pts.append((float(lat_s.strip()), float(lon_s.strip())))
    if len(pts) < 3:
        raise ValueError("Polygon requires at least 3 points")
    return pts


def ensure_closed_latlon(points: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    out = list(points)
    if out[0] != out[-1]:
        out.append(out[0])
    return out


def region_polygon(points: Sequence[Tuple[float, float]]) -> Polygon:
    # shapely uses lon/lat order
    return Polygon([(lon, lat) for lat, lon in ensure_closed_latlon(points)])


def utm_epsg_for_lonlat(lon: float, lat: float) -> str:
    zone = int(math.floor((lon + 180.0) / 6.0) + 1)
    base = 326 if lat >= 0 else 327
    return f"EPSG:{base}{zone:02d}"


def area_transformer_for_geom(geom: Polygon) -> Transformer:
    c = geom.centroid
    return Transformer.from_crs("EPSG:4326", utm_epsg_for_lonlat(c.x, c.y), always_xy=True)


def area_m2(geom: Polygon, transformer: Transformer) -> float:
    projected = transform(transformer.transform, geom)
    return abs(projected.area)


def simplify_geom(geom: Polygon, transformer_to_utm: Transformer, transformer_to_wgs84: Transformer, tolerance_m: float) -> Polygon:
    projected = transform(transformer_to_utm.transform, geom)
    simplified = projected.simplify(tolerance_m, preserve_topology=True)
    return transform(transformer_to_wgs84.transform, simplified)


def clamp_window(win: Window, width: int, height: int) -> Window:
    col_off = max(0, int(math.floor(win.col_off)))
    row_off = max(0, int(math.floor(win.row_off)))
    col_max = min(width, int(math.ceil(win.col_off + win.width)))
    row_max = min(height, int(math.ceil(win.row_off + win.height)))
    return Window(col_off, row_off, max(0, col_max - col_off), max(0, row_max - row_off))


def polygon_mask_for_grid(region: Polygon, out_shape: Tuple[int, int], transform_) -> np.ndarray:
    return geometry_mask([mapping(region)], out_shape=out_shape, transform=transform_, invert=True, all_touched=False)


def latest_worldcover_item(client: Client, bbox: Sequence[float]):
    items = list(client.search(collections=["esa-worldcover"], bbox=bbox, limit=10).items())
    if not items:
        raise RuntimeError("No ESA WorldCover item found for region")
    items.sort(key=lambda item: item.id, reverse=True)
    return items[0]


def read_worldcover_subset(client: Client, region: Polygon) -> Tuple[np.ndarray, rasterio.Affine]:
    item = latest_worldcover_item(client, region.bounds)
    url = item.assets["map"].href
    with rasterio.open(url) as ds:
        win = clamp_window(from_bounds(*region.bounds, transform=ds.transform), ds.width, ds.height)
        arr = ds.read(1, window=win, boundless=True, fill_value=0)
        transform_ = ds.window_transform(win)
    return arr, transform_


def reproject_to_target(src_arr: np.ndarray, src_transform, src_crs, target_shape: Tuple[int, int], target_transform) -> np.ndarray:
    dst = np.zeros(target_shape, dtype=np.uint8)
    reproject(
        source=src_arr,
        destination=dst,
        src_transform=src_transform,
        src_crs=src_crs,
        dst_transform=target_transform,
        dst_crs="EPSG:4326",
        resampling=Resampling.nearest,
        src_nodata=0,
        dst_nodata=0,
    )
    return dst


def read_esri_mask(client: Client, region: Polygon, classes: set[int], target_shape: Tuple[int, int], target_transform, region_grid_mask: np.ndarray) -> np.ndarray:
    mask = np.zeros(target_shape, dtype=bool)
    region_bbox = region.bounds
    for item in client.search(collections=["io-lulc"], bbox=region_bbox, limit=20).items():
        url = item.assets["data"].href
        with rasterio.open(url) as ds:
            region_in_src = transform(
                Transformer.from_crs("EPSG:4326", ds.crs, always_xy=True).transform,
                region,
            )
            if region_in_src.is_empty or not region_in_src.intersects(box(*ds.bounds)):
                continue
            win = clamp_window(from_bounds(*region_in_src.bounds, transform=ds.transform), ds.width, ds.height)
            if win.width <= 0 or win.height <= 0:
                continue
            arr = ds.read(1, window=win, boundless=True, fill_value=0)
            arr_transform = ds.window_transform(win)
            reproj = reproject_to_target(arr, arr_transform, ds.crs, target_shape, target_transform)
            mask |= np.isin(reproj, list(classes))
    return mask & region_grid_mask


def read_jrc_water_mask(client: Client, region: Polygon, target_shape: Tuple[int, int], target_transform, region_grid_mask: np.ndarray, occurrence_threshold: int, seasonality_threshold: int) -> np.ndarray:
    items = list(client.search(collections=["jrc-gsw"], bbox=region.bounds, limit=10).items())
    if not items:
        return np.zeros(target_shape, dtype=bool)

    extent_mask = np.zeros(target_shape, dtype=bool)
    occurrence_mask = np.zeros(target_shape, dtype=bool)
    seasonality_mask = np.zeros(target_shape, dtype=bool)

    for item in items:
        for asset_name, out_mask, predicate in (
            ("extent", extent_mask, lambda arr: arr > 0),
            ("occurrence", occurrence_mask, lambda arr: arr >= occurrence_threshold),
            ("seasonality", seasonality_mask, lambda arr: arr >= seasonality_threshold),
        ):
            url = item.assets[asset_name].href
            with rasterio.open(url) as ds:
                region_in_src = transform(
                    Transformer.from_crs("EPSG:4326", ds.crs, always_xy=True).transform,
                    region,
                )
                if region_in_src.is_empty or not region_in_src.intersects(box(*ds.bounds)):
                    continue
                win = clamp_window(from_bounds(*region_in_src.bounds, transform=ds.transform), ds.width, ds.height)
                if win.width <= 0 or win.height <= 0:
                    continue
                arr = ds.read(1, window=win, boundless=True, fill_value=0)
                arr_transform = ds.window_transform(win)
                reproj = reproject_to_target(arr, arr_transform, ds.crs, target_shape, target_transform)
                out_mask |= predicate(reproj)

    combined = seasonality_mask | (extent_mask & occurrence_mask)
    return combined & region_grid_mask


def explode_polygons(geom) -> Iterable[Polygon]:
    if geom.is_empty:
        return []
    if isinstance(geom, Polygon):
        return [geom]
    if isinstance(geom, MultiPolygon):
        return list(geom.geoms)
    if isinstance(geom, GeometryCollection):
        out: List[Polygon] = []
        for part in geom.geoms:
            out.extend(explode_polygons(part))
        return out
    return []


def polygonize_mask(mask: np.ndarray, transform_, region: Polygon) -> List[Polygon]:
    out: List[Polygon] = []
    for geom, value in shapes(mask.astype(np.uint8), mask=mask, transform=transform_):
        if value != 1:
            continue
        poly = shape(geom).intersection(region)
        for part in explode_polygons(poly):
            if not part.is_empty:
                out.append(part.buffer(0))
    return out


def load_qgc_polygons(path: Path) -> List[Polygon]:
    data = json.loads(path.read_text(encoding="utf-8"))
    polys: List[Polygon] = []
    for item in data:
        coords = item.get("path") or []
        if len(coords) < 3:
            continue
        poly = Polygon([(lon, lat) for lat, lon in coords])
        if poly.is_valid and not poly.is_empty:
            polys.append(poly)
    return polys


def append_new_polygons(existing: List[Polygon], candidates: List[Polygon], region: Polygon, min_area_m2: float, simplify_m: float) -> List[Polygon]:
    if not candidates:
        return []

    transformer_to_utm = area_transformer_for_geom(region)
    utm_epsg = utm_epsg_for_lonlat(region.centroid.x, region.centroid.y)
    transformer_to_wgs84 = Transformer.from_crs(utm_epsg, "EPSG:4326", always_xy=True)

    baseline_union = unary_union(existing) if existing else GeometryCollection()
    candidate_union = unary_union(candidates)
    extra = candidate_union.difference(baseline_union)

    added: List[Polygon] = []
    for part in explode_polygons(extra):
        if part.is_empty:
            continue
        cleaned = part.buffer(0)
        if cleaned.is_empty:
            continue
        if area_m2(cleaned, transformer_to_utm) < min_area_m2:
            continue
        simplified = simplify_geom(cleaned, transformer_to_utm, transformer_to_wgs84, simplify_m).buffer(0)
        if simplified.is_empty:
            continue
        if area_m2(simplified, transformer_to_utm) < min_area_m2:
            continue
        added.extend(explode_polygons(simplified))
    return added


def qgc_records(polys: Sequence[Polygon], key_name: str) -> List[dict]:
    out = []
    for idx, poly in enumerate(polys, start=1):
        coords = list(poly.exterior.coords)
        if len(coords) < 4:
            continue
        path = [[lat, lon] for lon, lat in coords[:-1]]
        out.append({key_name: idx, "path": path})
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract extra greenland/water polygons from open land-cover datasets")
    parser.add_argument("--points", required=True, help='Semicolon-separated "lat,lon" points')
    parser.add_argument("--osm-dir", default="docs/osm_extract", help="Directory containing existing greenlands.json and waters.json")
    parser.add_argument("--out-dir", default="docs/open_landcover_extract", help="Output directory")
    parser.add_argument("--green-min-area", type=float, default=500.0, help="Minimum area in square meters for new green polygons")
    parser.add_argument("--water-min-area", type=float, default=300.0, help="Minimum area in square meters for new water polygons")
    parser.add_argument("--simplify-m", type=float, default=4.0, help="Simplify tolerance in meters")
    parser.add_argument("--jrc-occurrence-threshold", type=int, default=20, help="Minimum JRC occurrence percentage")
    parser.add_argument("--jrc-seasonality-threshold", type=int, default=8, help="Minimum JRC seasonality in months")
    args = parser.parse_args()

    points = parse_points(args.points)
    region = region_polygon(points)

    client = Client.open(STAC_URL, modifier=planetary_computer.sign_inplace)

    # Use WorldCover as the common 10m grid.
    worldcover_arr, worldcover_transform = read_worldcover_subset(client, region)
    target_shape = worldcover_arr.shape
    region_grid_mask = polygon_mask_for_grid(region, target_shape, worldcover_transform)

    wc_green_mask = np.isin(worldcover_arr, list(WC_GREEN_CLASSES)) & region_grid_mask
    wc_water_mask = np.isin(worldcover_arr, list(WC_WATER_CLASSES)) & region_grid_mask

    esri_green_mask = read_esri_mask(client, region, ESRI_GREEN_CLASSES, target_shape, worldcover_transform, region_grid_mask)
    esri_water_mask = read_esri_mask(client, region, ESRI_WATER_CLASSES, target_shape, worldcover_transform, region_grid_mask)
    jrc_water_mask = read_jrc_water_mask(
        client,
        region,
        target_shape,
        worldcover_transform,
        region_grid_mask,
        args.jrc_occurrence_threshold,
        args.jrc_seasonality_threshold,
    )

    osm_dir = Path(args.osm_dir)
    existing_green = load_qgc_polygons(osm_dir / "greenlands.json")
    existing_water = load_qgc_polygons(osm_dir / "waters.json")

    candidate_green = polygonize_mask(wc_green_mask | esri_green_mask, worldcover_transform, region)
    candidate_water = polygonize_mask(wc_water_mask | esri_water_mask | jrc_water_mask, worldcover_transform, region)

    added_green = append_new_polygons(existing_green, candidate_green, region, args.green_min_area, args.simplify_m)
    added_water = append_new_polygons(existing_water, candidate_water, region, args.water_min_area, args.simplify_m)

    final_green = existing_green + added_green
    final_water = existing_water + added_water

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    green_records = qgc_records(final_green, "gid")
    water_records = qgc_records(final_water, "wid")

    (out_dir / "greenlands.json").write_text(json.dumps(green_records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out_dir / "waters.json").write_text(json.dumps(water_records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    snippet = (
        "[Greenland]\n"
        f"greenlandsJson={json.dumps(json.dumps(green_records, ensure_ascii=False))}\n"
        f"nextId={len(green_records) + 1}\n\n"
        "[Water]\n"
        f"watersJson={json.dumps(json.dumps(water_records, ensure_ascii=False))}\n"
        f"nextId={len(water_records) + 1}\n"
    )
    (out_dir / "qgc_settings_snippet.ini").write_text(snippet, encoding="utf-8")

    summary = {
        "existing_greenlands": len(existing_green),
        "existing_waters": len(existing_water),
        "candidate_greenlands_from_open_sources": len(candidate_green),
        "candidate_waters_from_open_sources": len(candidate_water),
        "added_greenlands": len(added_green),
        "added_waters": len(added_water),
        "final_greenlands": len(final_green),
        "final_waters": len(final_water),
        "greenland_increase": len(final_green) - len(existing_green),
        "water_increase": len(final_water) - len(existing_water),
        "sources": [
            "ESA WorldCover",
            "JRC Global Surface Water",
            "Esri 10-Meter Land Cover",
        ],
        "parameters": {
            "green_min_area_m2": args.green_min_area,
            "water_min_area_m2": args.water_min_area,
            "simplify_m": args.simplify_m,
            "jrc_occurrence_threshold": args.jrc_occurrence_threshold,
            "jrc_seasonality_threshold": args.jrc_seasonality_threshold,
        },
    }
    (out_dir / "summary_open_landcover.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
