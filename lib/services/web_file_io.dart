import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/trail.dart';
import 'trail_codec.dart';

/// Browser-native save/open for `.trail` files — the desktop designer's
/// equivalent of the mobile app's OS-share-sheet / native-intent flow (see
/// `TrailShare`, which can't be reused here: it imports `dart:io`, which
/// doesn't compile for Flutter web at all). A file download and a plain
/// `<input type=file>` picker are the natural desktop-browser stand-ins —
/// both read/write the exact same `.trail` JSON format via [TrailCodec], so
/// a trail designed here opens on the phone through the same import path
/// that already works today.
class WebTrailIo {
  /// Triggers a browser download of [trail] as a `.trail` JSON file.
  static void save(Trail trail) {
    final json = jsonEncode(TrailCodec.toMap(trail));
    final blob = web.Blob(
      [json.toJS].toJS,
      web.BlobPropertyBag(type: 'application/json'),
    );
    final url = web.URL.createObjectURL(blob);
    final safe = trail.name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    web.HTMLAnchorElement()
      ..href = url
      ..download = '${safe.isEmpty ? "trail" : safe}.trail'
      ..click();
    web.URL.revokeObjectURL(url);
  }

  /// Opens the browser's file picker and returns the parsed Trail, or null
  /// if the user cancelled or the chosen file wasn't a valid `.trail` file.
  static Future<Trail?> open() {
    final completer = Completer<Trail?>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = '.trail,application/json';
    // The listener itself must stay synchronous — `.toJS` can only convert a
    // plain (non-async) function signature to a JS callback; the actual file
    // read still happens asynchronously via `.then()` instead of `await`.
    input.addEventListener(
      'change',
      (web.Event _) {
        final file = input.files?.item(0);
        if (file == null) {
          completer.complete(null);
          return;
        }
        file.text().toDart.then((jsText) {
          completer.complete(TrailCodec.tryParse(jsText.toDart));
        });
      }.toJS,
    );
    input.click();
    return completer.future;
  }
}
