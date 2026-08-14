import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

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
/// `tools/build_streets_db.py` from OSM/Overpass data) ships read-only, but
/// becomes writable on-device once a downloaded region adds its own streets
/// (see [RegionDownloader]) — so it's copied out of the asset bundle exactly
/// like the bundled basemap in [OfflineMap], not opened read-only.
class SearchService {
  SearchService._();
  static final SearchService instance = SearchService._();

  static Future<String>? _dbPathReady;
  sqflite.Database? _db;

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

  Future<sqflite.Database> get _database async {
    if (_db != null) return _db!;
    final path = await _ensureCopied();
    _db = await sqflite.openDatabase(path);
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
    await db.transaction((txn) async {
      await txn.delete('streets', where: 'region_id = ?', whereArgs: [regionId]);
      for (final r in rows) {
        await txn.insert('streets',
            {'name': r.name, 'region_id': regionId, 'lat': r.lat, 'lon': r.lon});
      }
    });
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

  Future<List<SearchResult>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final trailRows = await TrailStore.instance.searchByName(q);
    final trails = [
      for (final r in trailRows)
        if (r.position != null)
          SearchResult(
              name: r.name, position: r.position!, type: SearchResultType.trail),
    ];

    final ftsQuery = _ftsQuery(q);
    var streets = <SearchResult>[];
    if (ftsQuery != null) {
      final db = await _database;
      final rows = await db.rawQuery(
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
      ];
    }

    // Trails first — the user's own curated content is more likely what
    // they meant than an arbitrary OSM street name.
    return [...trails, ...streets].take(20).toList();
  }
}
