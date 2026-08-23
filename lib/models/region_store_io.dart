import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'region.dart';

/// Downloaded-region persistence — extracted out of `region.dart` itself
/// (2026-08-23) so that file, and everything that only needs the plain
/// [Region] model (not disk persistence), can compile on web too — see
/// `region_store.dart`'s barrel doc.
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
