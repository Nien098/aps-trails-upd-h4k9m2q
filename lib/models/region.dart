import 'package:maplibre_gl/maplibre_gl.dart';

import 'trail.dart';

export 'region_store.dart';

/// The single bundled offline basemap covering ~100 km around Burnaby
/// (Victoria → Whistler → Hope → the US border). Matches the pmtiles asset
/// name assets/map/<id>.pmtiles.
const String kMapAsset = 'southwest_bc';

/// A "jump to" area. Bundled bookmarks all share the [kMapAsset] basemap;
/// user-downloaded regions carry their own [mapAsset] (a pmtiles file at
/// <docs>/map/<mapAsset>.pmtiles).
class Region {
  const Region({
    required this.id,
    required this.name,
    required this.center,
    required this.south,
    required this.west,
    required this.north,
    required this.east,
    this.mapAsset = kMapAsset,
  });

  final String id;
  final String name;
  final LatLng center;
  final double south, west, north, east;

  /// Which pmtiles file backs this region. Bundled regions share [kMapAsset];
  /// downloaded regions use their own id.
  final String mapAsset;

  /// A downloaded region has its own basemap file (not the bundled one).
  bool get isDownloaded => mapAsset != kMapAsset;

  bool contains(LatLng p) =>
      p.latitude >= south &&
      p.latitude <= north &&
      p.longitude >= west &&
      p.longitude <= east;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': center.latitude,
        'lng': center.longitude,
        'south': south,
        'west': west,
        'north': north,
        'east': east,
        'mapAsset': mapAsset,
      };

  factory Region.fromJson(Map<String, dynamic> j) => Region(
        id: j['id'] as String,
        name: j['name'] as String,
        center: LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        south: (j['south'] as num).toDouble(),
        west: (j['west'] as num).toDouble(),
        north: (j['north'] as num).toDouble(),
        east: (j['east'] as num).toDouble(),
        mapAsset: (j['mapAsset'] as String?) ?? j['id'] as String,
      );
}

/// Downloaded regions, loaded at startup and persisted to a JSON file.
List<Region> userRegions = [];

/// Bundled bookmarks + any downloaded regions.
List<Region> allRegions() => [...kRegions, ...userRegions];

/// Bookmarked areas within the bundled map. The bundled pmtiles covers a
/// ~100km span (Victoria → Whistler → Hope → the US border) as one file, so
/// these two bookmarks aren't separate maps — just a starting camera
/// position + a bounding box used to label/route a point to a name (see
/// [regionForPoint]). Previously this list had 12 separate Lower-Mainland
/// entries (Coquitlam, Port Coquitlam, Maple Ridge, Lynn Valley, Capilano,
/// West Van, Vancouver, Tsawwassen, Abbotsford, Chilliwack, Squamish,
/// Whistler) — merged into one "Vancouver - Mainland" bookmark since picking
/// between them was more choice than the underlying data actually warranted
/// (they're all the same map). Victoria stays separate: it's across the
/// water on Vancouver Island, not really "mainland," and its bbox doesn't
/// overlap the merged one.
const List<Region> kRegions = [
  Region(
    id: 'vancouver_mainland',
    name: 'Vancouver - Mainland',
    center: LatLng(49.265, -122.825),
    south: 48.96, west: -123.31, north: 50.20, east: -121.80,
  ),
  Region(
    id: 'victoria',
    name: 'Victoria (Vancouver Island)',
    center: LatLng(48.428, -123.365),
    south: 48.35, west: -123.50, north: 48.55, east: -123.25,
  ),
];

final Region kDefaultRegion = kRegions[0];

Region regionById(String id) =>
    allRegions().firstWhere((r) => r.id == id, orElse: () => kDefaultRegion);

/// The bookmarked area whose bounds contain [p], or the default if none match.
Region regionForPoint(LatLng p) =>
    allRegions().firstWhere((r) => r.contains(p), orElse: () => kDefaultRegion);

/// Resolves the region a trail belongs to — primarily by its stored
/// [Trail.regionId], but falling back to geography (the region whose bbox
/// actually contains the trail's own first point) when that id no longer
/// matches any current region.
///
/// A downloaded region's id isn't stable across delete-then-redownload — a
/// fresh download always mints a brand-new one (see
/// `DownloadRegionScreen._startDownload`'s `'dl_${DateTime.now()...}'`) —
/// so without this fallback, deleting and redownloading the exact same area
/// would silently orphan every trail that pointed at the old id: they'd
/// fall through [regionById]'s generic `orElse` straight to
/// [kDefaultRegion], the *wrong* basemap entirely, rather than finding
/// their way back to the region that now actually covers them. Callers that
/// can persist the correction (see `AuthorScreen`/`GuideScreen`) should
/// update `Trail.regionId` once this returns a match that differs from the
/// stored one, so the trail "self-heals" — future lookups go straight to
/// [regionById] again instead of paying for a geography fallback every time.
Region regionForTrail(Trail t) {
  final exact = allRegions().where((r) => r.id == t.regionId);
  if (exact.isNotEmpty) return exact.first;
  final point =
      t.anchors.isNotEmpty ? t.anchors.first : (t.path.isNotEmpty ? t.path.first : null);
  return point == null ? kDefaultRegion : regionForPoint(point);
}
