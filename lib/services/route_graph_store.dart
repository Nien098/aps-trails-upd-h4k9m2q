// Platform-conditional barrel: the real `dart:io`/`sqlite3`-backed
// RouteGraphStore on every platform that has `dart:io` (Android/iOS/
// desktop), a no-op stub on web (which can't compile `sqlite3` FFI at
// all). TrailRouter imports this file, not either variant directly, so
// it compiles and runs unchanged on both — see route_graph_store_stub.dart
// for why an empty offline network is a safe, honest answer on web rather
// than a special case TrailRouter needs to know about.
export 'route_graph_store_stub.dart'
    if (dart.library.io) 'route_graph_store_io.dart';
