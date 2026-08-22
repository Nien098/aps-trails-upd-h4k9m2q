// Platform-conditional barrel: the real browser-pointer-tracking probe on
// web, a no-op stub everywhere else. See pointer_probe_web.dart for why
// this exists at all — Flutter's own `Offset`/`localPosition` turned out
// not to be trustworthy for driving MapLibre's `toLatLng`/`toScreenLocation`
// on web.
export 'pointer_probe_web.dart' if (dart.library.io) 'pointer_probe_io.dart';
