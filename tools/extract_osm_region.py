#!/usr/bin/env python3
"""
Extract OSM data in a polygon and convert to QGC custom formats:
- greenlands: [{gid, path:[[lat, lon], ...]}]
- waters:     [{wid, path:[[lat, lon], ...]}]
- buildings:  [{bdid, path:[[lat, lon], ...]}]
- roads:      GeoJSON FeatureCollection with LineString features

Usage example:
python3 tools/extract_osm_region.py \
  --points "23.1076536,113.2501964;23.0667990,113.2490714;23.0656005,113.3211486;23.1072648,113.3208514" \
  --out-dir docs/osm_extract
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


EXCLUDED_HIGHWAYS = {
    "footway",
    "path",
    "steps",
    "cycleway",
    "bridleway",
    "corridor",
    "elevator",
    "construction",
    "proposed",
    "platform",
}

GREEN_LEISURE = {"park", "garden", "recreation_ground", "nature_reserve", "golf_course"}
GREEN_LANDUSE = {"grass", "forest", "meadow", "village_green", "recreation_ground"}
GREEN_NATURAL = {"wood", "grassland", "scrub", "heath"}

WATER_NATURAL = {"water", "wetland"}
WATER_LANDUSE = {"reservoir", "basin", "salt_pond"}
WATER_WATERWAY = {"riverbank"}
DEFAULT_FLOOR_HEIGHT_METERS = 3.0


def parse_points(text: str) -> List[Tuple[float, float]]:
    pts: List[Tuple[float, float]] = []
    for item in text.split(";"):
        item = item.strip()
        if not item:
            continue
        lat_s, lon_s = item.split(",", 1)
        lat = float(lat_s.strip())
        lon = float(lon_s.strip())
        pts.append((lat, lon))
    if len(pts) < 3:
        raise ValueError("Polygon requires at least 3 points")
    return pts


def to_poly_string(points: Sequence[Tuple[float, float]]) -> str:
    closed = list(points)
    if closed[0] != closed[-1]:
        closed.append(closed[0])
    return " ".join(f"{lat} {lon}" for lat, lon in closed)


def overpass_query(poly_text: str) -> str:
    # Keep tags broad enough to cover common OSM mapping styles.
    return f"""
[out:json][timeout:240];
(
  way(poly:"{poly_text}")[highway];

  way(poly:"{poly_text}")[building];
  relation(poly:"{poly_text}")[building];

  way(poly:"{poly_text}")[natural=water];
  way(poly:"{poly_text}")[natural=wetland];
  way(poly:"{poly_text}")[water];
  way(poly:"{poly_text}")[waterway=riverbank];
  way(poly:"{poly_text}")[landuse=reservoir];
  way(poly:"{poly_text}")[landuse=basin];
  way(poly:"{poly_text}")[landuse=salt_pond];
  relation(poly:"{poly_text}")[natural=water];
  relation(poly:"{poly_text}")[natural=wetland];
  relation(poly:"{poly_text}")[water];
  relation(poly:"{poly_text}")[waterway=riverbank];
  relation(poly:"{poly_text}")[landuse=reservoir];
  relation(poly:"{poly_text}")[landuse=basin];
  relation(poly:"{poly_text}")[landuse=salt_pond];

  way(poly:"{poly_text}")[leisure=park];
  way(poly:"{poly_text}")[leisure=garden];
  way(poly:"{poly_text}")[leisure=recreation_ground];
  way(poly:"{poly_text}")[leisure=nature_reserve];
  way(poly:"{poly_text}")[leisure=golf_course];
  way(poly:"{poly_text}")[landuse=grass];
  way(poly:"{poly_text}")[landuse=forest];
  way(poly:"{poly_text}")[landuse=meadow];
  way(poly:"{poly_text}")[landuse=village_green];
  way(poly:"{poly_text}")[landuse=recreation_ground];
  way(poly:"{poly_text}")[natural=wood];
  way(poly:"{poly_text}")[natural=grassland];
  way(poly:"{poly_text}")[natural=scrub];
  way(poly:"{poly_text}")[natural=heath];
  relation(poly:"{poly_text}")[leisure=park];
  relation(poly:"{poly_text}")[leisure=garden];
  relation(poly:"{poly_text}")[leisure=recreation_ground];
  relation(poly:"{poly_text}")[leisure=nature_reserve];
  relation(poly:"{poly_text}")[leisure=golf_course];
  relation(poly:"{poly_text}")[landuse=grass];
  relation(poly:"{poly_text}")[landuse=forest];
  relation(poly:"{poly_text}")[landuse=meadow];
  relation(poly:"{poly_text}")[landuse=village_green];
  relation(poly:"{poly_text}")[landuse=recreation_ground];
  relation(poly:"{poly_text}")[natural=wood];
  relation(poly:"{poly_text}")[natural=grassland];
  relation(poly:"{poly_text}")[natural=scrub];
  relation(poly:"{poly_text}")[natural=heath];
);
out tags geom;
"""


def fetch_overpass(query: str) -> Dict:
    endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.openstreetmap.ru/api/interpreter",
    ]
    payload = urllib.parse.urlencode({"data": query}).encode("utf-8")
    last_err: Optional[Exception] = None
    for url in endpoints:
        try:
            req = urllib.request.Request(url, data=payload, method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
            with urllib.request.urlopen(req, timeout=300) as resp:
                raw = resp.read().decode("utf-8")
            return json.loads(raw)
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
    if last_err is None:
        raise RuntimeError("Failed to fetch Overpass data")
    raise RuntimeError(f"Failed to fetch Overpass data: {last_err}")


def is_green(tags: Dict[str, str]) -> bool:
    leisure = tags.get("leisure", "")
    landuse = tags.get("landuse", "")
    natural = tags.get("natural", "")
    return leisure in GREEN_LEISURE or landuse in GREEN_LANDUSE or natural in GREEN_NATURAL


def is_water(tags: Dict[str, str]) -> bool:
    natural = tags.get("natural", "")
    waterway = tags.get("waterway", "")
    landuse = tags.get("landuse", "")
    return (
        natural in WATER_NATURAL
        or "water" in tags
        or waterway in WATER_WATERWAY
        or landuse in WATER_LANDUSE
    )


def is_building(tags: Dict[str, str]) -> bool:
    b = tags.get("building")
    return b is not None and b != "no"


def is_road(tags: Dict[str, str]) -> bool:
    h = tags.get("highway")
    return bool(h and h not in EXCLUDED_HIGHWAYS)


def parse_meter_value(raw: Optional[str]) -> Optional[float]:
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        value = float(raw)
        return value if value == value else None

    match = re.search(r"[+-]?\d+(?:\.\d+)?", str(raw))
    if not match:
        return None
    try:
        return float(match.group(0))
    except ValueError:
        return None


def building_record_from_ring(bdid: int, ring: Sequence[Sequence[float]], tags: Dict[str, str]) -> Dict:
    record: Dict[str, object] = {"bdid": bdid, "path": ring}

    height_m = parse_meter_value(tags.get("height"))
    min_height_m = parse_meter_value(tags.get("min_height"))
    levels = parse_meter_value(tags.get("building:levels"))

    if height_m is not None and height_m > 0:
        record["heightMeters"] = height_m
    if min_height_m is not None and min_height_m > 0:
        record["minHeightMeters"] = min_height_m
    if levels is not None and levels > 0:
        record["levels"] = levels
        if "heightMeters" not in record:
            record["heightMeters"] = levels * DEFAULT_FLOOR_HEIGHT_METERS

    return record


def ring_from_geometry(geom: Sequence[Dict[str, float]]) -> Optional[List[List[float]]]:
    if not geom or len(geom) < 4:
        return None
    first = geom[0]
    last = geom[-1]
    # Require closed ring for polygon-like objects.
    if first.get("lat") != last.get("lat") or first.get("lon") != last.get("lon"):
        return None
    ring = [[float(p["lat"]), float(p["lon"])] for p in geom[:-1]]
    return ring if len(ring) >= 3 else None


def line_from_geometry(geom: Sequence[Dict[str, float]]) -> Optional[List[List[float]]]:
    if not geom or len(geom) < 2:
        return None
    return [[float(p["lon"]), float(p["lat"])] for p in geom]


def signature_path(path_latlon: Sequence[Sequence[float]]) -> Tuple[Tuple[float, float], ...]:
    return tuple((round(float(a), 7), round(float(b), 7)) for a, b in path_latlon)


def relation_outer_rings(rel: Dict) -> Iterable[List[List[float]]]:
    members = rel.get("members") or []
    for m in members:
        if m.get("role") != "outer":
            continue
        if m.get("type") != "way":
            continue
        geom = m.get("geometry")
        if not geom:
            continue
        ring = ring_from_geometry(geom)
        if ring:
            yield ring


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract OSM features and convert to QGC formats")
    parser.add_argument(
        "--points",
        required=True,
        help='Semicolon-separated "lat,lon" points, e.g. "23.1,113.2;23.0,113.2;23.0,113.3;23.1,113.3"',
    )
    parser.add_argument("--out-dir", default="docs/osm_extract", help="Output directory")
    args = parser.parse_args()

    points = parse_points(args.points)
    poly_text = to_poly_string(points)

    print("[1/4] Querying Overpass ...")
    data = fetch_overpass(overpass_query(poly_text))
    elements = data.get("elements", [])
    print(f"Fetched elements: {len(elements)}")

    green_paths: List[List[List[float]]] = []
    water_paths: List[List[List[float]]] = []
    building_records: List[Dict] = []
    roads_features: List[Dict] = []

    seen_green = set()
    seen_water = set()
    seen_building = set()

    print("[2/4] Parsing ways ...")
    for e in elements:
        et = e.get("type")
        tags = e.get("tags") or {}

        if et == "way":
            geom = e.get("geometry") or []

            if is_road(tags):
                line = line_from_geometry(geom)
                if line:
                    props = dict(tags)
                    props["@id"] = f"way/{e.get('id')}"
                    roads_features.append(
                        {
                            "type": "Feature",
                            "properties": props,
                            "geometry": {"type": "LineString", "coordinates": line},
                        }
                    )

            ring = ring_from_geometry(geom)
            if ring:
                sig = signature_path(ring)
                if is_building(tags) and sig not in seen_building:
                    seen_building.add(sig)
                    building_records.append(building_record_from_ring(len(building_records) + 1, ring, tags))
                if is_water(tags) and sig not in seen_water:
                    seen_water.add(sig)
                    water_paths.append(ring)
                if is_green(tags) and sig not in seen_green:
                    seen_green.add(sig)
                    green_paths.append(ring)

        elif et == "relation":
            # For multipolygons: keep outer rings only.
            if not (is_building(tags) or is_water(tags) or is_green(tags)):
                continue
            for ring in relation_outer_rings(e):
                sig = signature_path(ring)
                if is_building(tags) and sig not in seen_building:
                    seen_building.add(sig)
                    building_records.append(building_record_from_ring(len(building_records) + 1, ring, tags))
                if is_water(tags) and sig not in seen_water:
                    seen_water.add(sig)
                    water_paths.append(ring)
                if is_green(tags) and sig not in seen_green:
                    seen_green.add(sig)
                    green_paths.append(ring)

    print("[3/4] Converting to target schema ...")
    greenlands = [{"gid": i + 1, "path": p} for i, p in enumerate(green_paths)]
    waters = [{"wid": i + 1, "path": p} for i, p in enumerate(water_paths)]
    buildings = building_records
    roads_geojson = {"type": "FeatureCollection", "features": roads_features}

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / "greenlands.json").write_text(
        json.dumps(greenlands, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out_dir / "waters.json").write_text(
        json.dumps(waters, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out_dir / "buildings.json").write_text(
        json.dumps(buildings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out_dir / "roads.geojson").write_text(
        json.dumps(roads_geojson, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    # Also generate QSettings-ready snippets for quick paste to QGroundControl.ini
    snippet = (
        "[Greenland]\n"
        f"greenlandsJson={json.dumps(json.dumps(greenlands, ensure_ascii=False))}\n"
        f"nextId={len(greenlands) + 1}\n\n"
        "[Water]\n"
        f"watersJson={json.dumps(json.dumps(waters, ensure_ascii=False))}\n"
        f"nextId={len(waters) + 1}\n\n"
        "[BuildingDense]\n"
        f"buildingsJson={json.dumps(json.dumps(buildings, ensure_ascii=False))}\n"
        f"nextId={len(buildings) + 1}\n"
    )
    (out_dir / "qgc_settings_snippet.ini").write_text(snippet, encoding="utf-8")

    summary = {
        "greenlands": len(greenlands),
        "waters": len(waters),
        "buildings": len(buildings),
        "buildings_with_height": sum(1 for record in buildings if float(record.get("heightMeters", 0) or 0) > 0),
        "roads": len(roads_features),
        "out_dir": str(out_dir.resolve()),
    }
    (out_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print("[4/4] Done")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
