import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:trailguide/cue_style.dart';
import 'package:trailguide/models/trail.dart';

/// Mirrors HomeScreen._reverseDirection's transform exactly (minus the
/// dialog/persistence), so the pure logic can be exercised directly.
void reverseInPlace(Trail t) {
  t.path = t.path.reversed.toList();
  if (t.anchors.isNotEmpty) t.anchors = t.anchors.reversed.toList();
  if (t.cues.isNotEmpty) {
    final maxOrder = t.cues.map((c) => c.order).reduce((a, b) => a > b ? a : b);
    for (final cue in t.cues) {
      cue.order = maxOrder - cue.order;
      reverseCueInPlace(cue);
    }
  }
}

Trail sampleTrail() => Trail(
      name: 'Sample',
      path: [
        const LatLng(49.260, -122.800),
        const LatLng(49.261, -122.800),
        const LatLng(49.262, -122.800),
        const LatLng(49.263, -122.800),
      ],
      cues: [
        Cue(type: CueType.start, position: const LatLng(49.260, -122.800), order: 0),
        Cue(type: CueType.left, position: const LatLng(49.261, -122.800), order: 1),
        Cue(type: CueType.right, position: const LatLng(49.262, -122.800), order: 2),
        Cue(type: CueType.finish, position: const LatLng(49.263, -122.800), order: 3),
      ],
    );

void main() {
  test('path and anchors reverse', () {
    final t = sampleTrail();
    final firstBefore = t.path.first;
    final lastBefore = t.path.last;
    reverseInPlace(t);
    expect(t.path.first, lastBefore);
    expect(t.path.last, firstBefore);
  });

  test('cue firing order reverses', () {
    final t = sampleTrail();
    reverseInPlace(t);
    final sorted = List.of(t.cues)..sort((a, b) => a.order.compareTo(b.order));
    // Walking the other way, the first cue encountered should be the one at
    // the new start of the path (the old finish position).
    expect(sorted.first.position, const LatLng(49.263, -122.800));
    expect(sorted.last.position, const LatLng(49.260, -122.800));
  });

  test('cue TYPES swap correctly', () {
    final t = sampleTrail();
    reverseInPlace(t);
    final byPos = {for (final c in t.cues) c.position: c};
    expect(byPos[const LatLng(49.261, -122.800)]!.type, CueType.right);
    expect(byPos[const LatLng(49.262, -122.800)]!.type, CueType.left);
    expect(byPos[const LatLng(49.260, -122.800)]!.type, CueType.finish);
    expect(byPos[const LatLng(49.263, -122.800)]!.type, CueType.start);
  });

  test('SPOKEN TEXT matches the swapped type (this is what the walker hears)', () {
    final t = sampleTrail();
    reverseInPlace(t);
    final byPos = {for (final c in t.cues) c.position: c};
    // The cue that is now a RIGHT turn must not still say "Turn left here".
    expect(byPos[const LatLng(49.261, -122.800)]!.spoken,
        CueType.right.defaultSpoken);
    expect(byPos[const LatLng(49.262, -122.800)]!.spoken,
        CueType.left.defaultSpoken);
  });

  test('LABEL matches the swapped type (shown on the map + card)', () {
    final t = sampleTrail();
    reverseInPlace(t);
    final byPos = {for (final c in t.cues) c.position: c};
    expect(byPos[const LatLng(49.261, -122.800)]!.label, CueType.right.label);
    expect(byPos[const LatLng(49.262, -122.800)]!.label, CueType.left.label);
  });

  test('custom wording on a direction-independent cue survives a reverse', () {
    final t = Trail(
      name: 'Custom',
      path: [
        const LatLng(49.260, -122.800),
        const LatLng(49.261, -122.800),
      ],
      cues: [
        Cue(
            type: CueType.caution,
            position: const LatLng(49.260, -122.800),
            order: 0,
            label: 'Roots',
            spoken: 'Careful, big tree roots across the path'),
        Cue(
            type: CueType.note,
            position: const LatLng(49.261, -122.800),
            order: 1,
            label: 'Bench',
            spoken: 'The bench with the view is here'),
      ],
    );
    reverseInPlace(t);
    final byPos = {for (final c in t.cues) c.position: c};
    expect(byPos[const LatLng(49.260, -122.800)]!.spoken,
        'Careful, big tree roots across the path');
    expect(byPos[const LatLng(49.261, -122.800)]!.label, 'Bench');
  });

  test('reversing twice returns to the original', () {
    final t = sampleTrail();
    final origTypes = [for (final c in t.cues) c.type];
    final origSpoken = [for (final c in t.cues) c.spoken];
    reverseInPlace(t);
    reverseInPlace(t);
    final sorted = List.of(t.cues)..sort((a, b) => a.order.compareTo(b.order));
    expect([for (final c in sorted) c.type], origTypes);
    expect([for (final c in sorted) c.spoken], origSpoken);
  });
}
