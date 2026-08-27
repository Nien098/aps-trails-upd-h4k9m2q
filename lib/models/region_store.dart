// Re-exports the real `dart:io`-backed persistence for downloaded regions (a
// JSON file on disk). Used to be a platform-conditional barrel with an
// in-memory web stub for the Flutter Web trail designer; that target has
// been fully retired (replaced by a separate TypeScript rewrite), so this is
// now a plain re-export. region.dart exports this file, so its own callers
// (which only ever `import 'region.dart'`) don't need to know this
// indirection exists.
export 'region_store_io.dart';
