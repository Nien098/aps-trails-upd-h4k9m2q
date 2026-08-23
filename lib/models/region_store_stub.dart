import 'region.dart';

/// Web equivalent of `region_store_io.dart` — no disk to persist to (and
/// nothing that ever populates [userRegions] on web today, since
/// `desktop_designer_screen.dart` never calls `RegionDownloader`), so these
/// just mutate the in-memory list for API-parity with the io variant rather
/// than actually persisting anything.
Future<void> loadUserRegions() async {}

Future<void> addUserRegion(Region r) async {
  userRegions.removeWhere((e) => e.id == r.id);
  userRegions.add(r);
}

Future<void> removeUserRegion(String id) async {
  userRegions.removeWhere((e) => e.id == id);
}
