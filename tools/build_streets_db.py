#!/usr/bin/env python3
"""Builds assets/data/streets.sqlite — a bundled, offline street/trail-name
index.

Queries the Overpass API for named roads and trails (footway/path/cycleway/
bridleway) within each bundled region's bbox (see lib/models/region.dart's
kRegions), dedupes by name, picks a representative point per name (midpoint
of the longest matching way), and writes them to a small SQLite database
with an FTS5 index so the app can search street/trail names entirely
offline. Each row's `kind` column ('street' or 'trail') is what lets the
app distinguish a real, named OSM trail (e.g. "Trans Canada Trail") from an
ordinary street in search results.

After rebuilding this file, also re-run tools/export_streets_web_json.py —
the web app can't use sqlite3 (no FFI on web), so it searches a flat JSON
export of this same data instead; the two files drift apart otherwise.

Usage:
    python tools/build_streets_db.py [region_id ...]

With no arguments, rebuilds every bundled region. Pass one or more region ids
(e.g. `python tools/build_streets_db.py squamish whistler`) to only refresh
those regions — useful when re-running after a single region's OSM data
changes, without waiting on a full 13-region rebuild.

Kept in sync by hand with lib/models/region.dart's kRegions — if a region is
added/renamed there, update REGIONS below to match.
"""
from __future__ import annotations

import json
import math
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OUT_PATH = Path(__file__).resolve().parent.parent / "assets" / "data" / "streets.sqlite"

# Mirrors lib/models/region.dart kRegions (id, south, west, north, east).
REGIONS = [
    ("coquitlam", 49.22, -122.90, 49.31, -122.75),
    ("port_coquitlam", 49.22, -122.82, 49.31, -122.68),
    ("maple_ridge", 49.18, -122.72, 49.30, -122.48),
    ("lynn_valley", 49.32, -123.06, 49.43, -122.98),
    ("capilano", 49.32, -123.16, 49.41, -123.08),
    ("west_van", 49.33, -123.31, 49.43, -123.16),
    ("vancouver", 49.20, -123.22, 49.32, -123.02),
    ("tsawwassen", 48.96, -123.17, 49.10, -122.95),
    ("abbotsford", 49.00, -122.42, 49.12, -122.18),
    ("chilliwack", 49.08, -122.10, 49.24, -121.80),
    ("squamish", 49.60, -123.28, 49.80, -123.05),
    ("whistler", 50.05, -123.05, 50.20, -122.85),
    ("victoria", 48.35, -123.50, 48.55, -123.25),
]

# Diagnostic-only bundles (see tools/build_route_graph.py's matching
# entries) — same bboxes, so a downloaded map covering these areas gets
# both routing AND street-name search working, not just one.
REGIONS.append(("jakarta_metro_test", -6.25, 106.75, -6.10, 106.87))
REGIONS.append(("tangerang_test", -6.25, 106.58, -6.10, 106.70))

# Overpass 504s on even small requests over these areas at the default
# single-request-per-region approach (confirmed empirically for the route
# graph build) — tile like build_route_graph.py does.
CELL_OVERRIDES = {"jakarta_metro_test": 0.05, "tangerang_test": 0.05}
DEFAULT_CELL_DEG = 0.20  # generous — the 13 original small regions never needed tiling

# highway=* values indexed as a named *trail* rather than a street — these
# used to be excluded entirely (overlapping the app's own trail data seemed
# redundant), but a named trail like "Trans Canada Trail" is exactly the
# kind of thing search should be able to jump the camera to, same as a
# street name (2026-08-23).
TRAIL_HIGHWAY = {"footway", "path", "cycleway", "bridleway"}

# highway=* values that aren't meaningful for either street or trail search
# (tiny stair segments, indoor routing, non-built features) — kept as a
# tunable denylist.
EXCLUDED_HIGHWAY = {
    "steps", "corridor", "proposed", "construction", "razed", "abandoned",
}


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
        f'way["highway"]["name"]({south},{west},{north},{east});'
        "out tags geom;"
    )
    data = urllib.parse.urlencode({"data": query}).encode()
    req = urllib.request.Request(
        OVERPASS_URL, data=data,
        headers={"User-Agent": "TrailGuide-streets-build/1.0"},
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=200) as resp:
                return json.loads(resp.read())["elements"]
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == 3:
                print(f"    giving up on this cell after 4 attempts: {e}",
                      file=sys.stderr)
                return []
            print(f"    retrying after error: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    return []


def fetch_region(south: float, west: float, north: float, east: float,
                  cell_deg: float = DEFAULT_CELL_DEG) -> list[dict]:
    cells = list(_cells(south, west, north, east, cell_deg))
    by_id: dict[int, dict] = {}
    for i, (s, w, n, e) in enumerate(cells):
        if len(cells) > 1:
            print(f"  cell {i + 1}/{len(cells)} ({s:.3f},{w:.3f},{n:.3f},{e:.3f})...")
        for el in _fetch_cell(s, w, n, e):
            if el.get("type") == "way" and el.get("id") is not None:
                by_id[el["id"]] = el  # dedupe ways spanning a cell boundary
        time.sleep(2 if len(cells) > 1 else 0)
    return list(by_id.values())


def way_length_m(geom: list[dict]) -> float:
    total = 0.0
    for a, b in zip(geom, geom[1:]):
        dlat = (b["lat"] - a["lat"]) * 111_320
        dlon = (b["lon"] - a["lon"]) * 111_320 * math.cos(math.radians(a["lat"]))
        total += math.hypot(dlat, dlon)
    return total


def representative_point(geom: list[dict]) -> tuple[float, float]:
    mid = geom[len(geom) // 2]
    return mid["lat"], mid["lon"]


def dedupe_streets(elements: list[dict]) -> dict[str, tuple[float, float, str]]:
    best_len: dict[str, float] = {}
    best_point: dict[str, tuple[float, float]] = {}
    best_kind: dict[str, str] = {}
    for el in elements:
        if el.get("type") != "way":
            continue
        tags = el.get("tags", {})
        name = tags.get("name", "").strip()
        highway = tags.get("highway", "")
        geom = el.get("geometry")
        if not name or not geom or highway in EXCLUDED_HIGHWAY:
            continue
        length = way_length_m(geom)
        if length > best_len.get(name, -1):
            best_len[name] = length
            best_point[name] = representative_point(geom)
            best_kind[name] = "trail" if highway in TRAIL_HIGHWAY else "street"
    return {name: (*best_point[name], best_kind[name]) for name in best_point}


def build_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS streets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            region_id TEXT NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            kind TEXT NOT NULL DEFAULT 'street'
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS streets_fts USING fts5(
            name, content='streets', content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS streets_ai AFTER INSERT ON streets BEGIN
            INSERT INTO streets_fts(rowid, name) VALUES (new.id, new.name);
        END;
        CREATE TRIGGER IF NOT EXISTS streets_ad AFTER DELETE ON streets BEGIN
            INSERT INTO streets_fts(streets_fts, rowid, name) VALUES('delete', old.id, old.name);
        END;
        CREATE TRIGGER IF NOT EXISTS streets_au AFTER UPDATE ON streets BEGIN
            INSERT INTO streets_fts(streets_fts, rowid, name) VALUES('delete', old.id, old.name);
            INSERT INTO streets_fts(rowid, name) VALUES (new.id, new.name);
        END;
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
        cell_deg = CELL_OVERRIDES.get(region_id, DEFAULT_CELL_DEG)
        print(f"Fetching {region_id} ({south},{west},{north},{east}), "
              f"cell size {cell_deg}deg...")
        elements = fetch_region(south, west, north, east, cell_deg)
        streets = dedupe_streets(elements)
        print(f"  {len(streets)} uniquely-named streets")
        conn.execute("DELETE FROM streets WHERE region_id = ?", (region_id,))
        conn.executemany(
            "INSERT INTO streets(name, region_id, lat, lon, kind) VALUES (?, ?, ?, ?, ?)",
            [(name, region_id, lat, lon, kind)
             for name, (lat, lon, kind) in streets.items()],
        )
        conn.commit()
        if len(regions) > 1:
            time.sleep(2)  # be polite to the shared public Overpass instance

    conn.execute("VACUUM")
    conn.execute("PRAGMA optimize")
    conn.close()

    size_mb = OUT_PATH.stat().st_size / 1e6
    print(f"Wrote {OUT_PATH} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
