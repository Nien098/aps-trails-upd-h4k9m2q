import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/trail.dart';
import 'trail_codec.dart';

/// Export/import of trails as portable `.trail` JSON files, so an author can
/// send a route to another phone (e.g. Dad → Mom) via WhatsApp, email, etc.
///
/// The actual (de)serialization lives in [TrailCodec] (no `dart:io`, so it's
/// safe to import from web code); this class just re-exposes it for existing
/// mobile call sites, plus [shareTrail] itself, which needs `dart:io` (a temp
/// file) and `share_plus` (the OS share sheet) — neither of which compiles
/// for Flutter web, which is why they're kept out of [TrailCodec].
class TrailShare {
  static Map<String, dynamic> toMap(Trail t) => TrailCodec.toMap(t);
  static Trail fromMap(Map<String, dynamic> m) => TrailCodec.fromMap(m);
  static Trail? tryParse(String contents) => TrailCodec.tryParse(contents);

  /// Writes the trail to a temp `.trail` file and opens the OS share sheet.
  static Future<void> shareTrail(Trail t) async {
    final dir = await getTemporaryDirectory();
    final safe = t.name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final file = File('${dir.path}/${safe.isEmpty ? "trail" : safe}.trail');
    await file.writeAsString(jsonEncode(toMap(t)));
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/json')],
      subject: 'TrailGuide route: ${t.name}',
      text: 'A TrailGuide route. Open it with the TrailGuide app to import.',
    ));
  }
}
