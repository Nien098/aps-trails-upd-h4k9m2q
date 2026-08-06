import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

/// Renders a trail route as a GeoJSON line plus directional arrows that point
/// in the travel direction (start → end). Used by both the author and guide
/// maps. Interaction is disabled so map taps pass through to cue placement.
/// The line colour is data-driven (read from the feature) so it can be changed
/// by simply re-setting the route.
class RouteLayer {
  /// [id] distinguishes multiple RouteLayers drawn on the same map at once
  /// (e.g. the original trail plus a computed escape route) — each needs
  /// its own source/layer ids or the second instance's `ensure()` would
  /// collide with the first's.
  RouteLayer(this.controller, {String id = 'route'})
      : _sourceId = id,
        _lineLayerId = '$id-line',
        _arrowLayerId = '$id-arrows',
        _arrowImage = '$id-arrow';

  final MapLibreMapController controller;

  final String _sourceId;
  final String _lineLayerId;
  final String _arrowLayerId;
  final String _arrowImage;

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

    // The circle/symbol annotation managers (cue & anchor markers, their
    // number labels) are set up by the plugin before this style-loaded
    // callback runs, so their layers already exist. Without pinning our
    // layers below them here, addLineLayer/addSymbolLayer would default to
    // the top of the stack — burying every marker and label under the
    // route line and its direction arrows.
    final symbolLayerIds = controller.symbolManager?.layerIds ?? const [];
    final belowId = symbolLayerIds.isEmpty ? null : symbolLayerIds.first;

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
      belowLayerId: belowId,
    );
    await controller.addSymbolLayer(
      _sourceId,
      _arrowLayerId,
      SymbolLayerProperties(
        iconImage: _arrowImage,
        iconSize: 0.5,
        symbolPlacement: 'line',
        symbolSpacing: 70.0,
        iconRotationAlignment: 'map',
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      enableInteraction: false,
      belowLayerId: belowId,
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
