import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../models/region.dart';
import 'pmtiles_writer.dart';

/// Progress of a region download.
class DownloadProgress {
  DownloadProgress(this.done, this.total, this.bytes);
  final int done;
  final int total;
  final int bytes;
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
          }
          done++;
        }
        onProgress
            ?.call(DownloadProgress(done, tiles.length, writer.byteCount));
      }
    } finally {
      client.close(force: true);
    }

    if (_cancelled) {
      // Abort: close/clean the temp file, leave nothing behind.
      try {
        await writer.finish(outPath,
            west: west, south: south, east: east, north: north,
            minZoom: kRegionMinZoom, maxZoom: kRegionMaxZoom);
        await File(outPath).delete();
      } catch (_) {}
      try {
        await File(tempPath).delete();
      } catch (_) {}
      return null;
    }

    await writer.finish(outPath,
        west: west, south: south, east: east, north: north,
        minZoom: kRegionMinZoom, maxZoom: kRegionMaxZoom);

    return Region(
      id: id,
      name: name,
      center: LatLng((south + north) / 2, (west + east) / 2),
      south: south, west: west, north: north, east: east,
      mapAsset: id,
    );
  }

  Future<List<int>?> _fetch(HttpClient client, int z, int x, int y) async {
    try {
      final req = await client.getUrl(Uri.parse(protomapsTileUrl(z, x, y)));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain();
        return null;
      }
      final b = BytesBuilder();
      await for (final chunk in resp) {
        b.add(chunk);
      }
      return b.takeBytes();
    } catch (_) {
      return null;
    }
  }
}
