import 'package:maplibre_gl/maplibre_gl.dart';

/// Renders trail cue markers (numbered circle + text label) via a GeoJSON
/// source backing two data-driven style layers — fully torn down and
/// rebuilt from scratch on every redraw (see [setMarkers]).
///
/// This replaces an earlier version that used the plugin's high-level
/// [MapLibreMapController.addCircles]/[addSymbols] annotation API — two
/// *independent* managers (circle, symbol), each doing its own clear-then-
/// re-add cycle. That two-manager design repeatedly proved able to go
/// visually out of sync with itself after a mid-walk redraw (e.g. a
/// marker's circle colour updating to the reversed type's colour while its
/// text label kept showing the old, un-reversed wording) — real, reproduced,
/// device-confirmed behaviour, not a hypothetical. A later version tried
/// folding both into one shared GeoJSON source updated via a single
/// `setGeoJsonSource` call (removing the two-manager race), then tried
/// additionally tearing down just the text layer on each redraw — neither
/// was enough: on-device testing kept showing the text stuck on whatever it
/// rendered the very first time, regardless of how the underlying data
/// changed afterwards, even while the circle layer's colour visibly updated
/// correctly on the very same redraw. Only fully recreating the source and
/// both layers together has reliably shown correct text on-device.
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
    await _create(Map.of(_empty));
    _ready = true;
  }

  Future<void> _create(Map<String, dynamic> geojson) async {
    await controller.addGeoJsonSource(_sourceId, geojson);
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
      belowLayerId: _belowLayerId,
    );
    await controller.addSymbolLayer(
      _sourceId,
      _symbolLayerId,
      _symbolLayerProperties,
      enableInteraction: false,
      belowLayerId: _belowLayerId,
    );
  }

  /// Replaces every marker. [markers] is a flat list of already-computed
  /// per-pin data — grouping/stacking/rank/colour logic all stays in the
  /// caller ([GuideScreen._drawCues]); this class only owns getting that
  /// data onto the map reliably.
  ///
  /// Every redraw fully tears down and recreates the source *and both
  /// layers* rather than updating them in place — on-device testing showed
  /// that in-place updates (`setGeoJsonSource` alone, and later even
  /// removing/re-adding just the text layer while leaving the source and
  /// circle layer in place) reliably leave the text stuck showing whatever
  /// it rendered on the very first draw, no matter how the underlying data
  /// changes afterwards; only a completely fresh source+layers has ever
  /// rendered correctly. That matches the one place in this app that has
  /// never shown this bug at all: reversing a trail from the main menu,
  /// which doesn't touch a live map layer's data — it starts an entirely
  /// new walk (a new GuideScreen, a new [ensure] call, i.e. a first draw)
  /// against already-reversed data. Tearing down and rebuilding here
  /// deliberately recreates that same "first draw" condition every time,
  /// instead of trying to coax an update out of a layer that has
  /// repeatedly proven unwilling to actually show one for its text.
  Future<void> setMarkers(List<CueMarker> markers) async {
    if (!_ready) return;
    final geojson = {
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
    };
    await controller.removeLayer(_symbolLayerId);
    await controller.removeLayer(_circleLayerId);
    await controller.removeSource(_sourceId);
    await _create(geojson);
  }

  Future<void> clear() async {
    if (!_ready) return;
    await setMarkers(const []);
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
