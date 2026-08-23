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

  /// Hard ceiling on how many cells a single [waysInBounds]/[prefetch] call
  /// will process. The lat/lon cross-product that turns a [LatLngBounds]
  /// into cells has no size limit of its own — a normal click/drag query
  /// area is 2-4 cells, but
  /// [prefetch] is called with the *entire visible viewport* on every camera
  /// idle, and zooming out far enough to see a whole multi-state/province
  /// region turns that into millions of cells. Confirmed live (2026-08-23):
  /// that crashed the page outright — building a multi-million-entry cell
  /// list and firing a `Future.wait` over that many concurrent Overpass
  /// fetches exhausts the tab well before any of them could plausibly
  /// finish. Past this ceiling, precise supplemental trail data isn't
  /// meaningful at that zoom level anyway, so treating it as "nothing
  /// offline found here" (same as a rate-limited/failed cell already
  /// resolves to, see [_failedAt]) is the correct behaviour, not just a
  /// safety hack.
  static const _maxCells = 400;

  final Map<String, List<RouteWay>> _cache = {};
  final Map<String, Future<List<RouteWay>>> _inFlight = {};

  /// When a cell last failed (see [_waysForCell]) — checked before starting
  /// a new fetch so a still-rate-limited/unreachable Overpass doesn't get
  /// hammered with an identical doomed request on every single subsequent
  /// action; confirmed live (2026-08-22) that heavy automated testing can
  /// get a public Overpass instance to reject/block requests outright for
  /// a while. [_failureBackoff] is deliberately short — this is a courtesy
  /// pause, not a long-lived "give up" signal, since a real edit session
  /// should recover once the block/outage clears.
  final Map<String, DateTime> _failedAt = {};
  static const _failureBackoff = Duration(seconds: 30);

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
    final swLat = (bounds.southwest.latitude / _cellDeg).floor();
    final neLat = (bounds.northeast.latitude / _cellDeg).floor();
    final swLon = (bounds.southwest.longitude / _cellDeg).floor();
    final neLon = (bounds.northeast.longitude / _cellDeg).floor();
    // Checked from the raw lat/lon span, before ever building the cell
    // list — a multi-million-cell span shouldn't even get as far as
    // allocating that list. See [_maxCells]'s doc.
    final latCells = neLat - swLat + 1;
    final lonCells = neLon - swLon + 1;
    if (latCells * lonCells > _maxCells) {
      DebugLog.instance.log('RouteGraphStore: viewport spans '
          '${latCells * lonCells} cells (> $_maxCells) — skipping live '
          'fetch, too large to be meaningful at this zoom');
      return const [];
    }
    final cells = [
      for (var la = swLat; la <= neLat; la++)
        for (var lo = swLon; lo <= neLon; lo++) (lat: la, lon: lo),
    ];
    final perCell = await Future.wait(cells.map(_waysForCell));
    return [for (final ways in perCell) ...ways];
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

    final failedAt = _failedAt[key];
    if (failedAt != null) {
      final since = DateTime.now().difference(failedAt);
      if (since < _failureBackoff) {
        DebugLog.instance.log('RouteGraphStore cell $key: skipping, failed '
            '${since.inSeconds}s ago (backoff ${_failureBackoff.inSeconds}s)');
        return Future.value(const []);
      }
    }

    final south = cell.lat * _cellDeg;
    final north = south + _cellDeg;
    final west = cell.lon * _cellDeg;
    final east = west + _cellDeg;
    final sw = DebugLog.instance.enabled ? (Stopwatch()..start()) : null;
    final future = _fetchCell(south, west, north, east).then((ways) {
      _cache[key] = ways;
      _inFlight.remove(key);
      _failedAt.remove(key);
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
      // "nothing offline found here", same as it always has. [_failedAt]
      // just delays the *next* retry a little, it never gives up outright.
      _inFlight.remove(key);
      _failedAt[key] = DateTime.now();
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
  /// this blocks an interactive click) with one retry.
  ///
  /// Deliberately **throws** rather than returning `[]` when every attempt
  /// fails (bad status, timeout, unparseable body) — a real, confirmed
  /// "Overpass has no ways here" answer (a 200 with a genuinely empty
  /// `elements` list) and a failed/rate-limited request must stay
  /// distinguishable, because [_waysForCell] caches a *returned* empty list
  /// forever but never caches a *thrown* one. Getting this backwards was a
  /// real bug: an earlier version swallowed every failure into `return
  /// const []`, so a transient Overpass error (rate-limiting from this
  /// project's own repeated automated testing is exactly the case that
  /// surfaced it, 2026-08-22) got cached as a permanent, wrongly-confident
  /// "confirmed no trails here" for that grid cell — reported as the
  /// Adjust tool's anchor-drag snapping going back to "barely functional",
  /// traced via the debug panel to every single cell in the edited area
  /// showing 0 rendered ways with no error ever logged, because the error
  /// was being caught and hidden right here, one level below where logging
  /// already existed.
  static Future<List<RouteWay>> _fetchCell(
      double south, double west, double north, double east) async {
    final query = '[out:json][timeout:10];'
        'way["highway"]($south,$west,$north,$east);'
        'out tags geom;';
    Object? lastError;
    for (var attempt = 0; attempt <= 1; attempt++) {
      try {
        final swNet = DebugLog.instance.enabled ? (Stopwatch()..start()) : null;
        final resp = await http
            .post(Uri.parse('https://overpass-api.de/api/interpreter'),
                body: {'data': query})
            .timeout(const Duration(seconds: 8));
        final netMs = swNet?.elapsedMilliseconds;
        if (resp.statusCode != 200) {
          lastError = 'HTTP ${resp.statusCode}: ${resp.body}';
          DebugLog.instance.log('RouteGraphStore fetch attempt $attempt: '
              '$lastError (network ${netMs}ms)');
          continue;
        }
        final swParse = DebugLog.instance.enabled ? (Stopwatch()..start()) : null;
        final decoded = jsonDecode(resp.body);
        final raw = decoded is Map ? decoded['elements'] : null;
        if (swParse != null) {
          DebugLog.instance.log('RouteGraphStore fetch: network ${netMs}ms, '
              '${resp.bodyBytes.length}B, jsonDecode '
              '${swParse.elapsedMilliseconds}ms so far');
        }
        if (raw is! List) {
          lastError = 'malformed response body (no elements list): '
              '${resp.body.substring(0, resp.body.length.clamp(0, 300))}';
          DebugLog.instance.log('RouteGraphStore fetch attempt $attempt: $lastError');
          continue;
        }
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
        // A genuine, successfully-parsed answer — confirmed empty (0 ways)
        // is a legitimate, cacheable result here, not a failure.
        return ways;
      } catch (e) {
        lastError = e;
        DebugLog.instance.log('RouteGraphStore fetch attempt $attempt threw: $e');
      }
    }
    throw StateError('Overpass fetch failed after 2 attempts: $lastError');
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
