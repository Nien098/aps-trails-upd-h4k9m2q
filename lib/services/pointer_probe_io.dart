/// No-op off web — native platforms get correct drag coordinates straight
/// from Flutter's own `Offset`/`localPosition` system, no browser-specific
/// workaround needed.
class PointerProbe {
  static void ensureStarted() {}

  static ({double x, double y})? mapRelativePosition() => null;
}
