// Re-exports the real `dart:io`/`sqlite3`-backed RouteGraphStore (a
// persistent, bundled/downloaded offline network). Used to be a
// platform-conditional barrel with a live-Overpass-fetch web stub for the
// Flutter Web trail designer; that target has been fully retired (replaced
// by a separate TypeScript rewrite), so this is now a plain re-export.
// TrailRouter still imports this file, not route_graph_store_io.dart
// directly, in case a platform split is ever needed again.
export 'route_graph_store_io.dart';
