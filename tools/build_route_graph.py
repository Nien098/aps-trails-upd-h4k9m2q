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

# Not a real "region" in lib/models/region.dart (no basemap ships for it) —
# a diagnostic bundle to prove/disprove whether the on-device download's
# 60-cell/45s caps (region_downloader.dart), not Jakarta's density itself,
# are why a *downloaded* Jakarta region's route graph came out empty.
# RouteGraphStore.waysInBounds() queries purely by geographic bbox overlap,
# not by region_id/mapAsset — so this data becomes usable for routing
# anywhere its bbox overlaps the user's own already-downloaded Jakarta
# basemap, with no new Region/pmtiles/kRegions entry needed at all.
#
# Deliberately just central/downtown Jakarta, not the full Jabodetabek
# metro the user originally asked for — a full-metro test of this density
# extrapolated to hundreds of MB (a 0.1x0.1deg sample alone produced 42k
# elements), which isn't a reasonable one-off bundle size. This smaller
# core (~Central/South Jakarta, inside the main ring road) is still dense
# enough to prove the point.
REGIONS.append(("jakarta_metro_test", -6.25, 106.75, -6.10, 106.87))

# Same idea, covering urban Tangerang (city + BSD, not the whole sprawling
# Tangerang Regency) — where the user's brother has actually been testing.
REGIONS.append(("tangerang_test", -6.25, 106.58, -6.10, 106.70))

# Per-region cell size override — Jakarta is dense enough that even the
# default CELL_DEG (0.15, fine for Southwest BC) reliably 504s at the
# Overpass server itself regardless of client-side patience/retries
# (confirmed empirically: a cell 1/36th that size still took 17.7s for a
# small slice of central Jakarta). Smaller cells keep each individual
# request small enough to actually complete.
CELL_OVERRIDES = {"jakarta_metro_test": 0.05, "tangerang_test": 0.05}

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


def _cells(south: float, west: float, north: float, east: float, cell_deg: float):
    lat = south
    while lat < north:
        lat2 = min(lat + cell_deg, north)
        lon = west
        while lon < east:
            lon2 = min(lon + cell_deg, east)
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
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=200) as resp:
                return json.loads(resp.read())["elements"]
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == 3:
                # Give up on just this one cell, not the whole region — a
                # cell that's permanently too dense/large for Overpass to
                # answer (confirmed happens even at small sizes for central
                # Jakarta) shouldn't lose every other cell's already-fetched
                # data by crashing the script.
                print(f"    giving up on this cell after 4 attempts: {e}",
                      file=sys.stderr)
                return []
            print(f"    retrying after error: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    return []


def fetch_region(south: float, west: float, north: float, east: float,
                  cell_deg: float = CELL_DEG) -> list[dict]:
    cells = list(_cells(south, west, north, east, cell_deg))
    by_id: dict[int, dict] = {}
    failed_cells = 0
    for i, (s, w, n, e) in enumerate(cells):
        print(f"  cell {i + 1}/{len(cells)} ({s:.3f},{w:.3f},{n:.3f},{e:.3f})...")
        elements = _fetch_cell(s, w, n, e)
        if not elements:
            failed_cells += 1
        for el in elements:
            if el.get("type") == "way":
                by_id[el["id"]] = el  # dedupe ways spanning a cell boundary
        time.sleep(2)  # be polite to the shared public Overpass instance
    if failed_cells:
        print(f"  {failed_cells}/{len(cells)} cells returned nothing "
              f"(permanently failed or genuinely empty)", file=sys.stderr)
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
        cell_deg = CELL_OVERRIDES.get(region_id, CELL_DEG)
        print(f"Fetching {region_id} ({south},{west},{north},{east}), "
              f"cell size {cell_deg}deg...")
        elements = fetch_region(south, west, north, east, cell_deg)

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
