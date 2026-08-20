import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'geo.dart';

/// Signed turn angle at [b] going a→b→c, in degrees. Positive = right
/// (clockwise), negative = left (counter-clockwise), 0 = straight on. Shared
/// by `cue_gen.dart`'s windowed turn detection and [immediateTurnAngle]/
/// [findExcursions] below, so both use the exact same geometry.
double turnAngle(LatLng a, LatLng b, LatLng c) {
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
  final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  return math.atan2(y, x) * 180 / math.pi;
}

/// The turn at `path[i]` using only its immediate neighbours (`path[i-1]`,
/// `path[i+1]`) — no interpolation/windowing, unlike `cue_gen.dart`'s
/// distance-windowed turn detection. This is what actually sees a sharp
/// reversal on a short out-and-back spur: a windowed check samples bearing
/// some fixed distance before/after a point, which for a spur shorter than
/// that distance can overshoot the turnaround and sample the main trail on
/// both sides instead, masking a real ~180° reversal as "no turn at all."
/// The immediate-neighbour angle can't do that — it's bounded by the path's
/// own vertex spacing, which after Douglas-Peucker simplification already
/// reflects real geometry, not raw GPS jitter.
double immediateTurnAngle(List<LatLng> path, int i) => turnAngle(path[i - 1], path[i], path[i + 1]);

/// A detected out-and-back excursion: the walker left the path at
/// [entryIndex], reversed direction at [turnIndex], and the return leg
/// mirrors the outbound leg back to [exitIndex] (spatially close to
/// [entryIndex], though not necessarily the exact same point). [oneWayMeters]
/// is the walked distance from entry to the turnaround.
class Excursion {
  const Excursion({
    required this.entryIndex,
    required this.turnIndex,
    required this.exitIndex,
    required this.oneWayMeters,
  });

  final int entryIndex;
  final int turnIndex;
  final int exitIndex;
  final double oneWayMeters;
}

/// Finds out-and-back excursions in [path] — the geometric signature of a
/// dead end, a wrong turn corrected, or a short viewpoint/side spur: walk
/// out, sharp reversal, walk back over roughly the same ground. This is
/// deliberately different from just "a sharp turn somewhere" — a genuine
/// hairpin or a long trail that gradually curves back on itself also
/// reverses direction eventually, but its two "legs" go somewhere new, they
/// don't retrace each other. Checking that the points *after* the reversal
/// stay close to the points *before* it (not just that the bearing
/// reversed) is what tells the two apart.
///
/// Used both to offer a keep-or-remove review right after recording (see
/// `RecordTrailScreen._stop`) and, at render time, to draw a retraced
/// stretch as two visually distinct lines instead of overlapping chevrons
/// (see `RouteLayer`) — the same detection answers both questions, so it's
/// shared rather than duplicated.
List<Excursion> findExcursions(
  List<LatLng> path, {
  double mirrorToleranceMeters = 10,
  double minOneWayMeters = 5,
  double uturnThresholdDeg = 150,
}) {
  if (path.length < 3) return const [];

  final cum = List<double>.filled(path.length, 0);
  for (var i = 1; i < path.length; i++) {
    cum[i] = cum[i - 1] + metersBetween(path[i - 1], path[i]);
  }

  final candidates = <Excursion>[];
  for (var i = 1; i < path.length - 1; i++) {
    if (immediateTurnAngle(path, i).abs() < uturnThresholdDeg) continue;

    var k = 0;
    while (i - (k + 1) >= 0 &&
        i + (k + 1) < path.length &&
        metersBetween(path[i - (k + 1)], path[i + (k + 1)]) <= mirrorToleranceMeters) {
      k++;
    }
    if (k == 0) continue;

    final entry = i - k;
    final oneWay = cum[i] - cum[entry];
    if (oneWay < minOneWayMeters) continue;
    candidates.add(Excursion(
      entryIndex: entry,
      turnIndex: i,
      exitIndex: i + k,
      oneWayMeters: oneWay,
    ));
  }

  // Noisy detection can produce several overlapping candidates for the same
  // physical spur (a reversal a vertex or two away from the "true" sharpest
  // point) — keep only the largest (most complete) one per overlapping
  // cluster, largest first so a later, smaller, overlapping candidate is the
  // one dropped.
  candidates.sort((a, b) => b.oneWayMeters.compareTo(a.oneWayMeters));
  final kept = <Excursion>[];
  for (final c in candidates) {
    final overlaps = kept.any((k) => c.entryIndex <= k.exitIndex && c.exitIndex >= k.entryIndex);
    if (!overlaps) kept.add(c);
  }
  kept.sort((a, b) => a.entryIndex.compareTo(b.entryIndex));
  return kept;
}
