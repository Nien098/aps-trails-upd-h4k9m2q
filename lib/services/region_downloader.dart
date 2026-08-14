import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../models/region.dart';
import 'pmtiles_writer.dart';
import 'route_graph_store.dart';
import 'search_service.dart';

/// Progress of a region download. [phase] labels which step is running —
/// map tiles, then street names, then route-graph data — since all three
/// report through the same callback but at very different scales (tile
/// count vs. Overpass cell count), so the UI can explain why the bar/number
/// jumps between phases instead of looking stuck.
class DownloadProgress {
  DownloadProgress(this.done, this.total, this.bytes,
      {this.phase = 'Downloading map'});
  final int done;
  final int total;
  final int bytes;
  final String phase;
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

  /// True if fetching this region's street names (for offline search) failed
  /// — checked by the caller after [download] to show a soft-fail message.
  /// Never blocks the download itself: map tiles are the essential data,
  /// street search is a bonus that degrades gracefully.
  bool get streetsFailed => _streetsFailed;
  bool _streetsFailed = false;

  /// True if fetching this region's route graph (for offline-region-wide
  /// routing, see [RouteGraphStore]) failed — same soft-fail contract as
  /// [streetsFailed]: TrailRouter just falls back to whatever's actually
  /// rendered on screen for this region until a re-download succeeds.
  bool get routeGraphFailed => _routeGraphFailed;
  bool _routeGraphFailed = false;

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

    final writer = await PmTilesWriter.create(tempPath);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    var done = 0;
    final failed = <List<int>>[];
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
        onProgress
            ?.call(DownloadProgress(done, tiles.length, writer.byteCount));
      }
      // A tile that failed even after _fetch's own retries is usually a
      // transient blip rather than a permanently bad tile (a dropped
      // connection in a batch of hundreds, a momentary rate limit) — worth
      // one more slower, sequential pass before accepting the gap.
      if (!_cancelled && failed.isNotEmpty) {
        final stillFailed = <List<int>>[];
        for (final t in failed) {
          final bytes = await _fetch(client, t[0], t[1], t[2], retries: 4);
          if (bytes != null && bytes.isNotEmpty) {
            await writer.addTile(t[0], t[1], t[2], bytes);
          } else {
            stillFailed.add(t);
          }
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

    await writer.finish(outPath,
        west: west, south: south, east: east, north: north,
        minZoom: kRegionMinZoom, maxZoom: kRegionMaxZoom);

    try {
      final streets = await _fetchStreets(west, south, east, north,
          onCellProgress: (d, t) => onProgress?.call(DownloadProgress(
              d, t, writer.byteCount, phase: 'Fetching street names')));
      await SearchService.instance.addStreets(id, streets);
    } catch (_) {
      // Soft-fail — street search for this region just won't work until a
      // re-download succeeds; the map itself is unaffected. Also the escape
      // hatch for an area too large to even attempt (_fetchOverpassTiled
      // throws outright rather than queuing hundreds of sequential
      // requests) — a slow-but-still-bounded area instead just returns
      // whatever cells finished inside its time budget, no exception.
      _streetsFailed = true;
    }

    try {
      final ways = await _fetchWays(west, south, east, north,
          onCellProgress: (d, t) => onProgress?.call(DownloadProgress(
              d, t, writer.byteCount, phase: 'Fetching trail & road data')));
      await RouteGraphStore.instance.addWays(id, ways);
    } catch (_) {
      // Soft-fail — same contract as streetsFailed above.
      _routeGraphFailed = true;
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

  /// Max cell size (degrees) per Overpass request — mirrors
  /// `tools/build_route_graph.py`'s `CELL_DEG`. Most downloaded areas are a
  /// single cell (whatever fit on screen when the user tapped Download),
  /// but a large/dense metro area (e.g. all of Jakarta, or zooming out to
  /// capture a whole province) can otherwise blow past the public Overpass
  /// instance's per-request timeout/size limit in one unbounded request —
  /// this is the bug that made street/route-graph data silently fail to
  /// fetch for exactly that kind of area.
  static const _overpassCellDeg = 0.15;

  /// Hard cap on how many cells a single download will attempt. Beyond
  /// this, the area needs so many sequential Overpass requests (each with
  /// its own retry/backoff) that it can run for many minutes with no
  /// visible progress once the map-tile bar already reads 100% — which is
  /// exactly what read as the app "stuck forever" (users had to force-quit
  /// out of it). Skipping outright and telling the user, instead of
  /// silently grinding for a very long time, is the better failure mode.
  static const _overpassMaxCells = 60;

  /// Wall-clock budget for the *whole* tiled fetch, independent of the cell
  /// cap above — a safety net for the case where even a modest-sized area
  /// turns out to be unexpectedly slow (an overloaded public instance,
  /// dense city data). Stops issuing new cell requests once exceeded and
  /// returns whatever succeeded so far, rather than the cap alone (which
  /// only guards against *area*, not per-cell slowness).
  static const _overpassTimeBudget = Duration(seconds: 45);

  static int _cellCount(double west, double south, double east, double north) {
    final rows = math.max(1, ((north - south) / _overpassCellDeg).ceil());
    final cols = math.max(1, ((east - west) / _overpassCellDeg).ceil());
    return rows * cols;
  }

  /// Fetches [queryFor]'s ways over the whole bbox, tiled into a grid of
  /// `_overpassCellDeg` cells and deduped by OSM way id (a way spanning a
  /// cell boundary comes back from more than one cell). Each cell's failure
  /// is caught and skipped individually rather than aborting the whole
  /// fetch — a partial street/route index for a huge area is far more
  /// useful than none at all, matching [RegionDownloader.download]'s own
  /// "keep whatever tiles succeeded" philosophy for map tiles. Throws (a
  /// deliberate, immediate soft-fail via the caller's try/catch) if the
  /// area is too large to even attempt — see [_overpassMaxCells].
  static Future<List<Map>> _fetchOverpassTiled(
    double west,
    double south,
    double east,
    double north,
    String Function(double s, double w, double n, double e) queryFor, {
    void Function(int done, int total)? onCellProgress,
  }) async {
    final totalCells = _cellCount(west, south, east, north);
    if (totalCells > _overpassMaxCells) {
      throw StateError(
          'Area needs $totalCells Overpass requests, over the $_overpassMaxCells cap');
    }
    final deadline = DateTime.now().add(_overpassTimeBudget);
    final byId = <int, Map>{};
    var cellsDone = 0;
    var lat = south;
    outer:
    while (lat < north) {
      final lat2 = math.min(lat + _overpassCellDeg, north);
      var lon = west;
      while (lon < east) {
        if (DateTime.now().isAfter(deadline)) break outer;
        final lon2 = math.min(lon + _overpassCellDeg, east);
        final elements = await _postOverpass(queryFor(lat, lon, lat2, lon2));
        if (elements != null) {
          for (final el in elements) {
            final id = el['id'];
            if (el['type'] == 'way' && id != null) byId[id as int] = el;
          }
        }
        cellsDone++;
        onCellProgress?.call(cellsDone, totalCells);
        lon = lon2;
        if (lon < east || lat2 < north) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
      lat = lat2;
    }
    return byId.values.toList();
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
  static Future<List<({String name, double lat, double lon})>> _fetchStreets(
      double west, double south, double east, double north,
      {void Function(int done, int total)? onCellProgress}) async {
    final elements = await _fetchOverpassTiled(west, south, east, north,
        (s, w, n, e) => '[out:json][timeout:180];'
            'way["highway"]["name"]($s,$w,$n,$e);'
            'out tags geom;',
        onCellProgress: onCellProgress);
    return _dedupeStreets(elements);
  }

  static const _excludedHighway = {
    'footway', 'path', 'steps', 'cycleway', 'bridleway', 'corridor',
    'proposed', 'construction', 'razed', 'abandoned',
  };

  static List<({String name, double lat, double lon})> _dedupeStreets(
      List<Map> elements) {
    final bestLen = <String, double>{};
    final bestPoint = <String, (double, double)>{};
    for (final el in elements) {
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
    }
    return [
      for (final entry in bestPoint.entries)
        (name: entry.key, lat: entry.value.$1, lon: entry.value.$2),
    ];
  }

  /// Every walkable way within the bbox, from the Overpass API — same query
  /// shape as `tools/build_route_graph.py` uses for the bundled regions
  /// (full geometry, every `highway=*` value, not just named ones), so a
  /// downloaded region's routing coverage matches the bundled ones. A single
  /// request is fine here (unlike the build script's grid-tiled fetch for
  /// the huge bundled-region bboxes) since a downloaded area is just
  /// whatever fit in the user's screen when they tapped Download.
  static Future<List<RouteWay>> _fetchWays(
      double west, double south, double east, double north,
      {void Function(int done, int total)? onCellProgress}) async {
    final elements = await _fetchOverpassTiled(west, south, east, north,
        (s, w, n, e) => '[out:json][timeout:180];'
            'way["highway"]($s,$w,$n,$e);'
            'out tags geom;',
        onCellProgress: onCellProgress);
    return _classifyWays(elements);
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

  static List<RouteWay> _classifyWays(List<Map> elements) {
    final ways = <RouteWay>[];
    for (final el in elements) {
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
    }
    return ways;
  }
}
