import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/region.dart';

enum SearchResultType {
  trail,

  /// A named OSM trail/path (e.g. "Trans Canada Trail") from the bundled
  /// street/trail index — carries a [SearchResult.locality] like [street]
  /// does. Web has no user-saved-trail database (desktop's Open/Save works
  /// on one `.trail` file at a time, not a searchable list), so this is the
  /// only kind of "trail" result the web app can ever produce.
  namedTrail,
  street,
}

class SearchResult {
  SearchResult({required this.name, required this.position, required this.type, this.locality});
  final String name;
  final LatLng position;
  final SearchResultType type;
  final String? locality;
}

/// Mirrors search_service_io.dart's `_bundledCityNames`/`_localityFor` —
/// kept as an exact duplicate rather than a shared import, matching this
/// project's existing conditional-export pattern (see
/// route_graph_store_stub.dart/_io.dart, which duplicate `RouteWay` the
/// same way) so each platform variant stays fully self-contained.
const Map<String, String> _bundledCityNames = {
  'coquitlam': 'Coquitlam',
  'port_coquitlam': 'Port Coquitlam',
  'maple_ridge': 'Maple Ridge',
  'lynn_valley': 'Lynn Valley (North Van)',
  'capilano': 'Capilano (North Van)',
  'west_van': 'West Vancouver',
  'vancouver': 'Vancouver',
  'tsawwassen': 'Tsawwassen',
  'abbotsford': 'Abbotsford',
  'chilliwack': 'Chilliwack',
  'squamish': 'Squamish',
  'whistler': 'Whistler',
  'victoria': 'Victoria',
  'jakarta_metro_test': 'Jakarta',
  'tangerang_test': 'Tangerang',
};

String _localityFor(String regionId) =>
    _bundledCityNames[regionId] ??
    allRegions().firstWhere((r) => r.id == regionId, orElse: () => Region(
      id: regionId, name: regionId, center: const LatLng(0, 0),
      south: 0, west: 0, north: 0, east: 0,
    )).name;

class _Row {
  _Row(this.name, this.regionId, this.lat, this.lon, this.kind);
  final String name;
  final String regionId;
  final double lat;
  final double lon;
  final String kind;
}

/// Web equivalent of `search_service_io.dart` — same public API
/// (`SearchService.instance.search(...)`), same underlying data, but no
/// `package:sqlite3` (dart:ffi doesn't compile for web) and no FTS5. Loads
/// `assets/data/streets_web.json` — a flat export of streets.sqlite kept in
/// sync by `tools/export_streets_web_json.py` — once via `rootBundle`, then
/// does simple case-insensitive per-word prefix matching in memory.
///
/// This is small enough (tens of thousands of rows, a few MB of JSON) that
/// an in-memory linear scan per keystroke is not a real performance concern
/// — no index needed the way FTS5 gives mobile one. If this index ever
/// grows enough to matter, the fix is a proper build-time word-prefix map,
/// not reaching for something like `sqlite3` on web (which fundamentally
/// can't work here, see `search_service_io.dart`'s doc).
///
/// The web app has no user-saved-trail database (see
/// [SearchResultType.namedTrail]'s doc), so this never merges in a
/// `TrailStore`-style first source the way the io variant does — every
/// result comes from the bundled index.
class SearchService {
  SearchService._();
  static final SearchService instance = SearchService._();

  List<_Row>? _rows;

  Future<List<_Row>> _ensureLoaded() async {
    final cached = _rows;
    if (cached != null) return cached;
    final text = await rootBundle.loadString('assets/data/streets_web.json');
    final decoded = jsonDecode(text) as List;
    final rows = [
      for (final r in decoded.cast<Map<String, dynamic>>())
        _Row(
          r['name'] as String,
          r['region_id'] as String,
          (r['lat'] as num).toDouble(),
          (r['lon'] as num).toDouble(),
          r['kind'] as String,
        ),
    ];
    _rows = rows;
    return rows;
  }

  /// No-op-adjacent: the web app doesn't do region downloading
  /// ([RegionDownloader] isn't part of `main_web.dart`'s dependency graph),
  /// so this is never actually called in the web app today. Implemented
  /// in-memory-only (not persisted — a page reload loses it, same as every
  /// other piece of web session state) purely to keep this class's public
  /// API identical to the io variant's, in case that ever changes.
  Future<void> addStreets(String regionId,
      List<({String name, double lat, double lon, String kind})> rows) async {
    final existing = await _ensureLoaded();
    existing.removeWhere((r) => r.regionId == regionId);
    existing.addAll([
      for (final r in rows) _Row(r.name, regionId, r.lat, r.lon, r.kind),
    ]);
  }

  Future<List<SearchResult>> search(String query, {Region? confineTo}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final words = q.split(RegExp(r'\s+'));

    bool reachable(LatLng pos) =>
        confineTo == null || regionForPoint(pos).mapAsset == confineTo.mapAsset;

    final rows = await _ensureLoaded();
    final results = <SearchResult>[];
    for (final r in rows) {
      final nameLower = r.name.toLowerCase();
      // Every typed word must prefix-match somewhere in the name — mirrors
      // FTS5's per-word-prefix MATCH semantics closely enough for this UI
      // (e.g. "coas mer" still finds "Coast Meridian Road").
      final matches = words.every((w) => nameLower
          .split(RegExp(r'\s+'))
          .any((part) => part.startsWith(w)));
      if (!matches) continue;
      final pos = LatLng(r.lat, r.lon);
      if (!reachable(pos)) continue;
      results.add(SearchResult(
        name: r.name,
        position: pos,
        type: r.kind == 'trail' ? SearchResultType.namedTrail : SearchResultType.street,
        locality: _localityFor(r.regionId),
      ));
      if (results.length >= 20) break;
    }
    return results;
  }
}
