import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// A curated, small set of pin categories — not user-extensible, matching
/// this app's existing preference for a fixed palette over open-ended
/// configuration (see [TrailColors]). Drives the marker's background color
/// and the label shown in lists; the marker's actual glyph comes from
/// [Bookmark.icon] instead (see [kBookmarkIcons]), which defaults to a
/// category's icon but can be overridden per-bookmark.
enum BookmarkCategory {
  scenic('Scenic spot', Icons.landscape, '#2E7D32'),
  trailhead('Trailhead', Icons.hiking, '#1565C0'),
  viewpoint('Viewpoint', Icons.visibility, '#6A1B9A'),
  parking('Parking', Icons.local_parking, '#37474F'),
  water('Water', Icons.water_drop, '#00838F'),
  campsite('Campsite', Icons.cabin, '#5D4037'),
  other('Other', Icons.bookmark, '#EF6C00');

  const BookmarkCategory(this.label, this.icon, this.colorHex);

  final String label;

  /// This category's default marker icon — used to seed a new bookmark's
  /// [Bookmark.icon] and as the fallback if a stored icon ever falls outside
  /// [kBookmarkIcons] (e.g. that list shrinks in a future update).
  final IconData icon;

  /// Matches [kTrailColors]' plain hex-string convention (see
  /// trail_colors.dart) rather than a [Color] — the map layer needs a hex
  /// string anyway, and `Color(int)` needs a UI-side wrapper regardless.
  final String colorHex;

  Color get color => Color(int.parse(colorHex.substring(1), radix: 16) | 0xFF000000);
}

/// Selectable marker icons, independent of [BookmarkCategory] — lets a
/// bookmark's pin actually look like what it marks (a picnic table, a
/// waterfall, a lookout) rather than just wearing its category's generic
/// icon. Deliberately a fixed, curated list rather than the full ~2000-icon
/// Material set: [BookmarkLayer] rasterizes each (icon, color) pairing into
/// a bitmap on demand (see `renderMarkerIcon`), so an open-ended picker
/// would mean unbounded image registrations with no real benefit — this
/// covers the situations a trail-bookmark is actually for.
const List<IconData> kBookmarkIcons = [
  Icons.landscape,
  Icons.hiking,
  Icons.terrain,
  Icons.forest,
  Icons.park,
  Icons.visibility,
  Icons.water_drop,
  Icons.pool,
  Icons.beach_access,
  Icons.local_parking,
  Icons.cabin,
  Icons.night_shelter,
  Icons.local_fire_department,
  Icons.photo_camera,
  Icons.restaurant,
  Icons.local_cafe,
  Icons.wc,
  Icons.directions_bike,
  Icons.directions_walk,
  Icons.kayaking,
  Icons.pets,
  Icons.star,
  Icons.favorite,
  Icons.flag,
  Icons.warning_amber,
  Icons.ac_unit,
  Icons.museum,
  Icons.home,
  Icons.route,
  Icons.bookmark,
];

/// Looks up a stored icon by its [IconData.codePoint] (see
/// [Bookmark.icon]'s DB round trip in `TrailStore`), falling back to
/// [fallback] if it's null or no longer in [kBookmarkIcons].
IconData iconForCodePoint(int? codePoint, IconData fallback) {
  if (codePoint == null) return fallback;
  for (final i in kBookmarkIcons) {
    if (i.codePoint == codePoint) return i;
  }
  return fallback;
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
    IconData? icon,
    this.note = '',
    DateTime? createdAt,
  })  : icon = icon ?? category.icon,
        createdAt = createdAt ?? DateTime.now();

  int? id;
  String name;
  BookmarkCategory category;
  LatLng position;

  /// The marker's actual glyph — defaults to [category]'s icon but can be
  /// picked independently (see [kBookmarkIcons]) so the pin can look like
  /// the real thing (a picnic table, a waterfall) rather than just its
  /// category's generic icon.
  IconData icon;
  String note;
  final DateTime createdAt;
}
