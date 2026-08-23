import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Locks or unlocks MapLibre GL JS's own native mouse-drag camera panning,
/// independent of Flutter's `MapLibreMap.dragEnabled` constructor flag.
///
/// **Why this exists**: `dragEnabled` was assumed (by an earlier version of
/// the freehand-draw tool) to disable camera drag-to-pan on web the same way
/// `BaseMap.gesturesEnabled = false` does on the native Android SDK. Reading
/// `maplibre_gl_web`'s source (`maplibre_web_gl_platform.dart`) disproved
/// that: on web, `dragEnabled` only gates whether `mouseup`/`mousemove`
/// listeners for *annotation* dragging (a draggable Symbol/Circle) get
/// attached — it never touches `map.dragPan`, the actual JS-library
/// interaction handler that pans the camera on drag. Confirmed live: a user
/// could still grab and move the map while the freehand tool's overlay was
/// supposedly capturing the drag. There is also no runtime setter reachable
/// from app code to call `map.dragPan.disable()` directly — the public
/// `maplibre_gl` package's `MapLibreMapController` keeps its
/// `MapLibrePlatform` (and, on web, the underlying JS `Map` instance) private.
///
/// Instead of reaching into that private state, this sets `pointer-events:
/// none` directly on MapLibre's own `<canvas class="maplibregl-canvas">`
/// element (a stable, documented part of MapLibre GL JS's public CSS API,
/// not an internal implementation detail) — the browser then never delivers
/// a `mousedown`/`touchstart` to the canvas at all, so `dragPan`,
/// `scrollZoom`, `dragRotate`, etc. never see the gesture in the first
/// place. A sibling Flutter `GestureDetector` overlay (used for freehand
/// draw / grab-and-bend) still receives every pointer event as normal,
/// since it's rendered in Flutter's own layer, not the DOM node being
/// locked here.
void setMapDragLocked(bool locked) {
  final canvases = web.document.querySelectorAll('.maplibregl-canvas');
  for (var i = 0; i < canvases.length; i++) {
    final el = canvases.item(i);
    if (el != null && el.isA<web.HTMLElement>()) {
      (el as web.HTMLElement)
          .style
          .setProperty('pointer-events', locked ? 'none' : 'auto');
    }
  }
}

bool _contextMenuSuppressed = false;

/// Suppresses the browser's own native right-click context menu over
/// MapLibre's canvas — call once (idempotent). Needed for the desktop
/// designer's right-click-to-insert-anchor gesture: without this, every
/// right-click would also pop up the browser's menu on top of it, same
/// class of problem [setMapDragLocked] already works around (Flutter has
/// no way to reach into this real DOM element's native event handling).
/// Scoped to just the map canvas via `closest` so it never affects a
/// right-click anywhere else on the page.
void suppressMapContextMenu() {
  if (_contextMenuSuppressed) return;
  _contextMenuSuppressed = true;
  web.document.addEventListener(
    'contextmenu',
    (web.MouseEvent e) {
      final target = e.target;
      if (target.isA<web.Element>() &&
          (target as web.Element).closest('.maplibregl-canvas') != null) {
        e.preventDefault();
      }
    }.toJS,
  );
}
