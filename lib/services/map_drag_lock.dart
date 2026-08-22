// Platform-conditional barrel: the real DOM-based drag lock on web, a
// no-op stub everywhere else (native platforms disable gestures via
// `BaseMap.gesturesEnabled`, a real MapLibre SDK setting this workaround
// doesn't apply to). See map_drag_lock_web.dart for why this exists at
// all — `MapLibreMap.dragEnabled` does NOT do what its name suggests on
// web.
export 'map_drag_lock_web.dart' if (dart.library.io) 'map_drag_lock_io.dart';
