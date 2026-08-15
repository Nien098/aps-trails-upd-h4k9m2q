// Dev-time script: fetches a whole-world, low-zoom (0..7) Protomaps vector
// tile pyramid and writes it to assets/map/world.pmtiles — a small, always-
// present basemap layered *beneath* the bundled/downloaded per-region
// pmtiles (see style.json's "world" source + "world_earth"/"world_water"
// layers), so panning/zooming out shows real coastline/landmass shapes
// instead of the flat grey background wherever no region data exists.
//
// z0-6 was sized by measuring the REAL built archive, not a sample: a small
// stratified sample (8 tiles/zoom) badly underestimated cost (predicted
// ~37MB for z0-7; the real number came back ~267MB, with z7 alone at
// ~206MB) — Protomaps' basemap carries much more real coastline/landcover
// detail at mid zoom than a handful of samples caught, and starts including
// road/building/place detail around z8, where the pyramid balloons into the
// hundreds of MB regardless. z0-6 measured at ~61MB real (not estimated),
// the accepted tradeoff after seeing the real z0-7 cost. MapLibre overzooms
// the z6 tiles automatically for any camera zoom beyond 6 (same mechanism
// already used for the regional pmtiles' zoom 15 data at zoom 18 — see
// kRegionMaxZoom's doc in config.dart), so panning outside any downloaded
// region at zoom 7+ still shows the z6 shapes, just blockier — not a blank
// grey screen.
//
// Run from the repo root: `dart run tools/build_world_basemap.dart`
// Takes a while (5,461 tiles) — this is a one-time dev-time build, not run
// by the app itself. If re-run at a deeper zoom, measure the REAL output
// file size before bundling it (don't trust a small sample — see above).

import 'dart:io';
import 'dart:math' as math;

import '../lib/config.dart';
import '../lib/services/pmtiles_writer.dart';

const int maxZoom = 6;
const int batchSize = 8;
const String outPath = 'assets/map/world.pmtiles';

Future<void> main() async {
  final tiles = <List<int>>[];
  for (var z = 0; z <= maxZoom; z++) {
    final n = 1 << z;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        tiles.add([z, x, y]);
      }
    }
  }
  stdout.writeln('Fetching ${tiles.length} tiles (z0-$maxZoom)...');

  final tempPath = '$outPath.tmp.tiles';
  final writer = await PmTilesWriter.create(tempPath);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  var done = 0;
  var failed = 0;

  try {
    for (var i = 0; i < tiles.length; i += batchSize) {
      final slice = tiles.sublist(i, math.min(i + batchSize, tiles.length));
      final results =
          await Future.wait(slice.map((t) => _fetch(client, t[0], t[1], t[2])));
      for (var j = 0; j < slice.length; j++) {
        final bytes = results[j];
        if (bytes != null && bytes.isNotEmpty) {
          await writer.addTile(slice[j][0], slice[j][1], slice[j][2], bytes);
        } else {
          failed++;
        }
        done++;
      }
      if (done % 500 < batchSize) {
        stdout.writeln('$done/${tiles.length} tiles ($failed failed so far)');
      }
    }
  } finally {
    client.close(force: true);
  }

  stdout.writeln('Fetched $done tiles, $failed permanently failed. Writing archive...');
  await writer.finish(
    outPath,
    west: -180,
    south: -85.0511,
    east: 180,
    north: 85.0511,
    minZoom: 0,
    maxZoom: maxZoom,
  );
  final size = await File(outPath).length();
  stdout.writeln('Done: $outPath (${(size / 1e6).toStringAsFixed(1)} MB)');
}

/// Same retry/backoff shape as RegionDownloader._fetch.
Future<List<int>?> _fetch(HttpClient client, int z, int x, int y,
    {int retries = 3}) async {
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
