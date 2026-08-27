// Re-exports the passthrough (non-web) implementation. Used to be a
// platform-conditional barrel with a dartify()-converting web variant for
// the Flutter Web trail designer; that target has been fully retired
// (replaced by a separate TypeScript rewrite), so this is now a plain
// re-export.
export 'js_interop_norm_io.dart';
