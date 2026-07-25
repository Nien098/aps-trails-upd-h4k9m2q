import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart';

/// The kind of direction cue, which drives the marker's icon/colour and the
/// default spoken phrase. Authors can override the spoken text per cue.
enum CueType {
  start('Start', '🏁', 'You are at the start of the trail'),
  left('Turn left', '⬅️', 'Turn left here'),
  right('Turn right', '➡️', 'Turn right here'),
  straight('Stay straight', '⬆️', 'Stay straight'),
  bridge('Bridge', '🌉', 'Cross the bridge'),
  caution('Caution', '⚠️', 'Careful here'),
  note('Note', '📍', ''),
  finish('Finish', '🏁', 'You have arrived. This is the end of the trail');

  const CueType(this.label, this.emoji, this.defaultSpoken);

  /// Short human label for the type, shown in the author's picker.
  final String label;

  /// Emoji used as a lightweight map marker glyph.
  final String emoji;

  /// Default phrase spoken aloud when the walker reaches this cue.
  final String defaultSpoken;
}

/// A single direction cue placed along a trail.
class Cue {
  Cue({
    required this.type,
    required this.position,
    String? label,
    String? spoken,
    this.radiusMeters = 25,
    this.onReturn = false,
    this.returnEnabled = false,
    this.returnType = CueType.straight,
    String? returnLabel,
    String? returnSpoken,
  })  : label = label ?? type.label,
        spoken = spoken ?? type.defaultSpoken,
        returnLabel = returnLabel ?? returnType.label,
        returnSpoken = returnSpoken ?? returnType.defaultSpoken;

  /// The direction category (drives icon + default phrase).
  CueType type;

  /// Where on the map the cue sits.
  LatLng position;

  /// Short text shown on the map next to the marker.
  String label;

  /// The full phrase read aloud / shown large in Guide mode.
  String spoken;

  /// How close (metres) the walker must be for the cue to fire.
  double radiusMeters;

  /// Which leg of an out-and-back / loop this cue belongs to. false = the
  /// outbound pass (default), true = the return pass. Used to order cues along
  /// the route and to fire the right one when the path overlaps itself.
  /// Ignored when [returnEnabled] (then the cue fires on both legs).
  bool onReturn;

  /// When true this single node carries TWO directions at the same spot: the
  /// primary ([type]/[label]/[spoken]) fires on the way out, and the return
  /// action below fires on the way back. Lets one crossroads marker say e.g.
  /// "turn left" outbound and "turn right" on the return.
  bool returnEnabled;
  CueType returnType;
  String returnLabel;
  String returnSpoken;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'lat': position.latitude,
        'lng': position.longitude,
        'label': label,
        'spoken': spoken,
        'radius': radiusMeters,
        'onReturn': onReturn,
        if (returnEnabled) 'returnEnabled': true,
        if (returnEnabled) 'returnType': returnType.name,
        if (returnEnabled) 'returnLabel': returnLabel,
        if (returnEnabled) 'returnSpoken': returnSpoken,
      };

  factory Cue.fromJson(Map<String, dynamic> j) => Cue(
        type: CueType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => CueType.note,
        ),
        position: LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        label: j['label'] as String?,
        spoken: j['spoken'] as String?,
        radiusMeters: (j['radius'] as num?)?.toDouble() ?? 25,
        onReturn: j['onReturn'] as bool? ?? false,
        returnEnabled: j['returnEnabled'] as bool? ?? false,
        returnType: CueType.values.firstWhere(
          (t) => t.name == j['returnType'],
          orElse: () => CueType.straight,
        ),
        returnLabel: j['returnLabel'] as String?,
        returnSpoken: j['returnSpoken'] as String?,
      );
}

/// A saved trail: an ordered path plus the cues placed along it.
class Trail {
  Trail({
    this.id,
    required this.name,
    this.regionId = 'coquitlam',
    this.color = '#1565C0',
    List<LatLng>? path,
    List<LatLng>? anchors,
    List<Cue>? cues,
    DateTime? createdAt,
    this.walkedMeters = 0,
    this.walkCount = 0,
    this.elevGainMeters = 0,
  })  : path = path ?? [],
        anchors = anchors ?? [],
        cues = cues ?? [],
        createdAt = createdAt ?? DateTime.now();

  int? id;
  String name;

  /// Per-device walk stats (not shared): total distance walked on this trail
  /// across all outings, how many times it's been walked, and total elevation
  /// gained (climbed).
  double walkedMeters;
  int walkCount;
  double elevGainMeters;

  /// Which pre-loaded map region this trail lives in (see [Region]).
  String regionId;

  /// The route line colour (hex, e.g. '#1565C0') shown drawing and guiding.
  String color;

  /// The full walking route polyline (follows trail geometry between anchors).
  /// Drawn on the map and used for guidance / off-route detection.
  List<LatLng> path;

  /// The waypoints the author tapped. Editing anchors re-derives [path].
  /// Empty for legacy trails saved before auto-follow (then path == anchors).
  List<LatLng> anchors;

  /// Direction cues placed along the trail.
  List<Cue> cues;

  DateTime createdAt;

  static String _encodePoints(List<LatLng> pts) =>
      jsonEncode(pts.map((p) => [p.latitude, p.longitude]).toList());

  String pathToJson() => _encodePoints(path);

  String anchorsToJson() => _encodePoints(anchors);

  String cuesToJson() => jsonEncode(cues.map((c) => c.toJson()).toList());

  static List<LatLng> pathFromJson(String s) => (jsonDecode(s) as List)
      .map((e) => LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble()))
      .toList();

  static List<Cue> cuesFromJson(String s) => (jsonDecode(s) as List)
      .map((e) => Cue.fromJson(e as Map<String, dynamic>))
      .toList();

  /// Full snapshot for backup (includes per-device walk stats).
  Map<String, dynamic> toBackupJson() => {
        'name': name,
        'regionId': regionId,
        'color': color,
        'path': jsonDecode(pathToJson()),
        'anchors': jsonDecode(anchorsToJson()),
        'cues': jsonDecode(cuesToJson()),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'walkedMeters': walkedMeters,
        'walkCount': walkCount,
        'elevGainMeters': elevGainMeters,
      };

  factory Trail.fromBackupJson(Map<String, dynamic> j) => Trail(
        name: j['name'] as String? ?? 'Trail',
        regionId: j['regionId'] as String? ?? 'coquitlam',
        color: j['color'] as String? ?? '#1565C0',
        path: Trail.pathFromJson(jsonEncode(j['path'] ?? [])),
        anchors: Trail.pathFromJson(jsonEncode(j['anchors'] ?? [])),
        cues: Trail.cuesFromJson(jsonEncode(j['cues'] ?? [])),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
        walkedMeters: (j['walkedMeters'] as num?)?.toDouble() ?? 0,
        walkCount: (j['walkCount'] as int?) ?? 0,
        elevGainMeters: (j['elevGainMeters'] as num?)?.toDouble() ?? 0,
      );
}
