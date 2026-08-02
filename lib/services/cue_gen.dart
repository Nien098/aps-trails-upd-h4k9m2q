import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/trail.dart';
import 'geo.dart';

/// Auto-suggests direction cues along a walking [path] from its geometry alone:
/// a Start cue at the beginning, Left/Right cues wherever the route turns
/// sharply, and a Finish cue at the end. Bearings are measured over a short
/// distance window so a dense polyline's jitter (and gentle curves) don't spam
/// cues, and cues are kept a minimum distance apart. [order] is assigned
/// sequentially as the path is walked start to finish, so an out-and-back or
/// loop's full path (both legs) naturally comes out correctly ordered with no
/// special-casing needed.
///
/// Works on any trail, hand-drawn or generated — the author can edit or delete
/// each suggestion afterwards like a normal cue.
List<Cue> suggestCues(
  List<LatLng> path, {
  double turnThresholdDeg = 35,
  double windowMeters = 18,
  double minSpacingMeters = 45,
}) {
  final cues = <Cue>[];
  if (path.length < 2) return cues;

  // Cumulative distance to each vertex.
  final cum = List<double>.filled(path.length, 0);
  for (var i = 1; i < path.length; i++) {
    cum[i] = cum[i - 1] + metersBetween(path[i - 1], path[i]);
  }
  final total = cum.last;
  if (total < minSpacingMeters * 2) {
    // Too short to bother with turn cues; just bookend it.
    cues.add(Cue(type: CueType.start, position: path.first, order: 0));
    cues.add(Cue(type: CueType.finish, position: path.last, order: 1));
    return cues;
  }

  LatLng pointAt(double d) => _pointAtDistance(path, cum, d.clamp(0, total));

  cues.add(Cue(type: CueType.start, position: path.first, order: cues.length));
  var lastCueDist = 0.0;

  for (var i = 1; i < path.length - 1; i++) {
    final d = cum[i];
    // Skip the immediate ends where a start/finish cue already sits.
    if (d < minSpacingMeters || total - d < minSpacingMeters) continue;
    if (d - lastCueDist < minSpacingMeters) continue;

    final before = pointAt(d - windowMeters);
    final after = pointAt(d + windowMeters);
    final turn = _turnAngle(before, path[i], after);
    if (turn.abs() < turnThresholdDeg) continue;

    cues.add(Cue(
      type: turn > 0 ? CueType.right : CueType.left,
      position: path[i],
      order: cues.length,
    ));
    lastCueDist = d;
  }

  cues.add(Cue(type: CueType.finish, position: path.last, order: cues.length));
  return cues;
}

/// One-time conversion for a trail saved before the stack-order model: [raw]
/// is the decoded `cues` JSON (still possibly carrying the old `onReturn`/
/// `returnEnabled`/`returnType`/`returnLabel`/`returnSpoken` fields), which
/// this expands (a dual-action node becomes two ordinary stack cues at the
/// same position) and orders with the old geometry-projection heuristic — a
/// reasonable starting point, not a guaranteed-correct one for a path that
/// crosses itself more than twice. The result is a plain, already-ordered
/// [Cue] list on the new model; any mis-ordering can be fixed afterwards with
/// drag-to-reorder in the cue list, same as any other cue.
List<Cue> migrateLegacyCues(List<Map<String, dynamic>> raw, List<LatLng> path) {
  final temps = <_LegacyTemp>[];
  for (final m in raw) {
    final type = CueType.values.firstWhere((t) => t.name == m['type'],
        orElse: () => CueType.note);
    final position =
        LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble());
    final label = m['label'] as String? ?? type.label;
    final spoken = m['spoken'] as String? ?? type.defaultSpoken;
    final radius = (m['radius'] as num?)?.toDouble() ?? 25;
    final onReturn = m['onReturn'] as bool? ?? false;
    final returnEnabled = m['returnEnabled'] as bool? ?? false;
    if (returnEnabled) {
      final returnType = CueType.values.firstWhere(
          (t) => t.name == m['returnType'],
          orElse: () => CueType.straight);
      temps.add(_LegacyTemp(
          type: type,
          position: position,
          label: label,
          spoken: spoken,
          radius: radius,
          onReturn: false));
      temps.add(_LegacyTemp(
          type: returnType,
          position: position,
          label: m['returnLabel'] as String? ?? returnType.label,
          spoken: m['returnSpoken'] as String? ?? returnType.defaultSpoken,
          radius: radius,
          onReturn: true));
    } else {
      temps.add(_LegacyTemp(
          type: type,
          position: position,
          label: label,
          spoken: spoken,
          radius: radius,
          onReturn: onReturn));
    }
  }

  final ordered = _legacyOrder(path, temps);
  return [
    for (var i = 0; i < ordered.length; i++)
      Cue(
        type: ordered[i].type,
        position: ordered[i].position,
        label: ordered[i].label,
        spoken: ordered[i].spoken,
        radiusMeters: ordered[i].radius,
        order: i,
      ),
  ];
}

class _LegacyTemp {
  _LegacyTemp({
    required this.type,
    required this.position,
    required this.label,
    required this.spoken,
    required this.radius,
    required this.onReturn,
  });
  final CueType type;
  final LatLng position;
  final String label;
  final String spoken;
  final double radius;
  final bool onReturn;
}

/// The old geometry-based ordering: projects each temp cue onto [path] and
/// sorts by distance along it — outbound temps take their first crossing,
/// return temps their last, within a tolerance. Only used for one-time
/// legacy migration now; live ordering uses [Cue.order] directly.
List<_LegacyTemp> _legacyOrder(List<LatLng> path, List<_LegacyTemp> temps) {
  if (path.length < 2 || temps.length < 2) return List.of(temps);

  final cum = List<double>.filled(path.length, 0);
  for (var i = 1; i < path.length; i++) {
    cum[i] = cum[i - 1] + metersBetween(path[i - 1], path[i]);
  }

  double alongDistance(_LegacyTemp t) {
    const nearMeters = 25.0;
    double? chosen;
    var globalBest = double.infinity;
    var globalAt = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      final proj = _projectOntoSegment(t.position, path[i], path[i + 1]);
      final at = cum[i] + proj.t * (cum[i + 1] - cum[i]);
      if (proj.meters <= nearMeters) {
        if (chosen == null || (t.onReturn ? at > chosen : at < chosen)) {
          chosen = at;
        }
      }
      if (proj.meters < globalBest) {
        globalBest = proj.meters;
        globalAt = at;
      }
    }
    return chosen ?? globalAt;
  }

  final indexed = [for (final t in temps) (t, alongDistance(t))];
  indexed.sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final e in indexed) e.$1];
}

/// Projection of [p] onto segment [a]–[b]: parameter [t] in 0..1 and the
/// perpendicular distance in metres (local equirectangular projection).
({double t, double meters}) _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
  const mPerDegLat = 111320.0;
  final cosLat = math.cos(p.latitude * math.pi / 180);
  double x(LatLng q) => (q.longitude - p.longitude) * mPerDegLat * cosLat;
  double y(LatLng q) => (q.latitude - p.latitude) * mPerDegLat;

  final ax = x(a), ay = y(a), bx = x(b), by = y(b);
  final dx = bx - ax, dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  var t = lenSq == 0 ? 0.0 : -(ax * dx + ay * dy) / lenSq;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx, cy = ay + t * dy;
  return (t: t, meters: math.sqrt(cx * cx + cy * cy));
}

/// Interpolates the point lying [d] metres along the polyline.
LatLng _pointAtDistance(List<LatLng> path, List<double> cum, double d) {
  if (d <= 0) return path.first;
  if (d >= cum.last) return path.last;
  // Find the segment containing d.
  var lo = 0, hi = cum.length - 1;
  while (lo + 1 < hi) {
    final mid = (lo + hi) ~/ 2;
    if (cum[mid] <= d) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final segLen = cum[hi] - cum[lo];
  final t = segLen == 0 ? 0.0 : (d - cum[lo]) / segLen;
  final a = path[lo], b = path[hi];
  return LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );
}

/// Signed turn at [b] going a→b→c, in degrees. Positive = right (clockwise),
/// negative = left. 0 = straight on.
double _turnAngle(LatLng a, LatLng b, LatLng c) {
  final into = _bearing(a, b);
  final out = _bearing(b, c);
  var delta = out - into;
  while (delta > 180) {
    delta -= 360;
  }
  while (delta < -180) {
    delta += 360;
  }
  return delta;
}

/// Compass bearing from [a] to [b] in degrees (0 = north, +90 = east).
double _bearing(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dLon) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  return math.atan2(y, x) * 180 / math.pi;
}
