import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/region.dart';
import '../services/offline_map.dart';

/// Reusable offline MapLibre map. Loads the bundled Coquitlam pmtiles style
/// and forwards the common callbacks. Shared by the author and guide screens.
///
/// Also supports keyboard pan (arrow keys) and zoom (+/-) as a fallback for
/// input paths where touch-drag doesn't translate reliably — e.g. some
/// remote-desktop tools (confirmed with Phone Link and Samsung Flow) inject
/// touch via Android's accessibility gesture API, which delivers sparse
/// synthetic move events that MapLibre's native pan-gesture recognizer often
/// doesn't pick up, even though a real finger (or the Android emulator's
/// proper virtual-touchscreen input) works fine. Keyboard events don't go
/// through that gesture recognizer at all, so they sidestep the problem.
class BaseMap extends StatefulWidget {
  const BaseMap({
    super.key,
    required this.region,
    required this.initialCamera,
    this.onMapCreated,
    this.onStyleLoaded,
    this.onMapClick,
    this.onMapLongClick,
    this.myLocationEnabled = false,
    this.trackCameraPosition = false,
  });

  final Region region;
  final CameraPosition initialCamera;
  final void Function(MapLibreMapController controller)? onMapCreated;
  final VoidCallback? onStyleLoaded;
  final OnMapClickCallback? onMapClick;
  final OnMapClickCallback? onMapLongClick;
  final bool myLocationEnabled;
  final bool trackCameraPosition;

  @override
  State<BaseMap> createState() => _BaseMapState();
}

class _BaseMapState extends State<BaseMap> {
  static const _panStepPx = 80.0;

  MapLibreMapController? _controller;

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    widget.onMapCreated?.call(controller);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final c = _controller;
    if (c == null) return KeyEventResult.ignored;

    final key = event.logicalKey;
    CameraUpdate? update;
    if (key == LogicalKeyboardKey.arrowUp) {
      update = CameraUpdate.scrollBy(0, -_panStepPx);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      update = CameraUpdate.scrollBy(0, _panStepPx);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      update = CameraUpdate.scrollBy(-_panStepPx, 0);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      update = CameraUpdate.scrollBy(_panStepPx, 0);
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
        return Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: MapLibreMap(
            styleString: snap.data!,
            initialCameraPosition: widget.initialCamera,
            minMaxZoomPreference: const MinMaxZoomPreference(10, 18),
            myLocationEnabled: widget.myLocationEnabled,
            trackCameraPosition: widget.trackCameraPosition,
            compassEnabled: true,
            compassViewPosition: CompassViewPosition.topLeft,
            compassViewMargins: const Point(12, 90),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: widget.onStyleLoaded,
            onMapClick: widget.onMapClick,
            onMapLongClick: widget.onMapLongClick,
          ),
        );
      },
    );
  }
}
