import 'package:maplibre_gl/maplibre_gl.dart';

/// Renders trail cue markers (numbered circle + text label) via a GeoJSON
/// source backing several data-driven style layers — fully torn down and
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
/// every layer together has reliably shown correct text on-device.
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

  /// How many stacked lines under one merged marker get their own distinct
  /// vertical offset — comfortably more than any real-world junction is
  /// likely to merge (see [CueMarker.lineIndex]'s doc for why this many
  /// layers, one per line, is the fix rather than a single data-driven
  /// offset).
  static const _maxStackLines = 8;

  String _symbolLayerIdFor(int line) => '${_symbolLayerId}_$line';

  SymbolLayerProperties _symbolLayerPropertiesFor(int line) =>
      SymbolLayerProperties(
        textField: ['get', 'text'],
        textSize: 15,
        textColor: ['get', 'textColor'],
        textHaloColor: '#ffffff',
        textHaloWidth: 2,
        textAnchor: 'top',
        // A *fixed* offset (ems, not geographic) — MapLibre applies this in
        // screen space after projection, so it stays a constant number of
        // pixels regardless of zoom. This used to be the same [0, 1.2] for
        // every line, with per-line vertical separation done instead by
        // nudging each line's own point *geometry* a little further from
        // the real spot (real-world metres, converted from a per-pixel
        // budget at redraw time). That geographic approach is fundamentally
        // zoom-dependent — a fixed real-world distance necessarily looks
        // larger zoomed in and smaller zoomed out, confirmed live
        // (2026-08-22): stacked cue text squished together when zoomed out
        // and spread apart when zoomed in, no matter how the metre gap was
        // computed. The actual fix is this: every line of a stack now sits
        // at the *exact same* real position, and a *separate style layer
        // per line index* (see [_maxStackLines]/[CueMarker.lineIndex]) each
        // carries its own fixed, ever-larger ems offset, filtered to only
        // that line's features. `textOffset` can't be a *data-driven*
        // per-feature expression on this plugin/native-SDK combination (an
        // earlier attempt at that made the whole text layer silently
        // render nothing, no Dart-catchable exception, nothing in
        // logcat) — but a fixed offset per *layer* works fine, so one layer
        // per possible stack line sidesteps that limitation entirely while
        // staying genuinely zoom-independent.
        textOffset: [0, 1.2 + line * 1.2],
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
    for (var line = 0; line < _maxStackLines; line++) {
      await controller.addSymbolLayer(
        _sourceId,
        _symbolLayerIdFor(line),
        _symbolLayerPropertiesFor(line),
        filter: [
          '==',
          ['get', 'lineIndex'],
          line,
        ],
        enableInteraction: false,
        belowLayerId: _belowLayerId,
      );
    }
  }

  /// Replaces every marker. [markers] is a flat list of already-computed
  /// per-pin data — grouping/stacking/rank/colour logic all stays in the
  /// caller ([GuideScreen._drawCues]); this class only owns getting that
  /// data onto the map reliably.
  ///
  /// Every redraw fully tears down and recreates the source *and every
  /// layer* rather than updating them in place — on-device testing showed
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
              'lineIndex': m.lineIndex,
            },
          },
      ],
    };
    for (var line = 0; line < _maxStackLines; line++) {
      await controller.removeLayer(_symbolLayerIdFor(line));
    }
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
/// from the same data — see [CueLayer].
class CueMarker {
  const CueMarker({
    required this.position,
    required this.radius,
    required this.color,
    required this.strokeWidth,
    required this.text,
    required this.textColor,
    this.lineIndex = 0,
  });

  final LatLng position;
  final double radius;
  final String color;
  final double strokeWidth;
  final String text;
  final String textColor;

  /// Which stacked text line this marker is, within a group sharing one
  /// spot — 0 for a solo marker or a stack's primary (real-circle) line,
  /// 1/2/3/... for each additional line merged at the same point. Every
  /// line of a stack now uses the exact same [position] (no geographic
  /// nudging); [CueLayer] renders each `lineIndex` through its own style
  /// layer with a distinct, genuinely zoom-independent screen-space text
  /// offset instead. Capped at [CueLayer._maxStackLines] — a caller with
  /// more simultaneous lines than that (unrealistic in practice) would see
  /// the overflow lines render on top of the last supported offset rather
  /// than crash.
  final int lineIndex;
}
