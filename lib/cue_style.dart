import 'package:flutter/material.dart';

import 'models/trail.dart';

/// Marker colour for each cue type — used on the map and in Guide-mode cards.
Color cueColor(CueType t) {
  switch (t) {
    case CueType.start:
    case CueType.finish:
      return const Color(0xFF2E7D32); // green
    case CueType.left:
      return const Color(0xFF1565C0); // blue
    case CueType.right:
      return const Color(0xFFE65100); // orange
    case CueType.uturn:
      return const Color(0xFF795548); // brown
    case CueType.straight:
      return const Color(0xFF00838F); // teal
    case CueType.bridge:
      return const Color(0xFF6A1B9A); // purple
    case CueType.caution:
      return const Color(0xFFC62828); // red
    case CueType.note:
      return const Color(0xFF455A64); // slate
  }
}

/// Hex string (without alpha) for MapLibre paint properties.
String cueColorHex(CueType t) {
  final c = cueColor(t);
  return '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}

/// The type a cue becomes when a trail (or the remaining leg of one) is
/// walked in the opposite direction — left/right and start/finish swap since
/// they're direction-dependent; everything else means the same thing either
/// way (a U-turn is still a U-turn, a caution spot is still a caution spot).
CueType reversedCueType(CueType t) => switch (t) {
      CueType.left => CueType.right,
      CueType.right => CueType.left,
      CueType.start => CueType.finish,
      CueType.finish => CueType.start,
      _ => t,
    };

/// Marker colour for a spot where two or more cues are stacked (e.g. a 4-way
/// crossing) — distinct from every [cueColor] so a stack reads as "multiple
/// cues here" at a glance, before the author or hiker even reads the label.
const Color stackedCueColor = Color(0xFFAD1457); // deep pink/magenta
const String stackedCueColorHex = '#AD1457';

/// Icon shown on Guide-mode cards and the author's type picker.
IconData cueIcon(CueType t) {
  switch (t) {
    case CueType.start:
      return Icons.flag;
    case CueType.finish:
      return Icons.sports_score;
    case CueType.left:
      return Icons.turn_left;
    case CueType.right:
      return Icons.turn_right;
    case CueType.uturn:
      return Icons.u_turn_left;
    case CueType.straight:
      return Icons.straight;
    case CueType.bridge:
      return Icons.directions_walk;
    case CueType.caution:
      return Icons.warning_amber;
    case CueType.note:
      return Icons.push_pin;
  }
}
