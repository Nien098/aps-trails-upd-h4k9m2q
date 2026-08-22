import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../config.dart';

/// Builds a MapLibre style JSON string for the web desktop designer — live
/// online Protomaps tiles, no local file staging at all (unlike
/// `OfflineMap`, which this deliberately does NOT reuse: that file imports
/// `dart:io`/`path_provider` to copy bundled pmtiles/glyphs onto a real
/// filesystem, which doesn't exist in a browser and doesn't compile for
/// Flutter web in the first place). The desktop designer is a desk tool with
/// an internet connection, not a field tool, so there's no need for offline
/// tiles at all.
///
/// On web, `MapLibreMap.styleString` accepts a raw JSON string directly (per
/// the plugin's own doc), so this returns the finished style text ready to
/// pass straight in — no file write, no asset copy.
Future<String> buildWebMapStyle() async {
  final template = await rootBundle.loadString('assets/style/style.json');
  final style = jsonDecode(template) as Map<String, dynamic>;

  final sources = (style['sources'] as Map).cast<String, dynamic>();
  sources['protomaps'] = {
    'type': 'vector',
    'attribution': '© OpenStreetMap',
    'tiles': [kProtomapsTileTemplate],
    'minzoom': 0,
    'maxzoom': 15,
  };
  // The "world" low-zoom fallback layer only makes sense with a bundled
  // world.pmtiles file staged onto local disk (see OfflineMap) — there's no
  // such file on web, and none is needed: online tiles already cover the
  // whole planet at every zoom.
  sources.remove('world');
  final layers = (style['layers'] as List)
      .cast<Map<String, dynamic>>()
      .where((l) => l['source'] != 'world')
      .toList();
  style['layers'] = layers;

  // Flutter web serves every pubspec-declared asset at "assets/<original
  // path>" — the outer "assets/" is Flutter's own web-serving convention,
  // separate from (and in addition to) this project's actual asset folder
  // already being named "assets/..." — confirmed via the real served URL
  // for style.json itself: "assets/assets/style/style.json". Getting this
  // wrong doesn't break the map (glyphs are only used for text labels), but
  // does mean silently missing place/road name labels everywhere.
  style['glyphs'] = 'assets/assets/glyphs/{fontstack}/{range}.pbf';

  return jsonEncode(style);
}
