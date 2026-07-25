import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart';

/// One recorded GPS sample: a position, seconds elapsed since the walk began,
/// and (when known) the altitude in metres — used to draw the elevation profile.
class TrackPoint {
  const TrackPoint(this.position, this.tSec, {this.ele});
  final LatLng position;
  final int tSec;
  final double? ele;
}

/// A single completed walk (a "Runkeeper-style" activity), logged per device.
/// Holds the summary stats plus the recorded GPS track so its route can be
/// re-drawn and per-km/mile splits computed later.
class Activity {
  Activity({
    this.id,
    this.trailId,
    required this.trailName,
    required this.startedAt,
    required this.durationSec,
    required this.distanceMeters,
    required this.elevGainMeters,
    List<TrackPoint>? track,
  }) : track = track ?? [];

  int? id;

  /// The trail walked (may be null if that trail was later deleted).
  int? trailId;
  String trailName;
  DateTime startedAt;
  int durationSec;
  double distanceMeters;
  double elevGainMeters;
  List<TrackPoint> track;

  String trackToJson() => jsonEncode([
        for (final p in track)
          [
            p.position.latitude,
            p.position.longitude,
            p.tSec,
            if (p.ele != null) p.ele,
          ]
      ]);

  static List<TrackPoint> trackFromJson(String? s) {
    if (s == null || s.isEmpty) return [];
    return [
      for (final e in jsonDecode(s) as List)
        TrackPoint(
          LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble()),
          (e[2] as num).toInt(),
          ele: e.length > 3 ? (e[3] as num?)?.toDouble() : null,
        ),
    ];
  }

  Map<String, Object?> toRow() => {
        'trail_id': trailId,
        'trail_name': trailName,
        'started_at': startedAt.millisecondsSinceEpoch,
        'duration_sec': durationSec,
        'distance_meters': distanceMeters,
        'elev_gain_meters': elevGainMeters,
        'track': trackToJson(),
      };

  factory Activity.fromRow(Map<String, Object?> r) => Activity(
        id: r['id'] as int?,
        trailId: r['trail_id'] as int?,
        trailName: (r['trail_name'] as String?) ?? 'Walk',
        startedAt:
            DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int),
        durationSec: (r['duration_sec'] as int?) ?? 0,
        distanceMeters: (r['distance_meters'] as num?)?.toDouble() ?? 0,
        elevGainMeters: (r['elev_gain_meters'] as num?)?.toDouble() ?? 0,
        track: trackFromJson(r['track'] as String?),
      );
}
