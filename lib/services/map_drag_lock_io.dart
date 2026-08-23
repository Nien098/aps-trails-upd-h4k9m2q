/// No-op off web — native platforms disable map gestures via
/// `BaseMap.gesturesEnabled`, a real MapLibre SDK setting this JS-only
/// workaround doesn't apply to.
void setMapDragLocked(bool locked) {}

/// No-op off web — see `map_drag_lock_web.dart`'s `suppressMapContextMenu`.
void suppressMapContextMenu() {}
