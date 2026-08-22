import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:trailguide/services/path_retrace.dart';

/// Straight line from [a] to [b] (both plain lat/lng offsets in metres,
/// converted crudely via a fixed degrees-per-metre factor — fine for a unit
/// test that only cares about relative geometry, not real-world accuracy),
/// split into [n] evenly-spaced vertices.
List<LatLng> _line(double fromLat, double fromLng, double toLat, double toLng, int n) {
  return [
    for (var i = 0; i <= n; i++)
      LatLng(
        fromLat + (toLat - fromLat) * i / n,
        fromLng + (toLng - fromLng) * i / n,
      ),
  ];
}

void main() {
  test('detects a symmetric out-and-back (dense, matched vertex count)', () {
    // Out from (0,0) to (0, 0.001) and back, 10 vertices each way.
    final out = _line(0, 0, 0, 0.001, 10);
    final back = _line(0, 0.001, 0, 0, 10).skip(1).toList();
    final path = [...out, ...back];

    final excursions = findExcursions(path);
    expect(excursions, isNotEmpty);
    expect(excursions.first.turnIndex, out.length - 1);
  });

  test('detects an out-and-back with mismatched vertex density between legs', () {
    // Same physical out-and-back as above, but the outbound leg is coarse
    // (3 vertices) while the return leg is dense (30 vertices) — mirrors a
    // TrailRouter.connect()-routed pair of legs that traversed the same
    // edges with different fragmentation. The old index-matched comparison
    // (path[i-k] vs path[i+k]) broke on exactly this shape.
    final out = _line(0, 0, 0, 0.001, 3);
    final back = _line(0, 0.001, 0, 0, 30).skip(1).toList();
    final path = [...out, ...back];

    final excursions = findExcursions(path);
    expect(excursions, isNotEmpty,
        reason: 'mismatched vertex density on each leg should not hide a real retrace');
    expect(excursions.first.turnIndex, out.length - 1);
    // Should recognise most of the ~111m one-way leg (0.001 deg lat ~ 111m).
    expect(excursions.first.oneWayMeters, greaterThan(80));
  });

  test('does not flag a hairpin that goes somewhere new as an excursion', () {
    // A gradual curve that reverses overall bearing but keeps moving away
    // sideways the whole time (like a long switchback) — the two "halves"
    // never come back close to each other, so this must not be an excursion.
    final path = [
      const LatLng(0, 0),
      const LatLng(0.0005, 0.0002),
      const LatLng(0.001, 0.0005),
      const LatLng(0.0012, 0.001),
      const LatLng(0.001, 0.0015),
      const LatLng(0.0005, 0.0018),
      const LatLng(0, 0.002),
    ];
    final excursions = findExcursions(path);
    expect(excursions, isEmpty);
  });
}
