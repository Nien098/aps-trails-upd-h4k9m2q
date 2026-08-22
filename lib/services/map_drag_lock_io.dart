/// No-op off web — native platforms disable map gestures via
/// `BaseMap.gesturesEnabled`, a real MapLibre SDK setting this JS-only
/// workaround doesn't apply to.
void setMapDragLocked(bool locked) {}
