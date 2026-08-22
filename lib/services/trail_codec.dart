import 'dart:convert';

import '../models/trail.dart';

/// Pure (de)serialization of a [Trail] to/from the portable `.trail` JSON
/// format — deliberately split out of `trail_share.dart` (which also pulls
/// in `dart:io`/`share_plus` for the mobile OS share sheet) so this half can
/// be imported from web code too: `dart:io` doesn't compile for Flutter web
/// at all, so any file importing it — even for a method a web caller never
/// calls — breaks the whole web build the moment that file is on the import
/// graph. `TrailShare` re-exposes these as static methods for existing
/// mobile call sites, unchanged.
class TrailCodec {
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

  /// Parses `.trail` file contents into a Trail, or null if not ours.
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
