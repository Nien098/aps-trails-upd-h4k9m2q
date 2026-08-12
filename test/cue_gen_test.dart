import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:trailguide/models/trail.dart';
import 'package:trailguide/services/cue_gen.dart';

/// Straight north-south line from [lat] with [count] points [stepMeters]
/// apart — ~0.00001 deg lat ≈ 1.1m, used throughout for simple synthetic
/// paths where exact spacing doesn't matter, only shape.
List<LatLng> straightPath(int count, {double stepDeg = 0.0005}) => [
      for (var i = 0; i < count; i++) LatLng(49.2 + i * stepDeg, -122.8),
    ];

void main() {
  group('u-turn classification', () {
    test('dead-end reversal gets uturn, not left/right', () {
      // Out 5 points north, apex, back 5 points south along the same line —
      // a plain reversal with no left/right bias at all.
      final out = straightPath(6); // index 0..5
      final path = [...out, ...out.reversed.skip(1)]; // apex at index 5
      final cues = suggestCues(path, minSpacingMeters: 1, windowMeters: 1);
      final apex = cues.firstWhere((c) => c.position == out.last);
      expect(apex.type, CueType.uturn);
    });

    test('a real ~90 degree turn is still left/right, not uturn', () {
      final path = [
        const LatLng(49.200, -122.800),
        const LatLng(49.201, -122.800),
        const LatLng(49.202, -122.800),
        const LatLng(49.202, -122.799),
        const LatLng(49.202, -122.798),
      ];
      final cues = suggestCues(path, minSpacingMeters: 1, windowMeters: 1);
      expect(cues.any((c) => c.type == CueType.uturn), isFalse);
      expect(cues.any((c) => c.type == CueType.left || c.type == CueType.right),
          isTrue);
    });
  });

  group('junction (stay-straight) cues', () {
    test('a real junction with no turn gets a straight cue', () {
      final path = straightPath(9);
      final midpoint = path[4];
      final cues = suggestCues(
        path,
        minSpacingMeters: 1,
        windowMeters: 1,
        junctions: [midpoint],
      );
      final atJunction =
          cues.where((c) => c.position == midpoint).toList();
      expect(atJunction, hasLength(1));
      expect(atJunction.single.type, CueType.straight);
    });

    test('no junctions given means no straight cues appear', () {
      final path = straightPath(9);
      final cues = suggestCues(path, minSpacingMeters: 1, windowMeters: 1);
      expect(cues.any((c) => c.type == CueType.straight), isFalse);
    });

    test('a junction that coincides with a real turn only gets one cue', () {
      final path = [
        const LatLng(49.200, -122.800),
        const LatLng(49.201, -122.800),
        const LatLng(49.202, -122.800),
        const LatLng(49.202, -122.799),
        const LatLng(49.202, -122.798),
      ];
      final turnPoint = path[2];
      final cues = suggestCues(
        path,
        minSpacingMeters: 1,
        windowMeters: 1,
        junctions: [turnPoint],
      );
      final atTurn = cues.where((c) => c.position == turnPoint).toList();
      expect(atTurn, hasLength(1));
      expect(atTurn.single.type, isNot(CueType.straight));
    });

    test('a junction within minSpacingMeters of a real turn yields only one cue overall', () {
      // p1 (straight-through, ~56m from start) sits a junction; p2 (the real
      // ~90 degree turn) is only ~5.6m further along — well inside the
      // default 45m minSpacingMeters gap enforced after any cue fires.
      final path = [
        const LatLng(49.2000, -122.8000), // p0
        const LatLng(49.2005, -122.8000), // p1 — junction here, ~56m in
        const LatLng(49.20055, -122.8000), // p2 — real turn, ~5.6m past p1
        const LatLng(49.20055, -122.7995), // p3 — turn east, ~36m
        const LatLng(49.20055, -122.7990), // p4 — another ~36m
      ];
      final junctionNear = path[1];
      final cues = suggestCues(
        path,
        minSpacingMeters: 45,
        windowMeters: 5,
        junctions: [junctionNear],
      );
      // The junction cue at p1 consumes the spacing budget, so the real
      // turn at p2 (only ~5.6m later) is correctly suppressed by the same
      // pre-existing lastCueDist gate — only one middle cue fires overall.
      final middleCues =
          cues.where((c) => c.type != CueType.start && c.type != CueType.finish);
      expect(middleCues.length, 1);
      expect(middleCues.single.type, CueType.straight);
    });
  });
}
