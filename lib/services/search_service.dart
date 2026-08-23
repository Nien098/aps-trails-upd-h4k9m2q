// Platform-conditional barrel, same shape as route_graph_store.dart: the
// real `dart:io`/`sqlite3`-backed SearchService (FTS5 over the bundled
// streets.sqlite) on every platform that has `dart:io`, a flat-JSON/
// in-memory one on web (which can't compile `sqlite3` FFI at all — see
// search_service_io.dart's class doc for why). Callers import this file,
// not either variant directly, so they compile and run unchanged on both.
export 'search_service_stub.dart' if (dart.library.io) 'search_service_io.dart';
