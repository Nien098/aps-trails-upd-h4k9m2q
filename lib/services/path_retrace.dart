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

LatLng _lerp(LatLng a, LatLng b, double t) => LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );

/// The point [distance] metres before `path[from]`, walking back toward
/// index 0 and linearly interpolating between whichever two vertices
/// straddle that distance — see [findExcursions] for why comparing at a
/// matched *physical distance* (not matched vertex index) matters.
LatLng _pointBefore(List<LatLng> path, List<double> cum, int from, double distance) {
  final target = cum[from] - distance;
  if (target <= 0) return path.first;
  var j = from;
  while (j > 0 && cum[j - 1] > target) {
    j--;
  }
  if (j == 0) return path.first;
  final segLen = cum[j] - cum[j - 1];
  final t = segLen <= 0 ? 0.0 : (cum[j] - target) / segLen;
  return _lerp(path[j], path[j - 1], t);
}

/// The point [distance] metres after `path[from]` — mirror of [_pointBefore].
LatLng _pointAfter(List<LatLng> path, List<double> cum, int from, double distance) {
  final target = cum[from] + distance;
  if (target >= cum.last) return path.last;
  var j = from;
  while (j < path.length - 1 && cum[j + 1] < target) {
    j++;
  }
  if (j == path.length - 1) return path.last;
  final segLen = cum[j + 1] - cum[j];
  final t = segLen <= 0 ? 0.0 : (target - cum[j]) / segLen;
  return _lerp(path[j], path[j + 1], t);
}

/// The last vertex index whose cumulative distance is still >= `cum[from] -
/// distance` — i.e. an existing vertex at or just past [distance] before
/// [from], for slicing an excursion's outbound leg without needing a
/// synthetic interpolated point in the actual returned path.
int _indexBefore(List<double> cum, int from, double distance) {
  final target = cum[from] - distance;
  var j = from;
  while (j > 0 && cum[j - 1] >= target) {
    j--;
  }
  return j;
}

/// Mirror of [_indexBefore] for the return leg.
int _indexAfter(List<double> cum, int from, double distance) {
  final target = cum[from] + distance;
  var j = from;
  while (j < cum.length - 1 && cum[j + 1] <= target) {
    j++;
  }
  return j;
}

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

  const distanceStep = 2.0;

  final candidates = <Excursion>[];
  for (var i = 1; i < path.length - 1; i++) {
    if (immediateTurnAngle(path, i).abs() < uturnThresholdDeg) continue;

    // Walk outward from the reversal in fixed physical-distance steps,
    // comparing an *interpolated* point at that same distance before and
    // after the turn — not the raw vertex `mirrorToleranceMeters` steps
    // away on each side. The original version compared `path[i-k]` against
    // `path[i+k]` for a shared vertex-count `k`, which silently breaks the
    // moment the outbound and return legs have different vertex density for
    // the same physical ground — exactly what a routed (TrailRouter.
    // connect()) out-and-back produces (Dijkstra can walk the same edges in
    // a different order/fragmentation each direction). Confirmed live: a
    // real out-and-back drawn in the desktop designer rendered as one
    // un-split line, with the outbound and return passes' direction arrows
    // landing almost on top of each other and visually merging into an X at
    // every arrow position instead of getting the dashed/offset treatment.
    // A GPS-recorded trail's near-uniform sampling made the old vertex-count
    // check work well enough there, but that was luck, not something this
    // function actually required — comparing at matched *distance* instead
    // behaves the same for uniform-density paths and correctly handles
    // uneven ones too.
    final maxD = math.min(cum[i], cum.last - cum[i]);
    var bestD = 0.0;
    var d = distanceStep;
    while (d <= maxD) {
      final back = _pointBefore(path, cum, i, d);
      final fwd = _pointAfter(path, cum, i, d);
      if (metersBetween(back, fwd) > mirrorToleranceMeters) break;
      bestD = d;
      d += distanceStep;
    }
    if (bestD < minOneWayMeters) continue;

    candidates.add(Excursion(
      entryIndex: _indexBefore(cum, i, bestD),
      turnIndex: i,
      exitIndex: _indexAfter(cum, i, bestD),
      oneWayMeters: bestD,
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
