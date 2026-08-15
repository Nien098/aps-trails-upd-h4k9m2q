import 'package:maplibre_gl/maplibre_gl.dart';

/// Draws a translucent freeform outline (with a dashed border) marking the
/// boundary area a user has drawn to constrain auto-generation (see
/// [author_screen.dart]'s draw-boundary mode and
/// [trail_router.dart]'s `TrailRouter.generate` `boundaryPolygon` param).
/// Structured the same way as [RouteLayer] (a single GeoJSON source,
/// live-updated via `setGeoJsonSource`) — see lib/services/route_layer.dart.
class BoundaryLayer {
  /// [lineColor]/[fillColor]/[fillOpacity]/[lineWidth]/[lineDasharray] let a
  /// second instance draw a differently-styled outline for a different
  /// purpose (see [BrowseMapScreen]'s downloaded-region boundary, a fainter
  /// no-fill outline reusing this same draw/clear machinery rather than
  /// duplicating it) without changing the generation-boundary tool's own
  /// look.
  BoundaryLayer(
    this.controller, {
    String id = 'gen-boundary',
    this.lineColor = '#3E8FB0',
    this.fillColor = '#3E8FB0',
    this.fillOpacity = 0.15,
    this.lineWidth = 2.5,
    this.lineDasharray = const [2, 2],
  })  : _sourceId = id,
        _fillLayerId = '$id-fill',
        _lineLayerId = '$id-line';

  final MapLibreMapController controller;
  final String _sourceId;
  final String _fillLayerId;
  final String _lineLayerId;
  final String lineColor;
  final String fillColor;
  final double fillOpacity;
  final double lineWidth;
  final List<double> lineDasharray;

  bool _ready = false;

  static const _empty = {
    'type': 'FeatureCollection',
    'features': <dynamic>[],
  };

  /// Adds the source and layers. Call once before the first [setPolygon].
  Future<void> ensure() async {
    if (_ready) return;
    await controller.addGeoJsonSource(_sourceId, Map.of(_empty));

    // Same reasoning as RouteLayer.ensure(): pin below the existing marker
    // layers so a box covering much of the screen doesn't bury anchor/cue
    // markers or route lines drawn on top of it.
    final symbolLayerIds = controller.symbolManager?.layerIds ?? const [];
    final belowId = symbolLayerIds.isEmpty ? null : symbolLayerIds.first;

    await controller.addFillLayer(
      _sourceId,
      _fillLayerId,
      FillLayerProperties(
        fillColor: fillColor,
        fillOpacity: fillOpacity,
      ),
      enableInteraction: false,
      belowLayerId: belowId,
    );
    await controller.addLineLayer(
      _sourceId,
      _lineLayerId,
      LineLayerProperties(
        lineColor: lineColor,
        lineWidth: lineWidth,
        lineDasharray: lineDasharray,
      ),
      enableInteraction: false,
      belowLayerId: belowId,
    );
    _ready = true;
  }

  /// Draws (or replaces) the outline for [points] — an arbitrary ring, not
  /// necessarily a rectangle; closed automatically if not already (first
  /// point repeated at the end). Clears when null or too short to form an
  /// area.
  Future<void> setPolygon(List<LatLng>? points) async {
    if (!_ready) return;
    if (points == null || points.length < 3) {
      await controller.setGeoJsonSource(_sourceId, Map.of(_empty));
      return;
    }
    final closed = points.first == points.last ? points : [...points, points.first];
    final ring = [for (final p in closed) [p.longitude, p.latitude]];
    await controller.setGeoJsonSource(_sourceId, {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [ring],
          },
          'properties': {},
        },
      ],
    });
  }
}
