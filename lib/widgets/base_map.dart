import 'dart:math' show Point;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/region.dart';
import '../services/offline_map.dart';
import '../services/settings.dart';

/// Reusable offline MapLibre map. Loads the bundled Coquitlam pmtiles style
/// and forwards the common callbacks. Shared by the author and guide screens.
///
/// Also supports keyboard pan (arrow keys), zoom (+/-), and rotate ([ / ]),
/// plus mouse-wheel zoom, as a fallback for input paths where touch-drag
/// doesn't translate reliably — e.g. some remote-desktop tools (confirmed
/// with Phone Link and Samsung Flow) inject touch via Android's
/// accessibility gesture API, which delivers sparse synthetic move events
/// that MapLibre's native pan-gesture recognizer often doesn't pick up, even
/// though a real finger (or the Android emulator's proper virtual-
/// touchscreen input) works fine. Keyboard events, and a real/forwarded
/// mouse's wheel and hover, don't go through that gesture recognizer at all,
/// so they sidestep the problem.
class BaseMap extends StatefulWidget {
  const BaseMap({
    super.key,
    required this.region,
    required this.initialCamera,
    this.onMapCreated,
    this.onStyleLoaded,
    this.onMapClick,
    this.onMapLongClick,
    this.onCameraIdle,
    this.myLocationEnabled = false,
    this.trackCameraPosition = false,
    this.gesturesEnabled = true,
    this.minZoom = 10,
  });

  final Region region;
  final CameraPosition initialCamera;
  final void Function(MapLibreMapController controller)? onMapCreated;
  final VoidCallback? onStyleLoaded;
  final OnMapClickCallback? onMapClick;
  final OnMapClickCallback? onMapLongClick;
  final VoidCallback? onCameraIdle;
  final bool myLocationEnabled;
  final bool trackCameraPosition;

  /// Lower bound for `minMaxZoomPreference`. Defaults to 10 (the floor
  /// below which downloaded regions have no tile data — see
  /// `kRegionMinZoom` in config.dart). Screens meant for panning long
  /// distances (BrowseMapScreen, AuthorScreen) pass a lower value so the
  /// user can zoom out further; below a region's real data floor the
  /// style's flat background fill shows instead of tiles, which is
  /// expected there, not a bug.
  final double minZoom;

  /// False disables the native one-finger pan/rotate camera gestures —
  /// used while a screen-space overlay gesture (e.g. dragging out a
  /// boundary box) needs sole ownership of drag input instead of fighting
  /// the map's own camera-drag recognizer for it.
  final bool gesturesEnabled;

  @override
  State<BaseMap> createState() => _BaseMapState();
}

class _BaseMapState extends State<BaseMap> {
  static const _panStepPx = 80.0;
  static const _rotateStepDeg = 15.0;

  MapLibreMapController? _controller;

  @override
  void initState() {
    super.initState();
    // Live-apply so a change made on the Settings screen (pushed on top of
    // an already-open map) takes effect the moment you come back to it,
    // without needing to fully leave and reopen the trail.
    Settings.instance.trailLineColor.addListener(_applyTrailLineStyle);
    Settings.instance.trailLineDashed.addListener(_applyTrailLineStyle);
  }

  @override
  void dispose() {
    Settings.instance.trailLineColor.removeListener(_applyTrailLineStyle);
    Settings.instance.trailLineDashed.removeListener(_applyTrailLineStyle);
    super.dispose();
  }

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    widget.onMapCreated?.call(controller);
  }

  /// Applies the user's chosen colour/dash setting to the background map's
  /// generic hiking-path layers — the "other trails in the area" clutter,
  /// not a trail you've authored (those draw their own per-trail colour on
  /// top, unaffected by this). Safe to call before the style has loaded
  /// (no-op) or repeatedly (idempotent).
  ///
  /// Three layers, not one: the current style (Protomaps' official basemap
  /// theme) splits path-like geometry into separate layers for normal/
  /// bridge/tunnel rendering rather than one combined layer the way this
  /// app's own earlier custom style did (that style named it plainly
  /// "trails" — a name specific to that style, not a stable id this app can
  /// rely on across basemap changes).
  static const _pathLayerIds = [
    'roads_other',
    'roads_bridges_other',
    'roads_tunnels_other',
  ];

  void _onStyleLoaded() {
    _applyTrailLineStyle();
    widget.onStyleLoaded?.call();
  }

  void _applyTrailLineStyle() {
    final c = _controller;
    if (c == null) return;
    final props = LineLayerProperties(
      lineColor: Settings.instance.trailLineColor.value,
      lineDasharray: Settings.instance.trailLineDashed.value ? [2, 1.5] : null,
    );
    for (final id in _pathLayerIds) {
      c.setLayerProperties(id, props);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final c = _controller;
    if (c == null) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // Rotate: '[' / ']', with Numpad 7 / 9 as alternates. Physical Numpad
    // 7/9 only send LogicalKeyboardKey.numpad7/9 when NumLock is ON — with
    // NumLock OFF, the OS translates those same physical keys to Home / Page
    // Up before the event ever reaches the app (NOT Home/End — it's Numpad
    // 1/3 that map to End/Page Down), so both forms are bound to cover
    // either NumLock state.
    if (key == LogicalKeyboardKey.bracketLeft ||
        key == LogicalKeyboardKey.numpad7 ||
        key == LogicalKeyboardKey.home) {
      _rotateBy(-_rotateStepDeg);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketRight ||
        key == LogicalKeyboardKey.numpad9 ||
        key == LogicalKeyboardKey.pageUp) {
      _rotateBy(_rotateStepDeg);
      return KeyEventResult.handled;
    }

    // scrollBy moves the camera TARGET, not the visible content — so to make
    // the arrow key match the direction content visually pans (not the
    // "drag" direction, which is the opposite), each axis is inverted from
    // what scrollBy's own dx/dy sign would naively suggest.
    CameraUpdate? update;
    if (key == LogicalKeyboardKey.arrowUp) {
      update = CameraUpdate.scrollBy(0, _panStepPx);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      update = CameraUpdate.scrollBy(0, -_panStepPx);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      update = CameraUpdate.scrollBy(_panStepPx, 0);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      update = CameraUpdate.scrollBy(-_panStepPx, 0);
    } else if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      update = CameraUpdate.zoomIn();
    } else if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      update = CameraUpdate.zoomOut();
    }
    if (update == null) return KeyEventResult.ignored;
    c.animateCamera(update);
    return KeyEventResult.handled;
  }

  /// Rotates the camera bearing by [deltaDeg] (positive = clockwise / turn
  /// right, matching ']'; negative = counter-clockwise / turn left, matching
  /// '[') relative to wherever it currently is. Queried fresh each time
  /// rather than tracked locally, since the on-screen compass / pinch-rotate
  /// gesture can also change the bearing independently of these keys.
  Future<void> _rotateBy(double deltaDeg) async {
    final c = _controller;
    if (c == null) return;
    final pos = await c.queryCameraPosition();
    final next = ((pos?.bearing ?? 0.0) + deltaDeg) % 360;
    await c.animateCamera(CameraUpdate.bearingTo(next));
  }

  /// Mouse-wheel zoom: standard scroll-to-zoom convention (Google Maps,
  /// browser maps, etc.) — scrolling up/away zooms in, down/toward zooms
  /// out, i.e. it mimics the '+' / '-' keys. A real or forwarded mouse's
  /// wheel arrives as a distinct pointer-signal input, separate from the
  /// touch-gesture path that click-drag panning struggles with over some
  /// remote-desktop tools, so this is expected to work reliably even there.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final c = _controller;
    if (c == null) return;
    c.animateCamera(event.scrollDelta.dy < 0
        ? CameraUpdate.zoomIn()
        : CameraUpdate.zoomOut());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: OfflineMap.styleFor(widget.region),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Map load error:\n${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Listener(
          onPointerSignal: _onPointerSignal,
          child: Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: MapLibreMap(
              styleString: snap.data!,
              initialCameraPosition: widget.initialCamera,
              minMaxZoomPreference: MinMaxZoomPreference(widget.minZoom, 18),
              myLocationEnabled: widget.myLocationEnabled,
              trackCameraPosition: widget.trackCameraPosition,
              compassEnabled: true,
              compassViewPosition: CompassViewPosition.topLeft,
              compassViewMargins: const Point(12, 90),
              onMapCreated: _onMapCreated,
              onStyleLoadedCallback: _onStyleLoaded,
              onMapClick: widget.onMapClick,
              onMapLongClick: widget.onMapLongClick,
              onCameraIdle: widget.onCameraIdle,
              scrollGesturesEnabled: widget.gesturesEnabled,
              rotateGesturesEnabled: widget.gesturesEnabled,
            ),
          ),
        );
      },
    );
  }
}
