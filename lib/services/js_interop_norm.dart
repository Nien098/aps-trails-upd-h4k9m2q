// Platform-conditional barrel — see js_interop_norm_web.dart's doc for why
// this exists. Native platforms (has dart:io) get the passthrough version;
// web gets the dartify() conversion.
export 'js_interop_norm_web.dart' if (dart.library.io) 'js_interop_norm_io.dart';
