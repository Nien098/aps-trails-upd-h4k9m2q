import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/trail.dart';
import 'geo.dart';

/// Auto-suggests direction cues along a walking [path] from its geometry alone:
/// a Start cue at the beginning, Left/Right cues wherever the route turns
/// sharply, and a Finish cue at the end. Bearings are measured over a short
/// distance window so a dense polyline's jitter (and gentle curves) don't spam
/// cues, and cues are kept a minimum distance apart.
///
/// Works on any trail, hand-drawn or generated — the author can edit or delete
/// each suggestion afterwards like a normal cue.
List<Cue> suggestCues(
  List<LatLng> path, {
  double turnThresholdDeg = 35,
  double windowMeters = 18,
  double minSpacingMeters = 45,
  bool markReturnHalf = false,
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
    cues.add(Cue(type: CueType.start, position: path.first));
    cues.add(Cue(type: CueType.finish, position: path.last));
    return cues;
  }

  LatLng pointAt(double d) => _pointAtDistance(path, cum, d.clamp(0, total));

  cues.add(Cue(type: CueType.start, position: path.first));
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
      // On an out-and-back, cues past the halfway apex belong to the return
      // leg, so they can be told apart from their outbound twin.
      onReturn: markReturnHalf && d > total / 2,
    ));
    lastCueDist = d;
  }

  cues.add(Cue(type: CueType.finish, position: path.last));
  return cues;
}

/// Orders [cues] in walking order along [path]. Each cue is projected onto the
/// route; outbound cues take their first pass over that spot and return cues the
/// last, so an out-and-back that retraces itself fires each cue on the correct
/// leg. Used by Guide mode to trigger cues sequentially without double-firing.
List<Cue> orderCuesAlongPath(List<LatLng> path, List<Cue> cues) {
  if (path.length < 2 || cues.length < 2) return List.of(cues);

  final cum = List<double>.filled(path.length, 0);
  for (var i = 1; i < path.length; i++) {
    cum[i] = cum[i - 1] + metersBetween(path[i - 1], path[i]);
  }

  double alongDistance(Cue c) {
    const nearMeters = 25.0;
    double? chosen; // matched crossing (first for outbound, last for return)
    var globalBest = double.infinity;
    var globalAt = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      final proj = _projectOntoSegment(c.position, path[i], path[i + 1]);
      final at = cum[i] + proj.t * (cum[i + 1] - cum[i]);
      if (proj.meters <= nearMeters) {
        if (chosen == null ||
            (c.onReturn ? at > chosen : at < chosen)) {
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

  final indexed = [for (final c in cues) (c, alongDistance(c))];
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
