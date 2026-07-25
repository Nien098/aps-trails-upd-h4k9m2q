import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/region.dart';
import '../services/offline_map.dart';

/// Reusable offline MapLibre map. Loads the bundled Coquitlam pmtiles style
/// and forwards the common callbacks. Shared by the author and guide screens.
class BaseMap extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: OfflineMap.styleFor(region),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Map load error:\n${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return MapLibreMap(
          styleString: snap.data!,
          initialCameraPosition: initialCamera,
          minMaxZoomPreference: const MinMaxZoomPreference(10, 18),
          myLocationEnabled: myLocationEnabled,
          trackCameraPosition: trackCameraPosition,
          compassEnabled: true,
          compassViewPosition: CompassViewPosition.topLeft,
          compassViewMargins: const Point(12, 90),
          onMapCreated: onMapCreated,
          onStyleLoadedCallback: onStyleLoaded,
          onMapClick: onMapClick,
          onMapLongClick: onMapLongClick,
        );
      },
    );
  }
}
