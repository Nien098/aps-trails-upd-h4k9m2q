import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

/// A road/trail/sidewalk way's geometry — see `route_graph_store.dart`'s
/// conditional export. [kind] mirrors `TrailRouter._isRoad`/`_isTrail`/
/// `_isSidewalk`'s classification.
typedef RouteWay = ({List<LatLng> coords, String kind});

/// Web build of [RouteGraphStore] — see `route_graph_store.dart`'s
/// conditional export. There's no bundled `route_graph.sqlite` on web (no
/// `dart:io`/`sqlite3` there at all), so unlike the mobile
/// (`route_graph_store_io.dart`) version this can't keep a persistent,
/// pre-fetched offline network on disk. Instead it fetches the same
/// road/trail/sidewalk geometry **live, on demand**, straight from the
/// public Overpass API — confirmed to send `Access-Control-Allow-Origin: *`,
/// so a direct browser `fetch`/`XMLHttpRequest` works with no proxy. This is
/// the fix for a real, reported gap between mobile and web: without this,
/// [TrailRouter]'s graph on web was built *only* from whatever
/// `queryRenderedFeaturesInRect` currently has rendered on screen — brittle
/// to vector-tile boundary seams and to trail geometry not rendered at the
/// current zoom, which showed up as the Draw tool detouring around a
/// perfectly real trail (a tiny rendering-only gap read as a genuine
/// disconnection) and the Freehand tool failing to snap at all wherever the
/// on-screen graph happened to be thin. Overpass returns each way's full,
/// un-clipped geometry, so a tile-boundary seam that never existed in the
/// real data disappears once it's merged in via this same
/// `RouteGraphStore.waysInBounds` seam `TrailRouter._addFeaturesToGraph`
/// already uses on mobile — no changes needed there at all.
///
/// Results are cached in memory per session, keyed by a fixed lat/lon grid
/// cell (see [_cellDeg]) rather than by the exact requested [LatLngBounds] —
/// two nearby-but-not-identical queries (e.g. successive clicks a few
/// metres apart while drawing) land on the same cell and reuse one fetch
/// instead of hitting Overpass again. No disk persistence: the desktop
/// designer is "a desk tool with an internet connection, not a field tool"
/// (see `web_map_style.dart`), so there's no offline requirement to justify
/// the complexity IndexedDB/localStorage would add — a page reload simply
/// re-fetches, same as it re-fetches map tiles.
class RouteGraphStore {
  RouteGraphStore._();
  static final RouteGraphStore instance = RouteGraphStore._();

  /// Grid cell size in degrees — small enough that a typical single
  /// draw/adjust action (a click, a short freehand stroke) usually touches
  /// only 1-4 cells, so the first interaction in a new area pays one or two
  /// small Overpass requests, not one large one; later nearby interactions
  /// reuse the cache. ~1.1km at the equator, tighter at higher latitudes.
  static const _cellDeg = 0.01;

  final Map<String, List<RouteWay>> _cache = {};
  final Map<String, Future<List<RouteWay>>> _inFlight = {};

  Future<List<RouteWay>> waysInBounds(LatLngBounds bounds) async {
    final cells = _cellsFor(bounds);
    final results = <RouteWay>[];
    for (final cell in cells) {
      results.addAll(await _waysForCell(cell));
    }
    return results;
  }

  List<({int lat, int lon})> _cellsFor(LatLngBounds b) {
    final swLat = (b.southwest.latitude / _cellDeg).floor();
    final neLat = (b.northeast.latitude / _cellDeg).floor();
    final swLon = (b.southwest.longitude / _cellDeg).floor();
    final neLon = (b.northeast.longitude / _cellDeg).floor();
    return [
      for (var la = swLat; la <= neLat; la++)
        for (var lo = swLon; lo <= neLon; lo++) (lat: la, lon: lo),
    ];
  }

  Future<List<RouteWay>> _waysForCell(({int lat, int lon}) cell) {
    final key = '${cell.lat}:${cell.lon}';
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;

    final south = cell.lat * _cellDeg;
    final north = south + _cellDeg;
    final west = cell.lon * _cellDeg;
    final east = west + _cellDeg;
    final future = _fetchCell(south, west, north, east).then((ways) {
      _cache[key] = ways;
      _inFlight.remove(key);
      return ways;
    }).catchError((Object _) {
      // Deliberately NOT cached — a transient network hiccup shouldn't
      // permanently disable supplemental data for the rest of the editing
      // session, unlike a genuine empty-result cache hit above. The caller
      // (TrailRouter._addFeaturesToGraph) treats an empty list exactly like
      // "nothing offline found here", same as it always has.
      _inFlight.remove(key);
      return <RouteWay>[];
    });
    _inFlight[key] = future;
    return future;
  }

  /// highway=* -> 'road'. Everything else walkable falls through to 'trail'
  /// (path/track/bridleway/steps/cycleway/pedestrian/footway), except
  /// footways explicitly tagged as a sidewalk/crossing -> 'sidewalk'. Kept
  /// byte-for-byte in sync with `tools/build_route_graph.py`'s `classify()`
  /// so live (web) and bundled (mobile) offline data behave identically once
  /// merged into the same graph.
  static const _roadHighway = {
    'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
    'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link',
    'unclassified', 'residential', 'service', 'living_street', 'road',
  };
  static const _sidewalkFootways = {'sidewalk', 'crossing'};
  static const _skipHighway = {'proposed', 'construction', 'razed', 'abandoned', 'corridor'};

  static String? _classify(Map<String, dynamic> tags) {
    final highway = tags['highway'] as String? ?? '';
    if (highway.isEmpty || _skipHighway.contains(highway)) return null;
    if (_roadHighway.contains(highway)) return 'road';
    if (highway == 'footway' && _sidewalkFootways.contains(tags['footway'])) {
      return 'sidewalk';
    }
    return 'trail';
  }

  /// POSTs one small Overpass query for a single grid cell. A short client
  /// timeout (not [_fetchCellAdaptive]'s multi-minute budget in
  /// `region_downloader.dart` — that's for a one-off bulk region download,
  /// this blocks an interactive click) with one retry; any failure just
  /// yields an empty list so drawing/adjusting never hangs or breaks.
  static Future<List<RouteWay>> _fetchCell(
      double south, double west, double north, double east) async {
    final query = '[out:json][timeout:10];'
        'way["highway"]($south,$west,$north,$east);'
        'out tags geom;';
    for (var attempt = 0; attempt <= 1; attempt++) {
      try {
        final resp = await http
            .post(Uri.parse('https://overpass-api.de/api/interpreter'),
                body: {'data': query})
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) continue;
        final decoded = jsonDecode(resp.body);
        final raw = decoded is Map ? decoded['elements'] : null;
        if (raw is! List) continue;
        // Eagerly filter to real Maps rather than a lazy `.cast<Map>()` —
        // Overpass can return a malformed/non-Map element under load, and a
        // lazy cast would let that sail through only to throw far away from
        // here (see CLAUDE.md's documented `.cast<Map>()` lesson from the
        // mobile region-downloader fetch).
        final elements = [for (final e in raw) if (e is Map) e];
        final ways = <RouteWay>[];
        for (final el in elements) {
          final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
          final kind = _classify(tags);
          if (kind == null) continue;
          final geom = el['geometry'];
          if (geom is! List) continue;
          final coords = <LatLng>[];
          for (final pt in geom) {
            if (pt is! Map) continue;
            final lat = pt['lat'], lon = pt['lon'];
            if (lat is! num || lon is! num) continue;
            coords.add(LatLng(lat.toDouble(), lon.toDouble()));
          }
          if (coords.length < 2) continue;
          ways.add((coords: coords, kind: kind));
        }
        return ways;
      } catch (_) {
        // fall through to retry/give up below
      }
    }
    return const [];
  }

  Future<void> addWays(String regionId, List<RouteWay> ways) async {
    throw UnsupportedError('RouteGraphStore.addWays is not available on web');
  }
}
