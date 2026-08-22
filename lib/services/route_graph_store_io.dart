import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// A road/trail/sidewalk way's geometry, as stored offline — see
/// `tools/build_route_graph.py`. [kind] mirrors
/// [TrailRouter._isRoad]/`_isTrail`/`_isSidewalk`'s classification.
typedef RouteWay = ({List<LatLng> coords, String kind});

/// Offline road/trail/sidewalk network (`assets/data/route_graph.sqlite`,
/// built by `tools/build_route_graph.py` from OSM/Overpass data), so
/// [TrailRouter]'s Dijkstra graph isn't limited to whatever's currently
/// rendered on screen (`queryRenderedFeaturesInRect` only sees the live
/// viewport). Uses `package:sqlite3` rather than `sqflite` for the same
/// reason as [SearchService]'s streets index: this needs the R-tree virtual-
/// table module for fast bounding-box lookups, and `sqflite`'s OS-provided
/// SQLite can't be trusted to have every extension compiled in.
class RouteGraphStore {
  RouteGraphStore._();
  static final RouteGraphStore instance = RouteGraphStore._();

  static Future<String>? _dbPathReady;
  sqlite3.Database? _db;

  static Future<String> _ensureCopied() => _dbPathReady ??= _copy();

  static Future<String> _copy() async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/route_graph.sqlite');
    final data = await rootBundle.load('assets/data/route_graph.sqlite');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (!dest.existsSync() || dest.lengthSync() != bytes.length) {
      await dest.writeAsBytes(bytes, flush: true);
    }
    return dest.path;
  }

  Future<sqlite3.Database> get _database async {
    if (_db != null) return _db!;
    final path = await _ensureCopied();
    _db = sqlite3.sqlite3.open(path);
    return _db!;
  }

  /// Ways whose bounding box overlaps [bounds] — a superset of ways that
  /// actually cross it (R-tree matches by bbox, not exact geometry), which
  /// is fine here: [TrailRouter._Graph.addLatLngChain] only cares about
  /// real shared coordinates, so a handful of extra nearby-but-not-quite
  /// overlapping ways just adds unused nodes, not incorrect routing.
  Future<List<RouteWay>> waysInBounds(LatLngBounds bounds) async {
    final db = await _database;
    final rows = db.select(
      '''
      SELECT w.kind, w.coords FROM ways w
      JOIN ways_rtree r ON r.id = w.id
      WHERE r.min_lon <= ? AND r.max_lon >= ?
        AND r.min_lat <= ? AND r.max_lat >= ?
      ''',
      [
        bounds.northeast.longitude, bounds.southwest.longitude,
        bounds.northeast.latitude, bounds.southwest.latitude,
      ],
    );
    return [
      for (final r in rows)
        (
          kind: r['kind'] as String,
          coords: [
            for (final c in jsonDecode(r['coords'] as String) as List)
              LatLng((c[0] as num).toDouble(), (c[1] as num).toDouble()),
          ],
        ),
    ];
  }

  /// Adds a downloaded region's ways to the on-device graph (called by
  /// [RegionDownloader] after fetching them from Overpass) — mirrors
  /// [SearchService.addStreets]. The bundled asset only ever covers the
  /// regions it was built against ([kRegions]); this is what extends route-
  /// graph coverage to a later *downloaded* region without a new app build.
  Future<void> addWays(String regionId, List<RouteWay> ways) async {
    final db = await _database;
    db.execute('BEGIN');
    try {
      final oldIds = db.select('SELECT id FROM ways WHERE region_id = ?', [regionId]);
      final delRtree = db.prepare('DELETE FROM ways_rtree WHERE id = ?');
      try {
        for (final r in oldIds) {
          delRtree.execute([r['id']]);
        }
      } finally {
        delRtree.close();
      }
      db.execute('DELETE FROM ways WHERE region_id = ?', [regionId]);

      final insertWay = db.prepare(
          'INSERT INTO ways(region_id, kind, coords) VALUES (?, ?, ?)');
      final insertRtree = db.prepare(
          'INSERT INTO ways_rtree(id, min_lon, max_lon, min_lat, max_lat) '
          'VALUES (?, ?, ?, ?, ?)');
      try {
        for (final w in ways) {
          if (w.coords.isEmpty) continue;
          insertWay.execute([
            regionId,
            w.kind,
            jsonEncode([for (final p in w.coords) [p.latitude, p.longitude]]),
          ]);
          final id = db.lastInsertRowId;
          final lons = [for (final p in w.coords) p.longitude];
          final lats = [for (final p in w.coords) p.latitude];
          insertRtree.execute([
            id,
            lons.reduce((a, b) => a < b ? a : b),
            lons.reduce((a, b) => a > b ? a : b),
            lats.reduce((a, b) => a < b ? a : b),
            lats.reduce((a, b) => a > b ? a : b),
          ]);
        }
      } finally {
        insertWay.close();
        insertRtree.close();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
