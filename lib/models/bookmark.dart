import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// A curated, small set of pin categories — not user-extensible, matching
/// this app's existing preference for a fixed palette over open-ended
/// configuration (see [TrailColors]). Each carries its own icon/color/map
/// glyph so [BookmarkLayer] and the bookmarks list stay visually in sync
/// without duplicating a lookup in both places.
enum BookmarkCategory {
  scenic('Scenic spot', Icons.landscape, '#2E7D32', 'S'),
  trailhead('Trailhead', Icons.hiking, '#1565C0', 'T'),
  viewpoint('Viewpoint', Icons.visibility, '#6A1B9A', 'V'),
  parking('Parking', Icons.local_parking, '#37474F', 'P'),
  water('Water', Icons.water_drop, '#00838F', 'W'),
  campsite('Campsite', Icons.cabin, '#5D4037', 'C'),
  other('Other', Icons.bookmark, '#EF6C00', '•');

  const BookmarkCategory(this.label, this.icon, this.colorHex, this.glyph);

  final String label;
  final IconData icon;

  /// Matches [kTrailColors]' plain hex-string convention (see
  /// trail_colors.dart) rather than a [Color] — the map layer needs a hex
  /// string anyway, and `Color(int)` needs a UI-side wrapper regardless.
  final String colorHex;

  /// Single-character text drawn on the map marker itself (see
  /// [BookmarkLayer._drawMarker]) — mirrors [CueLayer]'s numbered markers,
  /// which render reliably with this bundled font set; a full icon glyph
  /// would need its own icon-image pipeline this app doesn't have yet.
  final String glyph;

  Color get color => Color(int.parse(colorHex.substring(1), radix: 16) | 0xFF000000);
}

/// A saved point of interest — "here's a nice spot" — independent of any
/// trail, so it can be jumped to from either [BrowseMapScreen] or
/// [AuthorScreen] and used as the starting point for a brand new trail.
class Bookmark {
  Bookmark({
    this.id,
    required this.name,
    required this.category,
    required this.position,
    this.note = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  int? id;
  String name;
  BookmarkCategory category;
  LatLng position;
  String note;
  final DateTime createdAt;
}
