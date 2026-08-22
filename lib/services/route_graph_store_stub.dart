import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'debug_log.dart';

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

  /// Fetches every cell overlapping [bounds] **in parallel**, not one at a
  /// time — a single click/drag's padded query area can span 2-4 cells (see
  /// [_cellDeg]), and a sequential `for` loop here made each of those pay
  /// its own full Overpass round-trip back-to-back, directly causing a real
  /// reported "click-to-draw takes a couple of seconds now" regression
  /// (confirmed once cache/`_inFlight` sharing meant a *cached* cell already
  /// returned instantly — the slowdown was specifically proportional to how
  /// many cells a query touched, not a per-call fixed cost). `Future.wait`
  /// fixes this: cells sharing a fetch (via [_inFlight]) or already cached
  /// resolve immediately, and any genuinely new cells fetch concurrently, so
  /// total latency is roughly the *slowest single cell*, not the sum of all
  /// of them.
  Future<List<RouteWay>> waysInBounds(LatLngBounds bounds) async {
    final cells = _cellsFor(bounds);
    final perCell = await Future.wait(cells.map(_waysForCell));
    return [for (final ways in perCell) ...ways];
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
    if (cached != null) {
      DebugLog.instance.log('RouteGraphStore cell $key: cache hit '
          '(${cached.length} ways)');
      return Future.value(cached);
    }
    final inFlight = _inFlight[key];
    if (inFlight != null) {
      DebugLog.instance.log('RouteGraphStore cell $key: joining in-flight fetch');
      return inFlight;
    }

    final south = cell.lat * _cellDeg;
    final north = south + _cellDeg;
    final west = cell.lon * _cellDeg;
    final east = west + _cellDeg;
    final sw = DebugLog.instance.enabled ? (Stopwatch()..start()) : null;
    final future = _fetchCell(south, west, north, east).then((ways) {
      _cache[key] = ways;
      _inFlight.remove(key);
      if (sw != null) {
        DebugLog.instance.log('RouteGraphStore cell $key: fetched '
            '${ways.length} ways in ${sw.elapsedMilliseconds}ms');
      }
      return ways;
    }).catchError((Object e) {
      // Deliberately NOT cached — a transient network hiccup shouldn't
      // permanently disable supplemental data for the rest of the editing
      // session, unlike a genuine empty-result cache hit above. The caller
      // (TrailRouter._addFeaturesToGraph) treats an empty list exactly like
      // "nothing offline found here", same as it always has.
      _inFlight.remove(key);
      if (sw != null) {
        DebugLog.instance.log('RouteGraphStore cell $key: failed after '
            '${sw.elapsedMilliseconds}ms — $e');
      }
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
        final swNet = DebugLog.instance.enabled ? (Stopwatch()..start()) : null;
        final resp = await http
            .post(Uri.parse('https://overpass-api.de/api/interpreter'),
                body: {'data': query})
            .timeout(const Duration(seconds: 8));
        final netMs = swNet?.elapsedMilliseconds;
        if (resp.statusCode != 200) continue;
        final swParse = DebugLog.instance.enabled ? (Stopwatch()..start()) : null;
        final decoded = jsonDecode(resp.body);
        final raw = decoded is Map ? decoded['elements'] : null;
        if (swParse != null) {
          DebugLog.instance.log('RouteGraphStore fetch: network ${netMs}ms, '
              '${resp.bodyBytes.length}B, jsonDecode '
              '${swParse.elapsedMilliseconds}ms so far');
        }
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
        if (swParse != null) {
          DebugLog.instance.log('RouteGraphStore fetch: parsed '
              '${elements.length} elements into ${ways.length} ways, '
              '${swParse.elapsedMilliseconds}ms total parse');
        }
        return ways;
      } catch (_) {
        // fall through to retry/give up below
      }
    }
    return const [];
  }

  /// Fire-and-forget cache warm-up for [bounds] — identical work to
  /// [waysInBounds], just named for call sites (see
  /// `desktop_designer_screen.dart`'s camera-idle hook) that only want the
  /// relevant cells cached ahead of time and don't need the result
  /// themselves. Cache/`_inFlight` sharing means a later real
  /// [waysInBounds] call for the same area — the one an actual click is
  /// waiting on — resolves instantly instead of paying this fetch itself.
  Future<void> prefetch(LatLngBounds bounds) => waysInBounds(bounds).then((_) {});

  Future<void> addWays(String regionId, List<RouteWay> ways) async {
    throw UnsupportedError('RouteGraphStore.addWays is not available on web');
  }
}
