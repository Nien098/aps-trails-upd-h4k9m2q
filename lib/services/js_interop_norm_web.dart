import 'dart:js_interop';

/// `maplibre_gl_web`'s `queryRenderedFeaturesInRect` returns each feature's
/// `properties` and `geometry.coordinates` as raw, un-converted JS values —
/// see its `FeatureJsImpl`/`GeometryJsImpl` interop declarations
/// (`external JSAny? get properties`/`coordinates`; only primitive getters
/// like `type` convert automatically). Left as-is, these fail every plain
/// Dart `is Map`/`is List` check downstream — `TrailRouter._Graph.addLine`'s
/// own `if (coords is! List) return;` guard, in particular — silently, with
/// no exception, no matter what's actually rendered on screen. This was the
/// real cause of the desktop designer never snapping to trails: not a
/// viewport/zoom issue, a raw-JS-object-vs-Dart-type mismatch specific to
/// the web platform binding. `dartify()` is `dart:js_interop`'s standard
/// recursive JS→Dart conversion (JSObject→Map, JSArray→List, JSNumber→num,
/// …) and turns these back into values `addLine`/the props cast can use.
dynamic normalizeJs(dynamic value) => (value as JSAny?)?.dartify();
