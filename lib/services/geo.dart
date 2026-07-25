import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Great-circle distance in metres between two points.
double metersBetween(LatLng a, LatLng b) =>
    Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

/// Total length in metres of a polyline (0 for fewer than two points).
double pathLength(List<LatLng> path) {
  var total = 0.0;
  for (var i = 0; i < path.length - 1; i++) {
    total += metersBetween(path[i], path[i + 1]);
  }
  return total;
}

/// Shortest distance in metres from point [p] to the polyline [path].
/// Returns [double.infinity] for an empty path.
double distanceToPath(LatLng p, List<LatLng> path) {
  if (path.isEmpty) return double.infinity;
  if (path.length == 1) return metersBetween(p, path.first);
  var best = double.infinity;
  for (var i = 0; i < path.length - 1; i++) {
    final d = _projectOntoSegment(p, path[i], path[i + 1]).meters;
    if (d < best) best = d;
  }
  return best;
}

/// The point on polyline [path] nearest to [p] — used to snap a cue marker
/// onto the drawn trail line. Falls back to [p] itself for an empty path.
LatLng nearestPointOnPath(LatLng p, List<LatLng> path) {
  if (path.isEmpty) return p;
  if (path.length == 1) return path.first;
  var best = path.first;
  var bestDist = double.infinity;
  for (var i = 0; i < path.length - 1; i++) {
    final proj = _projectOntoSegment(p, path[i], path[i + 1]);
    if (proj.meters < bestDist) {
      bestDist = proj.meters;
      best = proj.point;
    }
  }
  return best;
}

/// Nearest point on segment [a]–[b] to [p] (and its distance in metres), using
/// a local equirectangular projection centred on [p] (accurate at trail scale).
({LatLng point, double meters}) _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
  const metersPerDegLat = 111320.0;
  final cosLat = math.cos(p.latitude * math.pi / 180);

  double x(LatLng q) => (q.longitude - p.longitude) * metersPerDegLat * cosLat;
  double y(LatLng q) => (q.latitude - p.latitude) * metersPerDegLat;

  final ax = x(a), ay = y(a), bx = x(b), by = y(b);
  final dx = bx - ax, dy = by - ay;
  final segLenSq = dx * dx + dy * dy;

  // p is the origin (0,0); project it onto the segment.
  double t = segLenSq == 0 ? 0 : -(ax * dx + ay * dy) / segLenSq;
  t = t.clamp(0.0, 1.0);

  final cx = ax + t * dx, cy = ay + t * dy;
  final meters = math.sqrt(cx * cx + cy * cy);
  final lat = p.latitude + cy / metersPerDegLat;
  final lng = p.longitude + cx / (metersPerDegLat * cosLat);
  return (point: LatLng(lat, lng), meters: meters);
}

/// Douglas–Peucker simplification: drops points that lie within
/// [toleranceMeters] of the straight line between their neighbours, removing
/// GPS jitter while keeping genuine turns and curves.
List<LatLng> simplifyPath(List<LatLng> pts, double toleranceMeters) {
  if (pts.length < 3) return pts;
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = true;
  keep[pts.length - 1] = true;

  void recurse(int start, int end) {
    var maxDist = 0.0;
    var maxIdx = -1;
    for (var i = start + 1; i < end; i++) {
      final d = _projectOntoSegment(pts[i], pts[start], pts[end]).meters;
      if (d > maxDist) {
        maxDist = d;
        maxIdx = i;
      }
    }
    if (maxIdx != -1 && maxDist > toleranceMeters) {
      keep[maxIdx] = true;
      recurse(start, maxIdx);
      recurse(maxIdx, end);
    }
  }

  recurse(0, pts.length - 1);
  return [for (var i = 0; i < pts.length; i++) if (keep[i]) pts[i]];
}
