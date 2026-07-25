import 'dart:convert';
import 'dart:io';

import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

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

Future<File> _userRegionsFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/user_regions.json');
}

Future<void> loadUserRegions() async {
  try {
    final f = await _userRegionsFile();
    if (!f.existsSync()) return;
    final list = jsonDecode(await f.readAsString()) as List;
    userRegions = [for (final e in list) Region.fromJson(e as Map<String, dynamic>)];
  } catch (_) {
    userRegions = [];
  }
}

Future<void> _saveUserRegions() async {
  final f = await _userRegionsFile();
  await f.writeAsString(jsonEncode([for (final r in userRegions) r.toJson()]));
}

Future<void> addUserRegion(Region r) async {
  userRegions.removeWhere((e) => e.id == r.id);
  userRegions.add(r);
  await _saveUserRegions();
}

Future<void> removeUserRegion(String id) async {
  userRegions.removeWhere((e) => e.id == id);
  await _saveUserRegions();
  // Best-effort delete of the downloaded basemap file.
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/map/$id.pmtiles');
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}

/// Bookmarked areas within the bundled map. Ordered roughly by likelihood of
/// use for the parents (their home trails first). All share one basemap.
const List<Region> kRegions = [
  Region(
    id: 'coquitlam',
    name: 'Coquitlam River',
    center: LatLng(49.265, -122.825),
    south: 49.22, west: -122.90, north: 49.31, east: -122.75,
  ),
  Region(
    id: 'port_coquitlam',
    name: 'Port Coquitlam',
    center: LatLng(49.265, -122.750),
    south: 49.22, west: -122.82, north: 49.31, east: -122.68,
  ),
  Region(
    id: 'maple_ridge',
    name: 'Maple Ridge / Pitt Meadows',
    center: LatLng(49.220, -122.600),
    south: 49.18, west: -122.72, north: 49.30, east: -122.48,
  ),
  Region(
    id: 'lynn_valley',
    name: 'Lynn Valley (North Van)',
    center: LatLng(49.375, -123.020),
    south: 49.32, west: -123.06, north: 49.43, east: -122.98,
  ),
  Region(
    id: 'capilano',
    name: 'Capilano (North Van)',
    center: LatLng(49.365, -123.120),
    south: 49.32, west: -123.16, north: 49.41, east: -123.08,
  ),
  Region(
    id: 'west_van',
    name: 'West Vancouver',
    center: LatLng(49.370, -123.230),
    south: 49.33, west: -123.31, north: 49.43, east: -123.16,
  ),
  Region(
    id: 'vancouver',
    name: 'Vancouver',
    center: LatLng(49.280, -123.120),
    south: 49.20, west: -123.22, north: 49.32, east: -123.02,
  ),
  Region(
    id: 'tsawwassen',
    name: 'Tsawwassen / Delta',
    center: LatLng(49.010, -123.080),
    south: 48.96, west: -123.17, north: 49.10, east: -122.95,
  ),
  Region(
    id: 'abbotsford',
    name: 'Abbotsford',
    center: LatLng(49.050, -122.300),
    south: 49.00, west: -122.42, north: 49.12, east: -122.18,
  ),
  Region(
    id: 'chilliwack',
    name: 'Chilliwack',
    center: LatLng(49.160, -121.950),
    south: 49.08, west: -122.10, north: 49.24, east: -121.80,
  ),
  Region(
    id: 'squamish',
    name: 'Squamish / The Chief',
    center: LatLng(49.700, -123.150),
    south: 49.60, west: -123.28, north: 49.80, east: -123.05,
  ),
  Region(
    id: 'whistler',
    name: 'Whistler',
    center: LatLng(50.115, -122.955),
    south: 50.05, west: -123.05, north: 50.20, east: -122.85,
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
