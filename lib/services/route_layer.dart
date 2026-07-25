import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

/// Renders a trail route as a GeoJSON line plus directional arrows that point
/// in the travel direction (start → end). Used by both the author and guide
/// maps. Interaction is disabled so map taps pass through to cue placement.
/// The line colour is data-driven (read from the feature) so it can be changed
/// by simply re-setting the route.
class RouteLayer {
  RouteLayer(this.controller);

  final MapLibreMapController controller;

  static const _sourceId = 'route';
  static const _lineLayerId = 'route-line';
  static const _arrowLayerId = 'route-arrows';
  static const _arrowImage = 'route-arrow';

  bool _ready = false;

  static const _empty = {
    'type': 'FeatureCollection',
    'features': <dynamic>[],
  };

  /// Adds the arrow image, source and layers. Call once after the style loads.
  Future<void> ensure() async {
    if (_ready) return;
    final bytes = await rootBundle.load('assets/img/arrow.png');
    await controller.addImage(_arrowImage,
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    await controller.addGeoJsonSource(_sourceId, Map.of(_empty));
    await controller.addLineLayer(
      _sourceId,
      _lineLayerId,
      const LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: 6.0,
        lineOpacity: 0.9,
        lineJoin: 'round',
        lineCap: 'round',
      ),
      enableInteraction: false,
    );
    await controller.addSymbolLayer(
      _sourceId,
      _arrowLayerId,
      const SymbolLayerProperties(
        iconImage: _arrowImage,
        iconSize: 0.5,
        symbolPlacement: 'line',
        symbolSpacing: 70.0,
        iconRotationAlignment: 'map',
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      enableInteraction: false,
    );
    _ready = true;
  }

  /// Updates the drawn route to [points] with line colour [colorHex]
  /// (cleared when fewer than 2 points).
  Future<void> setRoute(List<LatLng> points, String colorHex) async {
    if (!_ready) return;
    final coords = points.map((p) => [p.longitude, p.latitude]).toList();
    await controller.setGeoJsonSource(_sourceId, {
      'type': 'FeatureCollection',
      'features': [
        if (points.length >= 2)
          {
            'type': 'Feature',
            'geometry': {'type': 'LineString', 'coordinates': coords},
            'properties': {'color': colorHex},
          },
      ],
    });
  }
}
