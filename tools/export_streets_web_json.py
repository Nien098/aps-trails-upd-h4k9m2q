#!/usr/bin/env python3
"""Exports assets/data/streets.sqlite to assets/data/streets_web.json.

The web app can't open streets.sqlite directly: FTS5 lookups go through
package:sqlite3, which is dart:ffi-based and doesn't compile for web (see
lib/services/search_service_io.dart's class doc). Instead, the web variant
(search_service_stub.dart) loads this flat JSON array once via rootBundle
and does simple in-memory prefix matching — entirely offline, same as
mobile, just without FTS5.

Run this any time streets.sqlite changes (after tools/build_streets_db.py,
or after a manual edit) — it's a pure local read of the existing sqlite
file, no network access needed.

Usage:
    python tools/export_streets_web_json.py
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "assets" / "data" / "streets.sqlite"
OUT_PATH = Path(__file__).resolve().parent.parent / "assets" / "data" / "streets_web.json"


def main() -> None:
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        "SELECT name, region_id, lat, lon, kind FROM streets ORDER BY name"
    ).fetchall()
    conn.close()

    data = [
        {"name": name, "region_id": region_id, "lat": lat, "lon": lon, "kind": kind}
        for name, region_id, lat, lon, kind in rows
    ]
    OUT_PATH.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")

    size_kb = OUT_PATH.stat().st_size / 1e3
    print(f"Wrote {OUT_PATH} ({len(data)} rows, {size_kb:.0f} KB)")


if __name__ == "__main__":
    main()
