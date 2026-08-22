import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Tracks the browser's real pointer position and converts it to CSS
/// pixels relative to MapLibre's own canvas element — the coordinate space
/// `MapLibreMapController.toLatLng`/`toScreenLocation` actually expect on
/// web (see `map_drag_lock_web.dart`'s doc for the related discovery that
/// `dragEnabled` doesn't mean what its name suggests there either).
///
/// **Why this exists**: the freehand-draw and line-adjust tools drive their
/// drag capture off a Flutter `GestureDetector`, reading each callback's
/// `Offset` (`d.localPosition`) and feeding it straight to
/// `c.toLatLng(Point(...))`. That looked reasonable — click-to-draw already
/// worked, and mobile does the exact same `Offset` → `toLatLng` conversion
/// (with a devicePixelRatio multiply that web doesn't need, fixed
/// separately) — but confirmed live (2026-08-22): drawn points landed
/// hundreds of pixels from the actual cursor even after removing that
/// multiply, and the size of the miss didn't scale in any way that matched
/// a simple pixel-ratio error. Root cause: click-to-draw's coordinates
/// never come from Flutter's `Offset` at all — `maplibre_gl_web`'s
/// `_onMapClick` reads `e.point.x`/`e.point.y` straight off MapLibre GL
/// JS's own `MapMouseEvent`, computed by the JS library directly from the
/// native DOM event. Flutter Web's platform-view embedding for the
/// MapLibre canvas does not guarantee its `Offset`/`localPosition` space
/// lines up 1:1 with that — there's no public evidence it's supposed to,
/// and live testing showed it doesn't. Fix: stop trusting Flutter's
/// coordinate system for this conversion entirely. This class tracks the
/// browser's raw `clientX`/`clientY` via a `document`-level listener
/// (unaffected by `map_drag_lock`'s `pointer-events: none` on the canvas,
/// since a document-level listener sees every pointer event in the page
/// regardless of which element it targets) and converts to canvas-relative
/// coordinates using `getBoundingClientRect()` — the same
/// `clientX - rect.left` math MapLibre GL JS itself uses internally
/// (`DOM.mousePos`). The Flutter `GestureDetector` overlay is still used
/// for drag *lifecycle* (start/update/end timing, which it gets right) —
/// just not for *position* anymore.
class PointerProbe {
  static num _clientX = 0;
  static num _clientY = 0;
  static bool _started = false;

  static void ensureStarted() {
    if (_started) return;
    _started = true;
    web.document.addEventListener(
      'pointermove',
      (web.PointerEvent e) {
        _clientX = e.clientX;
        _clientY = e.clientY;
      }.toJS,
    );
  }

  /// The last known real pointer position, in CSS pixels relative to
  /// MapLibre's own canvas element — or null if that canvas isn't found
  /// (map not yet loaded).
  static ({double x, double y})? mapRelativePosition() {
    final canvas = web.document.querySelector('.maplibregl-canvas');
    if (canvas == null) return null;
    final rect = canvas.getBoundingClientRect();
    return (x: _clientX - rect.left, y: _clientY - rect.top);
  }
}
