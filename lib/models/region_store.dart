// Platform-conditional barrel, same shape as services/route_graph_store.dart:
// the real `dart:io`-backed persistence for downloaded regions (a JSON file
// on disk) on every platform that has `dart:io`, a web stub that just
// mutates the in-memory `userRegions` list on web (which has no downloaded-
// region concept at all — desktop_designer_screen.dart never calls
// RegionDownloader). region.dart exports this file, so its own callers
// (which only ever `import 'region.dart'`) get whichever variant matches
// the platform without needing to know this split exists.
export 'region_store_stub.dart' if (dart.library.io) 'region_store_io.dart';
