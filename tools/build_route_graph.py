#!/usr/bin/env python3
"""Builds assets/data/route_graph.sqlite — a bundled, offline routable
road/trail/sidewalk network, so TrailRouter's Dijkstra graph
(lib/services/trail_router.dart) isn't limited to whatever's currently
rendered on screen (queryRenderedFeaturesInRect only sees the live viewport).

Unlike tools/build_streets_db.py (which builds a *name* index and
deliberately excludes footways/paths), this pulls every walkable
highway=* way's full geometry — trails are the actual point of a routing
graph for a hiking app.

TrailRouter's in-memory graph connects purely by shared/near-shared
coordinates (~1m rounding, see _Graph._key in trail_router.dart), not real
OSM node IDs — so this script doesn't need to preserve OSM topology/node
IDs at all, just each way's ordered coordinate list.

Usage:
    python tools/build_route_graph.py [region_id ...]

With no arguments, rebuilds every bundled region. Kept in sync by hand with
lib/models/region.dart's kRegions.
"""
from __future__ import annotations

import json
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OUT_PATH = Path(__file__).resolve().parent.parent / "assets" / "data" / "route_graph.sqlite"

# Mirrors lib/models/region.dart kRegions (id, south, west, north, east).
REGIONS = [
    ("vancouver_mainland", 48.96, -123.31, 50.20, -121.80),
    ("victoria", 48.35, -123.50, 48.55, -123.25),
]

# highway=* -> 'road'. Everything else walkable falls through to 'trail'
# below (path/track/bridleway/steps/cycleway/pedestrian/footway), except
# footways explicitly tagged as a sidewalk/crossing -> 'sidewalk'. Mirrors
# TrailRouter._isRoad/_isTrail/_isSidewalk's Protomaps-kind-based semantics
# (trail_router.dart:101-105) so offline and live-rendered data behave
# identically once merged into the same graph.
ROAD_HIGHWAY = {
    "motorway", "trunk", "primary", "secondary", "tertiary",
    "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
    "unclassified", "residential", "service", "living_street", "road",
}
SIDEWALK_FOOTWAYS = {"sidewalk", "crossing"}

# Not a real walkable network edge — skip entirely (unlike build_streets_db.py,
# nothing here is excluded for being *too trail-like*).
SKIP_HIGHWAY = {"proposed", "construction", "razed", "abandoned", "corridor"}


def classify(tags: dict) -> str | None:
    highway = tags.get("highway", "")
    if highway in SKIP_HIGHWAY or not highway:
        return None
    if highway in ROAD_HIGHWAY:
        return "road"
    if highway == "footway" and tags.get("footway") in SIDEWALK_FOOTWAYS:
        return "sidewalk"
    return "trail"


# Max cell size (degrees) per Overpass request — the full bundled-region
# bboxes are far bigger than any single streets.sqlite query used to be (no
# name filter this time, every highway=* way), so a single request for the
# whole region risks the public Overpass instance's size/time limits. Tiling
# into a grid and deduping by OSM way id (ways spanning a cell boundary come
# back from more than one cell) keeps each request modest.
CELL_DEG = 0.15


def _cells(south: float, west: float, north: float, east: float):
    lat = south
    while lat < north:
        lat2 = min(lat + CELL_DEG, north)
        lon = west
        while lon < east:
            lon2 = min(lon + CELL_DEG, east)
            yield (lat, lon, lat2, lon2)
            lon = lon2
        lat = lat2


def _fetch_cell(south: float, west: float, north: float, east: float) -> list[dict]:
    query = (
        "[out:json][timeout:180];"
        f'way["highway"]({south},{west},{north},{east});'
        "out tags geom;"
    )
    data = urllib.parse.urlencode({"data": query}).encode()
    req = urllib.request.Request(
        OVERPASS_URL, data=data,
        headers={"User-Agent": "TrailGuide-route-graph-build/1.0"},
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=200) as resp:
                return json.loads(resp.read())["elements"]
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == 2:
                raise
            print(f"    retrying after error: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    return []


def fetch_region(south: float, west: float, north: float, east: float) -> list[dict]:
    cells = list(_cells(south, west, north, east))
    by_id: dict[int, dict] = {}
    for i, (s, w, n, e) in enumerate(cells):
        print(f"  cell {i + 1}/{len(cells)} ({s:.2f},{w:.2f},{n:.2f},{e:.2f})...")
        for el in _fetch_cell(s, w, n, e):
            if el.get("type") == "way":
                by_id[el["id"]] = el  # dedupe ways spanning a cell boundary
        time.sleep(1)  # be polite to the shared public Overpass instance
    return list(by_id.values())


def build_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS ways (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            region_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('road','trail','sidewalk')),
            coords TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS ways_rtree USING rtree(
            id, min_lon, max_lon, min_lat, max_lat
        );
        """
    )


def main() -> None:
    requested = set(sys.argv[1:])
    regions = [r for r in REGIONS if not requested or r[0] in requested]
    if requested and len(regions) != len(requested):
        missing = requested - {r[0] for r in regions}
        print(f"Unknown region id(s): {', '.join(sorted(missing))}", file=sys.stderr)
        sys.exit(1)

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(OUT_PATH)
    build_schema(conn)

    for region_id, south, west, north, east in regions:
        print(f"Fetching {region_id} ({south},{west},{north},{east})...")
        elements = fetch_region(south, west, north, east)

        # Delete old rows (and their rtree entries) for this region first,
        # so a re-run is idempotent.
        old_ids = [r[0] for r in conn.execute(
            "SELECT id FROM ways WHERE region_id = ?", (region_id,))]
        conn.executemany("DELETE FROM ways_rtree WHERE id = ?", [(i,) for i in old_ids])
        conn.execute("DELETE FROM ways WHERE region_id = ?", (region_id,))

        count = 0
        for el in elements:
            if el.get("type") != "way":
                continue
            geom = el.get("geometry")
            if not geom or len(geom) < 2:
                continue
            kind = classify(el.get("tags", {}))
            if kind is None:
                continue
            coords = [[p["lat"], p["lon"]] for p in geom]
            lats = [c[0] for c in coords]
            lons = [c[1] for c in coords]
            cur = conn.execute(
                "INSERT INTO ways(region_id, kind, coords) VALUES (?, ?, ?)",
                (region_id, kind, json.dumps(coords)),
            )
            way_id = cur.lastrowid
            conn.execute(
                "INSERT INTO ways_rtree(id, min_lon, max_lon, min_lat, max_lat) "
                "VALUES (?, ?, ?, ?, ?)",
                (way_id, min(lons), max(lons), min(lats), max(lats)),
            )
            count += 1
        conn.commit()
        print(f"  {count} ways")
        if len(regions) > 1:
            time.sleep(2)  # be polite to the shared public Overpass instance

    conn.execute("VACUUM")
    conn.execute("PRAGMA optimize")
    conn.close()

    size_mb = OUT_PATH.stat().st_size / 1e6
    print(f"Wrote {OUT_PATH} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
