import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../models/region.dart';
import 'crash_log.dart';
import 'native_bridge.dart';
import 'pmtiles_writer.dart';
import 'route_graph_store.dart';
import 'search_service.dart';

/// Minimum gap between download-notification text updates — the raw
/// tile/cell progress stream fires far more often than a notification needs
/// to redraw, and each update is its own platform-channel round trip.
const _kNotifyInterval = Duration(milliseconds: 800);

/// Progress of a region download. [phase] labels which step is running, and
/// [step]/[totalSteps] say which one of how many — tiles, an optional
/// missed-tile retry, finalizing the map file, street names, then
/// route-graph data. Each phase's [done]/[total] restarts from a fresh 0 (a
/// tile count and an Overpass cell count aren't comparable, so there's no
/// honest single percentage spanning all of them) — without [step]/
/// [totalSteps] that restart reads exactly like progress going backwards
/// (a real, reported point of confusion: "it reached 65% then reset to
/// 17%"), when it's actually a new phase starting. The UI shows "Step X of
/// Y" alongside the phase name specifically to make that unmistakable.
class DownloadProgress {
  DownloadProgress(this.done, this.total, this.bytes,
      {this.phase = 'Downloading map', this.step = 1, this.totalSteps = 1});
  final int done;
  final int total;
  final int bytes;
  final String phase;
  final int step;
  final int totalSteps;
}

/// Downloads a bounding box of Protomaps vector tiles and assembles them into a
/// local `.pmtiles` so the area works offline with the existing map pipeline.
class RegionDownloader {
  bool _cancelled = false;
  void cancel() => _cancelled = true;

  static int _lon2x(double lon, int z) =>
      ((lon + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);

  static int _lat2y(double lat, int z) {
    final r = lat * math.pi / 180;
    final y = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2;
    return (y * (1 << z)).floor().clamp(0, (1 << z) - 1);
  }

  /// All (z, x, y) tiles covering [west,south,east,north] over the zoom range.
  static List<List<int>> tilesFor(
      double west, double south, double east, double north) {
    final tiles = <List<int>>[];
    for (var z = kRegionMinZoom; z <= kRegionMaxZoom; z++) {
      final x0 = _lon2x(west, z), x1 = _lon2x(east, z);
      final y0 = _lat2y(north, z), y1 = _lat2y(south, z); // north = smaller y
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          tiles.add([z, x, y]);
        }
      }
    }
    return tiles;
  }

  /// Estimates the download size (bytes) by sampling a spread of tiles.
  Future<int> estimateBytes(
      double west, double south, double east, double north) async {
    final tiles = tilesFor(west, south, east, north);
    if (tiles.isEmpty) return 0;
    final client = HttpClient();
    try {
      const samples = 14;
      final step = math.max(1, tiles.length ~/ samples);
      var sum = 0, count = 0;
      for (var i = 0; i < tiles.length && count < samples; i += step) {
        final t = tiles[i];
        final bytes = await _fetch(client, t[0], t[1], t[2]);
        if (bytes != null) {
          sum += bytes.length;
          count++;
        }
      }
      final avg = count == 0 ? 0 : sum / count;
      return (avg * tiles.length).round();
    } finally {
      client.close(force: true);
    }
  }

  int get plannedTileCount => _planned;
  int _planned = 0;

  /// Tiles that never downloaded even after retries — each one leaves a gap
  /// that MapLibre fills by stretching a coarser tile to cover it (visibly
  /// blocky/oversized water, buildings, roads at close zoom, since that
  /// coarser tile was only ever meant for a zoomed-way-out view). Checked by
  /// the caller after [download] completes to warn if the region may have
  /// visible gaps.
  int get failedTileCount => _failedTileCount;
  int _failedTileCount = 0;

  /// Fraction (0.0-1.0) of this region's street-name Overpass cells that
  /// actually succeeded — checked by the caller after [download] to report
  /// how complete street search is for this area. 1.0 unless a fetch was
  /// attempted; never blocks the download itself: map tiles are the
  /// essential data, street search is a bonus that degrades gracefully.
  double get streetsCoverage => _streetsCoverage;
  double _streetsCoverage = 1.0;

  /// True if street coverage came back meaningfully incomplete (not just a
  /// handful of edge cells) — kept as a simple boolean for callers that only
  /// care about "should I mention this at all", alongside [streetsCoverage]
  /// for callers that want the actual percentage.
  bool get streetsFailed => _streetsCoverage < 0.999;

  /// Same idea as [streetsCoverage]/[streetsFailed], for the route graph
  /// (offline-region-wide routing, see [RouteGraphStore]) — TrailRouter
  /// just falls back to whatever's actually rendered on screen for any gap
  /// left in this region until a re-download improves coverage.
  double get routeGraphCoverage => _routeGraphCoverage;
  double _routeGraphCoverage = 1.0;
  bool get routeGraphFailed => _routeGraphCoverage < 0.999;

  /// A user-facing warning for [coverage] of [what] (e.g. "Street search"),
  /// or null when coverage is complete enough not to bother mentioning.
  /// Distinguishes "not available at all" (0%, e.g. Overpass unreachable)
  /// from "partially available" (some real percentage) rather than
  /// collapsing both into one "failed" message — a huge/dense area that
  /// still got most of its data covered shouldn't read the same as one that
  /// got none of it.
  static String? coverageWarning(String what, double coverage) {
    if (coverage >= 0.999) return null;
    if (coverage <= 0.001) {
      return "$what isn't available for this area — re-download it later "
          'if you want to try again.';
    }
    final pct = (coverage * 100).round();
    return '$what is only $pct% complete for this area (it\'s large/dense '
        'enough that some of it timed out) — re-download it later to try '
        'filling in the rest.';
  }

  /// Downloads the region into `<docs>/map/<id>.pmtiles` and returns a [Region].
  Future<Region?> download({
    required String id,
    required String name,
    required double west,
    required double south,
    required double east,
    required double north,
    void Function(DownloadProgress)? onProgress,
  }) async {
    final tiles = tilesFor(west, south, east, north);
    _planned = tiles.length;
    final docs = await getApplicationDocumentsDirectory();
    final mapDir = Directory('${docs.path}/map');
    await mapDir.create(recursive: true);
    final outPath = '${mapDir.path}/$id.pmtiles';
    final tempPath = '${mapDir.path}/$id.tiles.tmp';

    // Keeps this process alive (and the tile-fetch/Overpass loops below
    // running) if the app is backgrounded or the screen locks mid-download
    // — without this, Android can suspend the isolate within seconds and
    // the download silently stalls. Stopped in `finally` below no matter
    // how the download ends, so it never outlives it.
    await NativeBridge.startDownloadKeepAlive('Downloading $name…');
    var lastNotify = DateTime.now();
    void report(DownloadProgress p) {
      onProgress?.call(p);
      final now = DateTime.now();
      if (now.difference(lastNotify) >= _kNotifyInterval) {
        lastNotify = now;
        final pct = p.total > 0 ? (p.done / p.total * 100).round() : 0;
        NativeBridge.updateDownloadKeepAlive('${p.phase} ($name)… $pct%');
      }
    }

    try {
      return await _downloadInner(
        id: id, name: name, west: west, south: south, east: east, north: north,
        tiles: tiles, outPath: outPath, tempPath: tempPath, onProgress: report,
      );
    } finally {
      await NativeBridge.stopDownloadKeepAlive();
    }
  }

  Future<Region?> _downloadInner({
    required String id,
    required String name,
    required double west,
    required double south,
    required double east,
    required double north,
    required List<List<int>> tiles,
    required String outPath,
    required String tempPath,
    void Function(DownloadProgress)? onProgress,
  }) async {
    final writer = await PmTilesWriter.create(tempPath);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    var done = 0;
    final failed = <List<int>>[];
    // Retrying missed tiles only happens (and only counts as its own step)
    // when the batch loop below actually leaves failures — known only once
    // that loop finishes, so this starts as a guess and is corrected right
    // after. Every step number downstream is derived from it, so "Step 2 of
    // 4" vs "Step 2 of 5" is the only thing that can shift mid-download —
    // the step *number* itself never goes backward, which is the actual
    // point (see [DownloadProgress]'s doc).
    var totalSteps = 4;
    try {
      // Fetch in small concurrent batches to keep memory + sockets bounded.
      const batch = 6;
      for (var i = 0; i < tiles.length; i += batch) {
        if (_cancelled) break;
        final slice = tiles.sublist(i, math.min(i + batch, tiles.length));
        final results = await Future.wait(
            slice.map((t) => _fetch(client, t[0], t[1], t[2])));
        for (var j = 0; j < slice.length; j++) {
          final bytes = results[j];
          if (bytes != null && bytes.isNotEmpty) {
            await writer.addTile(slice[j][0], slice[j][1], slice[j][2], bytes);
          } else {
            failed.add(slice[j]);
          }
          done++;
        }
        onProgress?.call(DownloadProgress(done, tiles.length, writer.byteCount,
            step: 1, totalSteps: totalSteps));
      }
      // A tile that failed even after _fetch's own retries is usually a
      // transient blip rather than a permanently bad tile (a dropped
      // connection in a batch of hundreds, a momentary rate limit) — worth
      // one more slower, sequential pass before accepting the gap.
      if (!_cancelled && failed.isNotEmpty) {
        totalSteps = 5;
        final stillFailed = <List<int>>[];
        for (var i = 0; i < failed.length; i++) {
          final t = failed[i];
          final bytes = await _fetch(client, t[0], t[1], t[2], retries: 4);
          if (bytes != null && bytes.isNotEmpty) {
            await writer.addTile(t[0], t[1], t[2], bytes);
          } else {
            stillFailed.add(t);
          }
          onProgress?.call(DownloadProgress(i + 1, failed.length,
              writer.byteCount,
              phase: 'Retrying missed tiles', step: 2, totalSteps: totalSteps));
        }
        _failedTileCount = stillFailed.length;
      }
    } finally {
      client.close(force: true);
    }

    if (_cancelled) {
      // Just discard the in-progress temp file — never touch outPath, since
      // for an update-in-place [id] is an existing region's id, and that
      // region's real .pmtiles must survive a cancelled update untouched.
      await writer.abort();
      return null;
    }

    final finalizeStep = totalSteps - 2; // 2 or 3, depending on the retry step above
    await writer.finish(outPath,
        west: west, south: south, east: east, north: north,
        minZoom: kRegionMinZoom, maxZoom: kRegionMaxZoom,
        onCopyProgress: (copied, total) => onProgress?.call(DownloadProgress(
            copied, total, copied,
            phase: 'Finalizing map file', step: finalizeStep, totalSteps: totalSteps)));

    try {
      final result = await _fetchStreets(west, south, east, north,
          onCellProgress: (d, t) => onProgress?.call(DownloadProgress(
              d, t, writer.byteCount,
              phase: 'Fetching street names',
              step: finalizeStep + 1, totalSteps: totalSteps)));
      await SearchService.instance.addStreets(id, result.items);
      _streetsCoverage = result.coverage;
    } catch (e, st) {
      // Soft-fail — street search for this region just won't work until a
      // re-download succeeds; the map itself is unaffected. Logged (not just
      // swallowed) so a real bug here is diagnosable from a real device's
      // crash log instead of vanishing into "not available" with no trace —
      // exactly what made an earlier version of this bug (an uncaught
      // exception on malformed Overpass geometry, since fixed in
      // _dedupeStreets) invisible.
      CrashLog.log('Street-name fetch', e, st);
      _streetsCoverage = 0;
    }

    try {
      final result = await _fetchWays(west, south, east, north,
          onCellProgress: (d, t) => onProgress?.call(DownloadProgress(
              d, t, writer.byteCount,
              phase: 'Fetching trail & road data',
              step: finalizeStep + 2, totalSteps: totalSteps)));
      await RouteGraphStore.instance.addWays(id, result.items);
      _routeGraphCoverage = result.coverage;
    } catch (e, st) {
      // Soft-fail — same contract (and same logging reasoning) as
      // streetsCoverage above.
      CrashLog.log('Route-graph fetch', e, st);
      _routeGraphCoverage = 0;
    }

    return Region(
      id: id,
      name: name,
      center: LatLng((south + north) / 2, (west + east) / 2),
      south: south, west: west, north: north, east: east,
      mapAsset: id,
    );
  }

  /// Fetches one tile, retrying transient failures (timeout, dropped
  /// connection, non-200) with a short backoff — a silent `null` here used
  /// to just mean "skip this tile", which leaves a permanent gap in the
  /// archive that MapLibre papers over with a stretched, wrong-looking
  /// coarser tile at render time. Real, permanently-missing tiles (e.g. a
  /// zoom level with no coverage at this location) still end up `null`
  /// after retries — this only cuts down on the transient case.
  Future<List<int>?> _fetch(HttpClient client, int z, int x, int y,
      {int retries = 2}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final req = await client.getUrl(Uri.parse(protomapsTileUrl(z, x, y)));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          await resp.drain();
          if (attempt >= retries) return null;
        } else {
          final b = BytesBuilder();
          await for (final chunk in resp) {
            b.add(chunk);
          }
          return b.takeBytes();
        }
      } catch (_) {
        if (attempt >= retries) return null;
      }
      await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
  }

  /// Starting cell size (degrees) per Overpass request — mirrors
  /// `tools/build_route_graph.py`'s `CELL_DEG`. Most downloaded areas are a
  /// single cell (whatever fit on screen when the user tapped Download);
  /// a large/dense metro area (e.g. Jakarta) starts at this size too but
  /// [_fetchCellAdaptive] shrinks any cell that fails down toward
  /// [_minCellDeg] rather than just giving up on it — see that doc for why
  /// a flat cell size silently left dense areas with big gaps even after
  /// downloading real data.
  static const _overpassCellDeg = 0.15;

  /// Smallest a cell may shrink to while subdividing after a failure —
  /// mirrors the Jakarta/Tangerang diagnostic bundles' `CELL_OVERRIDES`
  /// (`tools/build_route_graph.py`), confirmed small enough to reliably
  /// succeed against the public Overpass instance even over a dense urban
  /// core, where the default 0.15° size reliably 504s.
  static const _minCellDeg = 0.05;

  /// How many times a single top-level cell may be quartered before giving
  /// up on whatever patch is still failing — bounds worst-case effort per
  /// cell (4³ = 64 leaf attempts) rather than subdividing indefinitely on a
  /// cell that's failing for a non-size reason (e.g. the instance is down).
  static const _maxSubdivideDepth = 3;

  /// Wall-clock budget for the *whole* tiled fetch (every top-level cell
  /// plus any subdivisions they need) — now the sole backstop against
  /// "runs forever silently", since a too-large area degrades gracefully to
  /// partial coverage (see [RegionDownloader.streetsCoverage]/
  /// [routeGraphCoverage]) instead of being rejected outright before even
  /// trying. Raised well past the original 45s: that budget was sized for
  /// a flat per-cell-skip strategy where 45s was already "a while"; an
  /// adaptive strategy needs real time to retry a failing cell smaller, and
  /// the download screen's progress bar keeps moving throughout (each
  /// top-level cell still reports done/total as it resolves), so a longer
  /// budget doesn't reintroduce the old "looks stuck" bug that number was
  /// originally chosen to prevent.
  static const _overpassTimeBudget = Duration(minutes: 4);

  static List<(double, double, double, double)> _cells(
      double west, double south, double east, double north, double cellDeg) {
    final cells = <(double, double, double, double)>[];
    var lat = south;
    while (lat < north) {
      final lat2 = math.min(lat + cellDeg, north);
      var lon = west;
      while (lon < east) {
        final lon2 = math.min(lon + cellDeg, east);
        cells.add((lat, lon, lat2, lon2));
        lon = lon2;
      }
      lat = lat2;
    }
    return cells;
  }

  /// Fetches [queryFor]'s ways over the whole bbox, tiled into a grid of
  /// [_overpassCellDeg] top-level cells (each recursively shrunk on failure
  /// by [_fetchCellAdaptive]) and deduped by OSM way id (a way spanning a
  /// cell boundary comes back from more than one cell). [coverage] is the
  /// fraction of every leaf cell attempted (top-level cells plus whatever
  /// subdivisions they needed) that actually succeeded — 1.0 for a clean
  /// fetch, lower for a dense/huge area that hit the time budget or genuine
  /// repeated failures, so the caller can report real completeness instead
  /// of a binary succeeded/failed.
  static Future<({List<Map> elements, double coverage})> _fetchOverpassTiled(
    double west,
    double south,
    double east,
    double north,
    String Function(double s, double w, double n, double e) queryFor, {
    void Function(int done, int total)? onCellProgress,
  }) async {
    final cells = _cells(west, south, east, north, _overpassCellDeg);
    final deadline = DateTime.now().add(_overpassTimeBudget);
    final byId = <int, Map>{};
    var attempted = 0, succeeded = 0, topDone = 0;
    for (final cell in cells) {
      if (DateTime.now().isAfter(deadline)) break;
      final result = await _fetchCellAdaptive(
          cell.$1, cell.$2, cell.$3, cell.$4, queryFor, deadline, 0);
      for (final el in result.elements) {
        final id = el['id'];
        if (el['type'] == 'way' && id != null) byId[id as int] = el;
      }
      attempted += result.attempted;
      succeeded += result.succeeded;
      topDone++;
      onCellProgress?.call(topDone, cells.length);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    final coverage = attempted == 0 ? 0.0 : succeeded / attempted;
    return (elements: byId.values.toList(), coverage: coverage);
  }

  /// Fetches one cell, recursively quartering it into smaller cells on
  /// failure instead of just skipping it outright — the actual fix for a
  /// dense area (Jakarta-scale) silently ending up with big gaps even
  /// though real data did download: the default 0.15° cell size reliably
  /// 504s over a dense urban core, but a smaller one succeeds there, so
  /// retrying smaller recovers real coverage that the old flat
  /// skip-on-failure approach was leaving on the table. Stops subdividing
  /// at [_minCellDeg] or [_maxSubdivideDepth], whichever comes first — at
  /// that point the patch is counted as attempted-but-failed rather than
  /// retried forever — and checks [deadline] on every call so a
  /// pathologically slow deep dive into one bad top-level cell can't blow
  /// the overall time budget either.
  static Future<({List<Map> elements, int attempted, int succeeded})>
      _fetchCellAdaptive(
    double s,
    double w,
    double n,
    double e,
    String Function(double s, double w, double n, double e) queryFor,
    DateTime deadline,
    int depth,
  ) async {
    if (DateTime.now().isAfter(deadline)) {
      return (elements: const <Map>[], attempted: 0, succeeded: 0);
    }
    final elements = await _postOverpass(queryFor(s, w, n, e));
    if (elements != null) {
      return (elements: elements, attempted: 1, succeeded: 1);
    }
    final canSubdivide = depth < _maxSubdivideDepth && (n - s) > _minCellDeg * 2;
    if (!canSubdivide) {
      return (elements: const <Map>[], attempted: 1, succeeded: 0);
    }
    final midLat = (s + n) / 2, midLon = (w + e) / 2;
    final quadrants = [
      (s, w, midLat, midLon),
      (s, midLon, midLat, e),
      (midLat, w, n, midLon),
      (midLat, midLon, n, e),
    ];
    final out = <Map>[];
    var attempted = 0, succeeded = 0;
    for (final q in quadrants) {
      await Future.delayed(const Duration(milliseconds: 300));
      final r = await _fetchCellAdaptive(
          q.$1, q.$2, q.$3, q.$4, queryFor, deadline, depth + 1);
      out.addAll(r.elements);
      attempted += r.attempted;
      succeeded += r.succeeded;
    }
    return (elements: out, attempted: attempted, succeeded: succeeded);
  }

  /// POSTs one Overpass query, retrying transient failures. Returns null
  /// (not a thrown exception) on final failure so [_fetchOverpassTiled] can
  /// skip just this cell and keep going.
  static Future<List<Map>?> _postOverpass(String query) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      for (var attempt = 0; attempt <= 2; attempt++) {
        try {
          final req = await client
              .postUrl(Uri.parse('https://overpass-api.de/api/interpreter'));
          req.headers.contentType =
              ContentType('application', 'x-www-form-urlencoded');
          req.write('data=${Uri.encodeQueryComponent(query)}');
          final resp = await req.close();
          if (resp.statusCode != 200) {
            await resp.drain();
            if (attempt == 2) return null;
          } else {
            final text = await resp.transform(utf8.decoder).join();
            return (jsonDecode(text)['elements'] as List).cast<Map>();
          }
        } catch (_) {
          if (attempt == 2) return null;
        }
        await Future.delayed(Duration(seconds: 3 * (attempt + 1)));
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Named streets within the bbox, from the Overpass API — the same query
  /// shape as `tools/build_streets_db.py` uses for the bundled regions, so a
  /// downloaded region's street search matches the bundled ones in quality.
  /// One representative point per name (midpoint of the longest matching
  /// way), so a repeated street name (common for long roads split into many
  /// OSM ways) doesn't produce duplicate search results.
  static Future<({List<({String name, double lat, double lon})> items, double coverage})>
      _fetchStreets(
      double west, double south, double east, double north,
      {void Function(int done, int total)? onCellProgress}) async {
    final result = await _fetchOverpassTiled(west, south, east, north,
        (s, w, n, e) => '[out:json][timeout:180];'
            'way["highway"]["name"]($s,$w,$n,$e);'
            'out tags geom;',
        onCellProgress: onCellProgress);
    return (items: _dedupeStreets(result.elements), coverage: result.coverage);
  }

  static const _excludedHighway = {
    'footway', 'path', 'steps', 'cycleway', 'bridleway', 'corridor',
    'proposed', 'construction', 'razed', 'abandoned',
  };

  /// One malformed element must never cost the whole batch — a dense/huge
  /// area's Overpass response (e.g. Tangerang-scale) is exactly where a
  /// single unresolved node reference (`geom` containing a `null` entry
  /// instead of a real point — real, documented Overpass behavior under
  /// load, not hypothetical) is most likely, and this method previously had
  /// no guard against it at all: one bad element threw an uncaught
  /// exception straight out of [_fetchStreets], discarding everything
  /// already successfully fetched and reporting "not available" instead of
  /// whatever real (possibly large) coverage had actually been gathered.
  static List<({String name, double lat, double lon})> _dedupeStreets(
      List<Map> elements) {
    final bestLen = <String, double>{};
    final bestPoint = <String, (double, double)>{};
    for (final el in elements) {
      try {
        if (el['type'] != 'way') continue;
        final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
        final name = (tags['name'] as String?)?.trim();
        final highway = tags['highway'] as String?;
        final geom = (el['geom'] as List?)?.cast<Map>();
        if (name == null || name.isEmpty || geom == null || geom.isEmpty) continue;
        if (_excludedHighway.contains(highway)) continue;
        var length = 0.0;
        for (var i = 0; i < geom.length - 1; i++) {
          final a = geom[i], b = geom[i + 1];
          final dlat = ((b['lat'] as num) - (a['lat'] as num)) * 111320;
          final dlon = ((b['lon'] as num) - (a['lon'] as num)) *
              111320 *
              math.cos((a['lat'] as num) * math.pi / 180);
          length += math.sqrt(dlat * dlat + dlon * dlon);
        }
        if (length > (bestLen[name] ?? -1)) {
          bestLen[name] = length;
          final mid = geom[geom.length ~/ 2];
          bestPoint[name] = ((mid['lat'] as num).toDouble(), (mid['lon'] as num).toDouble());
        }
      } catch (_) {
        // Skip just this one way — see this method's doc.
      }
    }
    return [
      for (final entry in bestPoint.entries)
        (name: entry.key, lat: entry.value.$1, lon: entry.value.$2),
    ];
  }

  /// Every walkable way within the bbox, from the Overpass API — same query
  /// shape as `tools/build_route_graph.py` uses for the bundled regions
  /// (full geometry, every `highway=*` value, not just named ones), so a
  /// downloaded region's routing coverage matches the bundled ones.
  static Future<({List<RouteWay> items, double coverage})> _fetchWays(
      double west, double south, double east, double north,
      {void Function(int done, int total)? onCellProgress}) async {
    final result = await _fetchOverpassTiled(west, south, east, north,
        (s, w, n, e) => '[out:json][timeout:180];'
            'way["highway"]($s,$w,$n,$e);'
            'out tags geom;',
        onCellProgress: onCellProgress);
    return (items: _classifyWays(result.elements), coverage: result.coverage);
  }

  // Mirrors tools/build_route_graph.py's classify() exactly, so bundled and
  // downloaded route-graph data behave identically once merged into
  // TrailRouter's graph.
  static const _roadHighway = {
    'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
    'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link',
    'unclassified', 'residential', 'service', 'living_street', 'road',
  };
  static const _sidewalkFootways = {'sidewalk', 'crossing'};
  static const _skipHighway = {
    'proposed', 'construction', 'razed', 'abandoned', 'corridor',
  };

  static String? _classifyWay(Map<String, dynamic> tags) {
    final highway = tags['highway'] as String? ?? '';
    if (highway.isEmpty || _skipHighway.contains(highway)) return null;
    if (_roadHighway.contains(highway)) return 'road';
    if (highway == 'footway' && _sidewalkFootways.contains(tags['footway'])) {
      return 'sidewalk';
    }
    return 'trail';
  }

  /// Same "one bad element can't cost the batch" reasoning as
  /// [_dedupeStreets] — an unresolved node reference in `geom` (Overpass
  /// returning `null` for a point it couldn't resolve, real behavior under
  /// load) would otherwise throw here and discard the whole route-graph
  /// fetch.
  static List<RouteWay> _classifyWays(List<Map> elements) {
    final ways = <RouteWay>[];
    for (final el in elements) {
      try {
        if (el['type'] != 'way') continue;
        final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
        final kind = _classifyWay(tags);
        final geom = (el['geom'] as List?)?.cast<Map>();
        if (kind == null || geom == null || geom.length < 2) continue;
        ways.add((
          kind: kind,
          coords: [
            for (final p in geom)
              LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()),
          ],
        ));
      } catch (_) {
        // Skip just this one way — see this method's doc.
      }
    }
    return ways;
  }
}
