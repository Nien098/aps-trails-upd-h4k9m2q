import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'path_retrace.dart';

/// Renders a trail route as a GeoJSON line plus directional arrows that point
/// in the travel direction (start → end). Used by both the author and guide
/// maps. Interaction is disabled so map taps pass through to cue placement.
/// The line colour is data-driven (read from the feature) so it can be changed
/// by simply re-setting the route.
///
/// An out-and-back stretch (see [findExcursions]) draws differently from the
/// rest of the route: the return leg gets its own slightly-offset, dashed
/// line with no arrows, instead of overlapping the outbound leg with
/// direction chevrons pointing both ways on the same line — confirmed
/// confusing to read on screen. The outbound leg and every non-retraced
/// stretch keep today's solid-line-plus-arrows look unchanged.
class RouteLayer {
  /// [id] distinguishes multiple RouteLayers drawn on the same map at once
  /// (e.g. the original trail plus a computed escape route) — each needs
  /// its own source/layer ids or the second instance's `ensure()` would
  /// collide with the first's.
  ///
  /// [splitOutAndBack] runs excursion detection on every [setRoute] call —
  /// worth it for a trail's real, final route, but `author_screen.dart`'s
  /// live drag-trace preview calls `setRoute` on every gesture update with a
  /// still-growing, not-yet-committed stroke; false there skips the
  /// per-update detection cost for geometry that's about to be replaced
  /// anyway.
  RouteLayer(this.controller, {String id = 'route', this.splitOutAndBack = true})
      : _sourceId = id,
        _lineLayerId = '$id-line',
        _returnLineLayerId = '$id-line-return',
        _arrowLayerId = '$id-arrows',
        _arrowImage = '$id-arrow';

  final MapLibreMapController controller;
  final bool splitOutAndBack;

  final String _sourceId;
  final String _lineLayerId;
  final String _returnLineLayerId;
  final String _arrowLayerId;
  final String _arrowImage;

  bool _ready = false;
  String? _belowId;

  /// Base icon size before [setArrowScale]'s multiplier — was 0.5, bumped to
  /// 1.3 for legibility (see below); kept as its own constant so
  /// [setArrowScale] always means "relative to what this app already ships
  /// with", independent of whatever that base happens to be.
  static const _baseArrowSize = 1.3;
  double _arrowScale = 1.0;
  bool _arrowVisible = true;

  static const _empty = {
    'type': 'FeatureCollection',
    'features': <dynamic>[],
  };

  /// Any feature without this property (every non-excursion stretch, and an
  /// excursion's outbound leg) renders on the main line/arrow layers exactly
  /// as before; `'return'` renders on the dashed, offset, arrow-free layer.
  static const _legProp = 'leg';

  /// Adds the arrow image, source and layers. Call once after the style
  /// loads. [arrowScale] is the initial multiplier on [_baseArrowSize], and
  /// [arrowVisible] the initial on/off state — see [setArrowScale]/
  /// [setArrowVisible] to change either later on an already-`ensure()`d
  /// layer.
  Future<void> ensure({double arrowScale = 1.0, bool arrowVisible = true}) async {
    if (_ready) return;
    _arrowScale = arrowScale;
    _arrowVisible = arrowVisible;
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
    _belowId = symbolLayerIds.isEmpty ? null : symbolLayerIds.first;
    final belowId = _belowId;

    final notReturn = ['!=', ['get', _legProp], 'return'];

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
      filter: notReturn,
    );
    await controller.addLineLayer(
      _sourceId,
      _returnLineLayerId,
      const LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: 6.0,
        lineOpacity: 0.9,
        lineJoin: 'round',
        lineCap: 'round',
        lineOffset: -4.0,
        lineDasharray: [2, 2],
      ),
      enableInteraction: false,
      belowLayerId: belowId,
      filter: ['==', ['get', _legProp], 'return'],
    );
    await _addArrowLayer(notReturn);
    _ready = true;
  }

  Future<void> _addArrowLayer(List<Object> notReturn) => controller.addSymbolLayer(
        _sourceId,
        _arrowLayerId,
        SymbolLayerProperties(
          iconImage: _arrowImage,
          // Was 0.5 — nearly invisible to anyone with reduced vision, which
          // defeats the point of an app built around being easy to read for
          // older walkers. 1.3x (_baseArrowSize) renders it at a clearly
          // legible size; [_arrowScale] lets a walker size it up/down
          // further from Settings.
          iconSize: _baseArrowSize * _arrowScale,
          // Explicit on/off via opacity rather than overloading iconSize:0
          // to mean "hidden" — a real MapLibre icon layer at size 0 isn't
          // guaranteed to render as cleanly invisible (and still occupies
          // its collision/placement footprint) the way an opacity toggle
          // does. See Settings.chevronVisible.
          iconOpacity: _arrowVisible ? 1.0 : 0.0,
          symbolPlacement: 'line',
          // Wider spacing to match the bigger icon — otherwise adjacent
          // arrows crowd/overlap each other along tighter bends.
          symbolSpacing: 110.0,
          iconRotationAlignment: 'map',
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        enableInteraction: false,
        belowLayerId: _belowId,
        filter: notReturn,
      );

  /// Changes the arrow icon size live (a [Settings.chevronScale] multiplier
  /// on [_baseArrowSize]) by tearing down and re-adding just the arrow
  /// layer — mirrors [CueLayer]'s hard-won lesson that this plugin/native
  /// combination reliably applies a *new* symbol layer's properties but not
  /// always an in-place update to an existing one. No-op before [ensure].
  Future<void> setArrowScale(double scale) async {
    if (!_ready || scale == _arrowScale) return;
    _arrowScale = scale;
    await _rebuildArrowLayer();
  }

  /// Shows/hides the direction arrows entirely (see [Settings.chevronVisible]) —
  /// same teardown-and-rebuild approach as [setArrowScale].
  Future<void> setArrowVisible(bool visible) async {
    if (!_ready || visible == _arrowVisible) return;
    _arrowVisible = visible;
    await _rebuildArrowLayer();
  }

  Future<void> _rebuildArrowLayer() async {
    final notReturn = ['!=', ['get', _legProp], 'return'];
    await controller.removeLayer(_arrowLayerId);
    await _addArrowLayer(notReturn);
  }

  /// Updates the drawn route to [points] with line colour [colorHex]
  /// (cleared when fewer than 2 points). Any out-and-back stretch (see
  /// [findExcursions]) is split into an outbound feature (drawn on the main
  /// layers, unchanged) and a return feature (drawn on the dashed/offset/
  /// arrow-free layers) instead of one straight-through line.
  Future<void> setRoute(List<LatLng> points, String colorHex) async {
    if (!_ready) return;
    if (points.length < 2) {
      await controller.setGeoJsonSource(_sourceId, Map.of(_empty));
      return;
    }

    Map<String, dynamic> lineFeature(List<LatLng> pts, {String? leg}) => {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': pts.map((p) => [p.longitude, p.latitude]).toList(),
          },
          'properties': {'color': colorHex, _legProp: ?leg},
        };

    final excursions = splitOutAndBack ? findExcursions(points) : const <Excursion>[];
    final features = <Map<String, dynamic>>[];
    if (excursions.isEmpty) {
      features.add(lineFeature(points));
    } else {
      var cursor = 0;
      for (final e in excursions) {
        if (e.entryIndex > cursor) {
          features.add(lineFeature(points.sublist(cursor, e.entryIndex + 1)));
        }
        features.add(lineFeature(
            points.sublist(e.entryIndex, e.turnIndex + 1), leg: 'outbound'));
        features.add(lineFeature(
            points.sublist(e.turnIndex, e.exitIndex + 1), leg: 'return'));
        cursor = e.exitIndex;
      }
      if (cursor < points.length - 1) {
        features.add(lineFeature(points.sublist(cursor)));
      }
    }

    await controller.setGeoJsonSource(_sourceId, {
      'type': 'FeatureCollection',
      'features': features,
    });
  }
}
