import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../models/region.dart';
import 'settings.dart';

/// Copies bundled offline map assets (region pmtiles, glyphs) out of the
/// Flutter asset bundle onto the device filesystem, because MapLibre Native
/// reads these resources from real files, not from the asset bundle. Then
/// builds a MapLibre style pointing at a chosen region's pmtiles — bundled or
/// downloaded.
class OfflineMap {
  static const _glyphAssets = <String>[
    'assets/glyphs/Noto Sans Regular/0-255.pbf',
    'assets/glyphs/Noto Sans Regular/256-511.pbf',
    'assets/glyphs/Noto Sans Medium/0-255.pbf',
    'assets/glyphs/Noto Sans Medium/256-511.pbf',
    'assets/glyphs/Open Sans Regular,Arial Unicode MS Regular/0-255.pbf',
    'assets/glyphs/Open Sans Regular,Arial Unicode MS Regular/256-511.pbf',
  ];

  static Future<String>? _glyphsReady;
  static Future<void>? _bakedReady;
  static Future<void>? _worldReady;
  static final Map<String, Future<String>> _styles = {};
  static Future<String>? _onlineStyle;

  /// Style.json path for [region] (bundled or downloaded). Cached per basemap.
  static Future<String> styleFor(Region region) =>
      _styles[region.mapAsset] ??= _buildStyle(region);

  static Future<String> _buildStyle(Region region) async {
    final root = await _ensureGlyphs();
    await _ensureWorldBasemap();
    if (!region.isDownloaded) await _ensureBakedBasemap();
    final template = await rootBundle.loadString('assets/style/style.json');
    final style = template
        .replaceAll('__DOC__', root.replaceAll('\\', '/'))
        .replaceAll('__REGION__', region.mapAsset);
    final file = File('$root/style_${region.mapAsset}.json');
    await file.writeAsString(style, flush: true);
    return file.path;
  }

  /// Online style (live Protomaps tiles) used to frame + download a new region.
  static Future<String> onlineStyleFile() => _onlineStyle ??= _buildOnline();

  static Future<String> _buildOnline() async {
    final root = await _ensureGlyphs();
    await _ensureWorldBasemap();
    final template = await rootBundle.loadString('assets/style/style.json');
    final style = template
        .replaceAll(
          '"url": "pmtiles://file://__DOC__/map/__REGION__.pmtiles"',
          '"tiles": ["$kProtomapsTileTemplate"], "minzoom": 0, "maxzoom": 15',
        )
        .replaceAll('__DOC__', root.replaceAll('\\', '/'));
    final file = File('$root/style_online.json');
    await file.writeAsString(style, flush: true);
    return file.path;
  }

  static const int _mapPartCount = 14;
  static const int _mapBytes = 205760133;

  /// Small (single-file, unchunked — see route_graph.sqlite's copy pattern
  /// in route_graph_store.dart for precedent at this size) whole-world,
  /// low-zoom basemap — see tools/build_world_basemap.dart for how it's
  /// built and why. Layered beneath every region's own pmtiles (style.json's
  /// "world" source) so panning/zooming out of any bundled or downloaded
  /// region's coverage shows real coastline/landmass shapes instead of the
  /// flat background.
  static const int _worldBytes = 60753026;

  static Future<void> _ensureWorldBasemap() => _worldReady ??= _copyWorld();

  static Future<void> _copyWorld() async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/map/world.pmtiles');
    await dest.parent.create(recursive: true);
    if (dest.existsSync() && dest.lengthSync() == _worldBytes) return;
    final data = await rootBundle.load('assets/map/world.pmtiles');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await dest.writeAsBytes(bytes, flush: true);
  }

  static Future<String> _ensureGlyphs() => _glyphsReady ??= _copyGlyphs();

  static Future<String> _copyGlyphs() async {
    final dir = await getApplicationDocumentsDirectory();
    final root = dir.path;
    for (final asset in _glyphAssets) {
      final rel = asset.substring('assets/'.length);
      final dest = File('$root/$rel');
      await dest.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List();
      if (!dest.existsSync() || dest.lengthSync() != bytes.length) {
        await dest.writeAsBytes(bytes, flush: true);
      }
    }
    return root;
  }

  static Future<void> _ensureBakedBasemap() => _bakedReady ??= _copyBaked();

  static Future<void> _copyBaked() async {
    final dir = await getApplicationDocumentsDirectory();
    final root = dir.path;
    final mapFile = File('$root/map/$kMapAsset.pmtiles');
    await mapFile.parent.create(recursive: true);
    // A live in-app update (HomeScreen._updateBundledMap, via the same
    // RegionDownloader pipeline as a downloaded region) replaces this exact
    // file with data fetched fresh from Protomaps. Once that's happened,
    // never overwrite it with the older data baked into this build — the
    // size-mismatch check below would otherwise "restore" the stale copy
    // on every cold start, silently undoing the update.
    if (Settings.instance.bundledMapUpdated.value) return;
    if (!mapFile.existsSync() || mapFile.lengthSync() != _mapBytes) {
      final sink = mapFile.openWrite();
      try {
        for (var i = 0; i < _mapPartCount; i++) {
          final part =
              'assets/map/$kMapAsset.part.${i.toString().padLeft(2, '0')}';
          final data = await rootBundle.load(part);
          sink.add(data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes));
          await sink.flush();
        }
      } finally {
        await sink.close();
      }
    }
  }
}
