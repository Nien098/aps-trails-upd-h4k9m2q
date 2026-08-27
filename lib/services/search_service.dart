// Re-exports the real `dart:io`/`sqlite3`-backed SearchService (FTS5 over
// the bundled streets.sqlite). Used to be a platform-conditional barrel with
// a web-stub fallback for the Flutter Web trail designer; that target has
// been fully retired (replaced by a separate TypeScript rewrite), so this is
// now a plain re-export. Callers still import this file, not
// search_service_io.dart directly, in case a platform split is ever needed
// again.
export 'search_service_io.dart';
