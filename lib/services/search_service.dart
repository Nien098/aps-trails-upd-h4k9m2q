import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/region.dart';
import 'trail_store.dart';

enum SearchResultType { trail, street }

class SearchResult {
  SearchResult({required this.name, required this.position, required this.type});
  final String name;
  final LatLng position;
  final SearchResultType type;
}

/// Offline search across the user's own trails and a bundled street-name
/// index, so the search FAB can jump the map camera to either — the same way
/// [GuideScreen._recenter] jumps to GPS position.
///
/// The street index (`assets/data/streets.sqlite`, built by
/// `tools/build_streets_db.py` from OSM/Overpass data) uses an FTS5 virtual
/// table. FTS5 needs a real SQLite build compiled with it — Android's
/// OS-provided SQLite (what the `sqflite` plugin talks to via platform
/// channel) often doesn't have it, which is why this used to fail silently
/// on real devices. `package:sqlite3` bundles its own native SQLite (FTS5
/// included) and talks to it directly via FFI, sidestepping the OS build
/// entirely — that's why this uses `sqlite3.open()`, not `sqflite`, even
/// though [TrailStore] (no FTS5 needed there) still uses `sqflite` fine.
/// The DB ships read-only in the asset bundle, but becomes writable on-device
/// once a downloaded region adds its own streets (see [RegionDownloader]) —
/// so it's copied out of the asset bundle exactly like the bundled basemap in
/// [OfflineMap], not opened read-only.
class SearchService {
  SearchService._();
  static final SearchService instance = SearchService._();

  static Future<String>? _dbPathReady;
  sqlite3.Database? _db;

  static Future<String> _ensureCopied() => _dbPathReady ??= _copy();

  static Future<String> _copy() async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/streets.sqlite');
    final data = await rootBundle.load('assets/data/streets.sqlite');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (!dest.existsSync() || dest.lengthSync() != bytes.length) {
      await dest.writeAsBytes(bytes, flush: true);
    }
    return dest.path;
  }

  /// `sqlite3` is synchronous (direct FFI call, no platform channel) — kept
  /// as an `async` method anyway so call sites don't care that opening is a
  /// one-time file-copy-then-sync-open rather than a true async DB open.
  Future<sqlite3.Database> get _database async {
    if (_db != null) return _db!;
    final path = await _ensureCopied();
    _db = sqlite3.sqlite3.open(path);
    return _db!;
  }

  /// Adds a downloaded region's streets to the on-device index (called by
  /// [RegionDownloader] after fetching them from Overpass). The bundled
  /// asset only ever covers the regions it was built against
  /// ([kRegions]) — this is what makes a later *downloaded* region
  /// searchable too, without waiting for a new app build.
  Future<void> addStreets(
      String regionId, List<({String name, double lat, double lon})> rows) async {
    final db = await _database;
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM streets WHERE region_id = ?', [regionId]);
      final stmt = db.prepare(
          'INSERT INTO streets(name, region_id, lat, lon) VALUES (?, ?, ?, ?)');
      try {
        for (final r in rows) {
          stmt.execute([r.name, regionId, r.lat, r.lon]);
        }
      } finally {
        stmt.close();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Sanitizes free text for FTS5 MATCH syntax (strips characters that would
  /// otherwise break the query, e.g. quotes/colons) and appends a prefix
  /// wildcard so "coas" matches "Coast Meridian Road".
  static String? _ftsQuery(String raw) {
    final cleaned =
        raw.replaceAll(RegExp(r'["*:^]'), ' ').trim();
    if (cleaned.isEmpty) return null;
    return '${cleaned.split(RegExp(r'\s+')).join(' ')}*';
  }

  /// [confineTo], when set, drops any result that isn't reachable by a plain
  /// camera pan on that region's already-loaded basemap — a result sitting
  /// in a different (separately downloaded) region's own pmtiles file would
  /// otherwise jump the camera to nothing rendered. Screens that can't swap
  /// their basemap mid-session (GuideScreen, AuthorScreen — both tied to one
  /// trail's region) pass their current region; BrowseMapScreen, which can
  /// swap basemaps on demand, passes null.
  Future<List<SearchResult>> search(String query, {Region? confineTo}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    bool reachable(LatLng pos) =>
        confineTo == null || regionForPoint(pos).mapAsset == confineTo.mapAsset;

    final trailRows = await TrailStore.instance.searchByName(q);
    final trails = [
      for (final r in trailRows)
        if (r.position != null && reachable(r.position!))
          SearchResult(
              name: r.name, position: r.position!, type: SearchResultType.trail),
    ];

    final ftsQuery = _ftsQuery(q);
    var streets = <SearchResult>[];
    if (ftsQuery != null) {
      final db = await _database;
      final rows = db.select(
        '''
        SELECT s.name, s.lat, s.lon FROM streets s
        JOIN streets_fts f ON f.rowid = s.id
        WHERE streets_fts MATCH ?
        LIMIT 20
        ''',
        [ftsQuery],
      );
      streets = [
        for (final r in rows)
          SearchResult(
            name: r['name'] as String,
            position: LatLng((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
            type: SearchResultType.street,
          ),
      ].where((r) => reachable(r.position)).toList();
    }

    // Trails first — the user's own curated content is more likely what
    // they meant than an arbitrary OSM street name.
    return [...trails, ...streets].take(20).toList();
  }
}
