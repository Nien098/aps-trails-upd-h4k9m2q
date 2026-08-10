import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart';

import '../services/geo.dart';

/// One recorded GPS sample: a position, seconds elapsed since the walk began,
/// and (when known) the altitude in metres — used to draw the elevation profile.
class TrackPoint {
  const TrackPoint(this.position, this.tSec, {this.ele});
  final LatLng position;
  final int tSec;
  final double? ele;
}

/// Shared by [Activity] and [WalkCheckpoint], which both persist a track.
String _encodeTrack(List<TrackPoint> track) => jsonEncode([
      for (final p in track)
        [
          p.position.latitude,
          p.position.longitude,
          p.tSec,
          if (p.ele != null) p.ele,
        ]
    ]);

List<TrackPoint> _decodeTrack(String? s) {
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

  String trackToJson() => _encodeTrack(track);

  static List<TrackPoint> trackFromJson(String? s) => _decodeTrack(s);

  /// Seconds actually moving (excludes long pauses / standing still) —
  /// used for "moving time"/"moving pace" stats, distinct from
  /// [durationSec] (total elapsed, pauses included). Falls back to
  /// [durationSec] if the track is too sparse to tell.
  int movingSeconds() {
    var moving = 0;
    for (var i = 1; i < track.length; i++) {
      final dt = track[i].tSec - track[i - 1].tSec;
      final d = metersBetween(track[i - 1].position, track[i].position);
      if (dt > 0 && dt < 120 && d >= 2) moving += dt;
    }
    return moving == 0 ? durationSec : moving;
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

/// A checkpoint of an in-progress walk, written periodically during Guide
/// mode (cue fires, pause/resume, and every ~15s while walking) so an
/// interrupted walk — the app killed by Android, not a deliberate Stop —
/// can be resumed close to where it left off instead of losing everything
/// and restarting from the trailhead. Cleared once the walk ends normally
/// (see GuideScreen._saveWalk). Only one is ever kept per trail.
class WalkCheckpoint {
  WalkCheckpoint({
    required this.trailId,
    required this.trailName,
    required this.startedAt,
    this.pausedTotalSec = 0,
    this.wasPaused = false,
    required this.nextIndex,
    required this.walkedMeters,
    required this.elevGainMeters,
    this.lastPos,
    List<TrackPoint>? track,
  }) : track = track ?? [];

  final int trailId;
  final String trailName;
  final DateTime startedAt;

  /// Total paused duration so far, so resumed elapsed time stays correct.
  final int pausedTotalSec;

  /// Whether the walk was mid-pause when this checkpoint was written — a
  /// resumed session reopens paused too, rather than silently restarting
  /// GPS tracking without the walker's fresh say-so.
  final bool wasPaused;

  /// Index into the trail's sorted cue list of the next expected cue.
  final int nextIndex;
  final double walkedMeters;
  final double elevGainMeters;
  final LatLng? lastPos;
  final List<TrackPoint> track;

  Map<String, Object?> toRow() => {
        'trail_id': trailId,
        'trail_name': trailName,
        'started_at': startedAt.millisecondsSinceEpoch,
        'paused_total_sec': pausedTotalSec,
        'was_paused': wasPaused ? 1 : 0,
        'next_index': nextIndex,
        'walked_meters': walkedMeters,
        'elev_gain_meters': elevGainMeters,
        'last_lat': lastPos?.latitude,
        'last_lng': lastPos?.longitude,
        'track': _encodeTrack(track),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };

  factory WalkCheckpoint.fromRow(Map<String, Object?> r) => WalkCheckpoint(
        trailId: r['trail_id'] as int,
        trailName: (r['trail_name'] as String?) ?? 'Walk',
        startedAt: DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int),
        pausedTotalSec: (r['paused_total_sec'] as int?) ?? 0,
        wasPaused: (r['was_paused'] as int?) == 1,
        nextIndex: (r['next_index'] as int?) ?? 0,
        walkedMeters: (r['walked_meters'] as num?)?.toDouble() ?? 0,
        elevGainMeters: (r['elev_gain_meters'] as num?)?.toDouble() ?? 0,
        lastPos: r['last_lat'] != null && r['last_lng'] != null
            ? LatLng((r['last_lat'] as num).toDouble(),
                (r['last_lng'] as num).toDouble())
            : null,
        track: _decodeTrack(r['track'] as String?),
      );
}

/// A checkpoint of an in-progress *recording* (RecordTrailScreen), written
/// periodically and on pause so a recording session interrupted by the app
/// being killed — not a deliberate Stop — can be resumed instead of losing
/// the whole walk. Unlike [WalkCheckpoint], there's no trail id to key this
/// by yet (the trail doesn't exist until the recording finishes and is
/// saved), so only one recording checkpoint is ever kept at a time — the app
/// only supports recording one trail at a time anyway. Cleared once the
/// recording ends normally (deliberate Stop) or the walker discards it.
class RecordingCheckpoint {
  RecordingCheckpoint({
    required this.regionId,
    required this.startedAt,
    this.pausedTotalSec = 0,
    this.wasPaused = false,
    required this.walkedMeters,
    required this.elevGainMeters,
    required this.path,
    List<TrackPoint>? track,
  }) : track = track ?? [];

  final String regionId;
  final DateTime startedAt;
  final int pausedTotalSec;
  final bool wasPaused;
  final double walkedMeters;
  final double elevGainMeters;

  /// The recorded (raw, not yet cleaned/simplified) path so far.
  final List<LatLng> path;
  final List<TrackPoint> track;

  static String _encodePath(List<LatLng> path) =>
      jsonEncode(path.map((p) => [p.latitude, p.longitude]).toList());

  static List<LatLng> _decodePath(String? s) {
    if (s == null || s.isEmpty) return [];
    return [
      for (final e in jsonDecode(s) as List)
        LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble()),
    ];
  }

  Map<String, Object?> toRow() => {
        'region_id': regionId,
        'started_at': startedAt.millisecondsSinceEpoch,
        'paused_total_sec': pausedTotalSec,
        'was_paused': wasPaused ? 1 : 0,
        'walked_meters': walkedMeters,
        'elev_gain_meters': elevGainMeters,
        'path': _encodePath(path),
        'track': _encodeTrack(track),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };

  factory RecordingCheckpoint.fromRow(Map<String, Object?> r) =>
      RecordingCheckpoint(
        regionId: (r['region_id'] as String?) ?? 'coquitlam',
        startedAt: DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int),
        pausedTotalSec: (r['paused_total_sec'] as int?) ?? 0,
        wasPaused: (r['was_paused'] as int?) == 1,
        walkedMeters: (r['walked_meters'] as num?)?.toDouble() ?? 0,
        elevGainMeters: (r['elev_gain_meters'] as num?)?.toDouble() ?? 0,
        path: _decodePath(r['path'] as String?),
        track: _decodeTrack(r['track'] as String?),
      );
}
