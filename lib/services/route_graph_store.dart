// Platform-conditional barrel: the real `dart:io`/`sqlite3`-backed
// RouteGraphStore (a persistent, bundled/downloaded offline network) on
// every platform that has `dart:io` (Android/iOS/desktop), a live
// Overpass-API-backed one on web (which can't compile `sqlite3` FFI or
// touch a real filesystem at all — see route_graph_store_stub.dart for why
// a live fetch, not a bundled file, is the right shape there). TrailRouter
// imports this file, not either variant directly, so it compiles and runs
// unchanged on both — an empty result from either one just means "nothing
// offline found in this area," never a special case TrailRouter needs to
// know about.
export 'route_graph_store_stub.dart'
    if (dart.library.io) 'route_graph_store_io.dart';
