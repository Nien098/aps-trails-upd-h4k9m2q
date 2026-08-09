import 'package:maplibre_gl/maplibre_gl.dart';

/// Renders trail cue markers (numbered circle + text label) as a single
/// GeoJSON source backing two data-driven style layers, updated with ONE
/// atomic [setGeoJsonSource] call per redraw.
///
/// This replaces an earlier version that used the plugin's high-level
/// [MapLibreMapController.addCircles]/[addSymbols] annotation API — two
/// *independent* managers (circle, symbol), each doing its own clear-then-
/// re-add cycle. That two-manager design repeatedly proved able to go
/// visually out of sync with itself after a mid-walk redraw (e.g. a
/// marker's circle colour updating to the reversed type's colour while its
/// text label kept showing the old, un-reversed wording, or vice versa) —
/// real, reproduced, device-confirmed behaviour, not a hypothetical. Since
/// the circle and text always came from the exact same source Cue object in
/// the calling code, the two properties should never have been able to
/// diverge; the most plausible explanation left is that the plugin's own
/// glyph-shaping pass for text symbols is slower and more prone to being
/// superseded/dropped than a plain circle repaint (matching an even older,
/// already-documented case of this same "colours updated, text didn't"
/// symptom from earlier work on this screen), and that a text-only update
/// can occasionally lose that race against a near-simultaneous circle
/// update from the very same redraw. Folding both into one GeoJSON source
/// with two *data-driven* layers (reading `color`/`text`/etc. straight off
/// each feature's properties) removes the two-manager race entirely: there
/// is only one GeoJSON replace per redraw, so the circle and text layers
/// reading from it can never see different data.
class CueLayer {
  CueLayer(this.controller, {String id = 'cues'})
      : _sourceId = id,
        _circleLayerId = '${id}_circle',
        _symbolLayerId = '${id}_symbol';

  final MapLibreMapController controller;
  final String _sourceId;
  final String _circleLayerId;
  final String _symbolLayerId;

  bool _ready = false;
  String? _belowLayerId;

  static const _empty = {
    'type': 'FeatureCollection',
    'features': <dynamic>[],
  };

  SymbolLayerProperties get _symbolLayerProperties => SymbolLayerProperties(
        textField: ['get', 'text'],
        textSize: 15,
        textColor: ['get', 'textColor'],
        textHaloColor: '#ffffff',
        textHaloWidth: 2,
        textAnchor: 'top',
        // A *fixed* offset, deliberately not data-driven: an earlier version
        // read a per-feature array property here (['get', 'textOffset']) so
        // each line of a stacked marker could sit at a different height, but
        // that made the whole text layer fail to render anything at all —
        // text-offset apparently isn't supported as a data expression on
        // this plugin/native-SDK combination, and the failure is silent
        // (no Dart-catchable exception, nothing in logcat). Per-line spacing
        // is now done by nudging each line's own point geometry instead (see
        // [CueMarker.position] in [GuideScreen._drawCues]) — geometry is
        // definitely supported per-feature, sidestepping the whole question.
        textOffset: [0, 1.2],
        textAllowOverlap: true,
        textIgnorePlacement: true,
      );

  /// Adds the source and layers. Call once after the style loads.
  Future<void> ensure({String? belowLayerId}) async {
    if (_ready) return;
    _belowLayerId = belowLayerId;
    await controller.addGeoJsonSource(_sourceId, Map.of(_empty));
    await controller.addCircleLayer(
      _sourceId,
      _circleLayerId,
      CircleLayerProperties(
        circleRadius: ['get', 'radius'],
        circleColor: ['get', 'color'],
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: ['get', 'strokeWidth'],
      ),
      enableInteraction: false,
      belowLayerId: belowLayerId,
    );
    await controller.addSymbolLayer(
      _sourceId,
      _symbolLayerId,
      _symbolLayerProperties,
      enableInteraction: false,
      belowLayerId: belowLayerId,
    );
    _ready = true;
  }

  /// Replaces every marker. [markers] is a flat list of already-computed
  /// per-pin data — grouping/stacking/rank/colour logic all stays in the
  /// caller ([GuideScreen._drawCues]); this class only owns getting that
  /// data onto the map reliably.
  ///
  /// The circle layer is a plain data update (`setGeoJsonSource` alone is
  /// enough — paint-property repaints have been reliable here). The text
  /// layer is fully torn down and re-added every time instead: on-device
  /// testing showed a `setGeoJsonSource` update alone leaves stale glyphs on
  /// screen — new *circle* colours land correctly on the same redraw, but
  /// the *text* stays exactly as it was before the update, as if the label
  /// layer never re-shaped its glyphs for the new source data at all. Only
  /// removing and re-adding the layer itself (not just its data) reliably
  /// forces that re-shape. More expensive than a data-only update, but
  /// cue-marker redraws are infrequent (cue fired/skipped/reversed) and the
  /// marker count is small, so the extra cost is not a concern.
  Future<void> setMarkers(List<CueMarker> markers) async {
    if (!_ready) return;
    await controller.setGeoJsonSource(_sourceId, {
      'type': 'FeatureCollection',
      'features': [
        for (final m in markers)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [m.position.longitude, m.position.latitude],
            },
            'properties': {
              'radius': m.radius,
              'color': m.color,
              'strokeWidth': m.strokeWidth,
              'text': m.text,
              'textColor': m.textColor,
            },
          },
      ],
    });
    await controller.removeLayer(_symbolLayerId);
    await controller.addSymbolLayer(
      _sourceId,
      _symbolLayerId,
      _symbolLayerProperties,
      enableInteraction: false,
      belowLayerId: _belowLayerId,
    );
  }

  Future<void> clear() async {
    if (!_ready) return;
    await controller.setGeoJsonSource(_sourceId, Map.of(_empty));
  }
}

/// One rendered pin: a circle (colour/size) plus its text label, both driven
/// from the same data — see [CueLayer]. For a stacked group's 2nd+ line,
/// [position] should already be nudged slightly off the real cue position
/// (see [GuideScreen._drawCues]) so the lines don't fully overlap — the
/// *real* circle (radius > 0) always uses the true, un-nudged position.
class CueMarker {
  const CueMarker({
    required this.position,
    required this.radius,
    required this.color,
    required this.strokeWidth,
    required this.text,
    required this.textColor,
  });

  final LatLng position;
  final double radius;
  final String color;
  final double strokeWidth;
  final String text;
  final String textColor;
}
