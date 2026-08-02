import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/trail.dart';

/// Export/import of trails as portable `.trail` JSON files, so an author can
/// send a route to another phone (e.g. Dad → Mom) via WhatsApp, email, etc.
class TrailShare {
  static Map<String, dynamic> toMap(Trail t) => {
        'app': 'trailguide',
        'v': 1,
        'name': t.name,
        'regionId': t.regionId,
        'color': t.color,
        'anchors': jsonDecode(t.anchorsToJson()),
        'path': jsonDecode(t.pathToJson()),
        'cues': jsonDecode(t.cuesToJson()),
      };

  static Trail fromMap(Map<String, dynamic> m) {
    final name = (m['name'] as String?)?.trim();
    final path = Trail.pathFromJson(jsonEncode(m['path'] ?? []));
    return Trail(
      name: (name == null || name.isEmpty) ? 'Imported trail' : name,
      regionId: m['regionId'] as String? ?? 'coquitlam',
      color: m['color'] as String? ?? '#1565C0',
      path: path,
      anchors: Trail.pathFromJson(jsonEncode(m['anchors'] ?? [])),
      cues: Trail.cuesFromJson(jsonEncode(m['cues'] ?? []), path: path),
    );
  }

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

  /// Parses shared `.trail` file contents into a Trail, or null if not ours.
  static Trail? tryParse(String contents) {
    try {
      final m = jsonDecode(contents);
      if (m is Map && m['app'] == 'trailguide') {
        return fromMap(m.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }
}
