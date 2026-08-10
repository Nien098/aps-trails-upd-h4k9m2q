import 'dart:async';
import 'dart:math' show Point, max, min, sqrt;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../cue_style.dart';
import '../models/region.dart';
import '../models/trail.dart';
import '../trail_colors.dart';
import '../services/boundary_layer.dart';
import '../services/cue_gen.dart';
import '../services/geo.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/trail_router.dart';
import '../services/trail_store.dart';
import '../widgets/base_map.dart';
import '../widgets/cue_editor_sheet.dart';
import 'cue_list_screen.dart';

/// Trail editor. Tap the map to lay the path (Path mode) or drop a labelled
/// direction cue (Cue mode). Tap an existing cue marker to edit or delete it.
class AuthorScreen extends StatefulWidget {
  const AuthorScreen({super.key, this.trail, this.region});

  /// Existing trail to edit, or null to start a new one.
  final Trail? trail;

  /// Region for a new trail (ignored when editing an existing trail).
  final Region? region;

  @override
  State<AuthorScreen> createState() => _AuthorScreenState();
}

class _AuthorScreenState extends State<AuthorScreen> {
  late Trail _trail;
  late Region _region;
  MapLibreMapController? _c;
  RouteLayer? _routeLayer;
  BoundaryLayer? _boundaryLayer;

  /// Separate layer just for the raw in-progress drag trace in
  /// [_dragDrawMode] — kept apart from [_routeLayer] (which always shows the
  /// trail's actual committed path) so a live preview never has to touch or
  /// restore that real data mid-drag.
  RouteLayer? _strokeLayer;

  /// While true, a drag on the map draws a generation-boundary outline
  /// instead of panning the camera or placing an anchor/cue — see
  /// [_onBoundaryPanStart]/[_onBoundaryPanEnd] and [BaseMap.gesturesEnabled].
  bool _drawBoundaryMode = false;

  /// Screen-space drag-in-progress trace (only non-empty while actively
  /// dragging) — the source of truth converted into the final [_genBoundary]
  /// once the drag ends. Points are recorded with a minimum spacing (see
  /// [_onBoundaryPanUpdate]) so a slow drag doesn't blow this list, and the
  /// eventual polygon, up unnecessarily.
  final List<Offset> _dragPoints = [];

  /// Best-effort geographic trace of the drag in progress, drawn live via
  /// [_boundaryLayer] so what's on screen while dragging matches exactly
  /// what the final result will look like (same layer, same styling) —
  /// a Flutter-side CustomPaint overlay was tried first but didn't reliably
  /// render on top of the map's native platform view, so the live preview
  /// goes through the map's own rendering instead. Necessarily lower-
  /// fidelity than [_dragPoints] (see [_pushDragPreview]'s self-throttling),
  /// since it costs a platform-channel round trip per point instead of zero.
  final List<LatLng> _dragPreview = [];
  bool _convertingDragPoint = false;

  /// While true, a drag on the map draws a trail stroke by nudging each
  /// sampled point onto the nearest trail/road, instead of tap-to-tap
  /// routing — see [_onStrokePanEnd]/[TrailRouter.snapPoint]. Mirrors what
  /// record mode's post-recording cleanup does (nudge, never guess-route),
  /// for authors who'd rather trace a trail by hand than tap point-to-point.
  bool _dragDrawMode = false;

  /// Screen-space drag-in-progress trace for [_dragDrawMode] — same
  /// min-spacing/cap approach as [_dragPoints], kept separate since the two
  /// drag modes are mutually exclusive but shouldn't share bookkeeping.
  final List<Offset> _strokePoints = [];
  bool _committingStroke = false;

  /// Geographic trace of the drag in progress, pushed live to [_strokeLayer]
  /// so the raw, unsnapped path is visible as it's drawn (unlike the final
  /// result, this is never snapped — that only happens once on release, see
  /// [_onStrokePanEnd]). Same self-throttling approach as [_dragPreview].
  final List<LatLng> _strokePreview = [];
  bool _convertingStrokePoint = false;

  static const _strokePreviewColor = '#FF6D00';

  /// Real-anchor spacing along a committed drag-draw stroke — see the
  /// commit logic in [_onStrokePanEnd] for why this exists.
  static const _strokeAnchorIntervalMeters = 25.0;

  /// Bumped on every toggle, mode switch, and grab-start affecting either
  /// drag mode's preview layer. [_pushStrokePreview]/[_pushAdjustPreview]
  /// capture it before their async lat/lng conversion and re-check it
  /// after — if it changed while the conversion was in flight (a new grab
  /// started, the tool was toggled off, or the mode switched to Add cue),
  /// that stale result is dropped instead of being pushed to the map, where
  /// it would otherwise render a leftover line from a drag that's no longer
  /// current — real geometry, but disconnected from what's on screen now.
  int _previewGeneration = 0;

  /// While true, a drag on the map grabs the nearest interior point of the
  /// drawn line and pulls it, re-aligning the surrounding stretch onto the
  /// mapped trail as it goes — see [_onAdjustPanEnd]/[TrailRouter.rippleRealign].
  bool _adjustLineMode = false;

  /// Which segment/local-index of [_segments] is currently grabbed, or null
  /// when nothing's being dragged — see [_nearestSegmentVertex]. Never an
  /// anchor (index 0 or a segment's last index): those already have their
  /// own long-press-to-move interaction.
  int? _grabSegIdx;
  int? _grabLocalIdx;

  /// Local index bounds (inclusive) of the live-preview window around
  /// [_grabLocalIdx] — see [_previewWindow]. Purely cosmetic (computed once
  /// at grab time from the un-edited segment); the real, trail-aware ripple
  /// boundary is decided by [TrailRouter.rippleRealign] on release, this
  /// just keeps the preview from implying an edit scope far larger than
  /// what a release could actually change.
  int? _grabWindowLo;
  int? _grabWindowHi;
  Offset? _lastAdjustOffset;
  bool _convertingAdjustPoint = false;
  bool _adjustingLine = false;

  /// The drawn boundary outline (closed ring) constraining auto-generation,
  /// or null to fall back to whatever's currently on screen (existing
  /// behaviour).
  List<LatLng>? _genBoundary;

  bool _cueMode = false;
  bool _dirty = false;
  bool _follow = true; // auto-follow trail lines between anchors
  bool _busy = false; // a routing query is in flight

  /// Whether the mode-bar card shows its full controls (Follow-trails/Free-
  /// placement switch + hint text) or just the essentials (Draw/Cue toggle +
  /// trail length). Starts expanded (unchanged default); collapsing is an
  /// explicit choice for when the full card gets in the way while actively
  /// tapping out a path.
  bool _modeBarExpanded = true;

  /// When true, the mode-bar card is hidden entirely — replaced by a small
  /// corner icon (like the map's other small FABs) — for when even the
  /// collapsed card is still in the way and the map needs the full screen.
  /// Reopening restores whatever [_modeBarExpanded] state it was in before.
  bool _modeBarHidden = false;

  /// The cue awaiting a new position (long-pressed in Cue mode), or null.
  Cue? _moving;
  /// When true, the next tap places [_moving] exactly where tapped; when
  /// false (default), it snaps onto the nearest point of the drawn path.
  bool _freeMove = false;

  /// Briefly highlighted after being located from the cue list, so it's
  /// obvious which marker the map just centred on.
  Cue? _highlighted;
  Timer? _highlightTimer;

  /// Index into [_trail]'s anchors awaiting a new position (chosen via the
  /// long-press action sheet), or null.
  int? _movingAnchor;

  /// Route segments parallel to [_trail.anchors]: segment i connects anchor
  /// i-1 → i (segment 0 is just [anchor0]). Undo drops the last of each.
  final List<List<LatLng>> _segments = [];

  // Map drawn markers back to their data for tap-to-edit / tap-to-delete.
  final Map<String, Cue> _symbolToCue = {};
  final Map<String, Cue> _circleToCue = {};
  // Circles drawn for a stacked-cue spot (2+ cues within a metre of each
  // other) map here instead of [_circleToCue] — tapping one opens a picker
  // rather than assuming which cue in the stack was meant.
  final Map<String, List<Cue>> _circleToCueGroup = {};
  final Map<String, List<Cue>> _symbolToCueGroup = {};
  final Map<String, int> _circleToAnchor = {};

  @override
  void initState() {
    super.initState();
    if (widget.trail != null) {
      _trail = widget.trail!;
      _region = regionById(_trail.regionId);
    } else {
      _region = widget.region ?? kDefaultRegion;
      _trail = Trail(name: 'New trail', regionId: _region.id);
    }
    _segments.addAll(_rebuildSegments(_trail.path, _trail.anchors));
  }

  /// Splits an existing route [path] back into per-anchor segments so an edited
  /// trail keeps its geometry and undo works. Legacy trails (no anchors) treat
  /// every path point as a straight-line anchor.
  List<List<LatLng>> _rebuildSegments(List<LatLng> path, List<LatLng> anchors) {
    if (path.isEmpty) return [];
    final marks = anchors.isNotEmpty ? anchors : path;
    _trail.anchors = List.of(marks);
    final segs = <List<LatLng>>[[marks.first]];
    var cursor = 0;
    for (var i = 1; i < marks.length; i++) {
      var idx = -1;
      for (var j = cursor + 1; j < path.length; j++) {
        if (metersBetween(path[j], marks[i]) < 1.0) {
          idx = j;
          break;
        }
      }
      if (idx < 0) idx = path.length - 1;
      segs.add(path.sublist(cursor, idx + 1));
      cursor = idx;
    }
    return segs;
  }

  void _onMapCreated(MapLibreMapController c) {
    _c = c;
    c.onSymbolTapped.add(_onCueTapped);
    c.onCircleTapped.add(_onCircleTapped);
  }

  /// A tap on a drawn circle. Behaviour depends on the current mode:
  /// - While a cue move is pending ([_moving]), a tap on an anchor dot places
  ///   it there exactly; a tap on any cue circle is ignored (ambiguous —
  ///   tap empty map or Cancel instead).
  /// - Cue circle in Draw-path mode → link that cue into the trail (connect
  ///   the dots), routing to its exact position.
  /// - Cue circle in Add-cue mode → edit / delete the cue.
  /// - Anchor circle in Draw-path mode → continue/return the trail *through*
  ///   that existing point (so a loop can retrace its own line). Long-press an
  ///   anchor to delete it instead.
  Future<void> _onCircleTapped(Circle circle) async {
    if (_moving != null) {
      // A tap that lands exactly on an anchor dot places the moving cue
      // there precisely, bypassing the fuzzy snap-to-nearest-path-point that
      // a generic map click falls back to — that fallback often couldn't
      // land exactly on a node even when the tap visually looked spot-on.
      // Cue-circle taps stay ignored during a move to avoid the ambiguity of
      // "is this an edit or a move?" — tap empty map or Cancel instead.
      final idx = _circleToAnchor[circle.id];
      if (idx != null) {
        final moving = _moving!;
        setState(() {
          moving.position = _trail.anchors[idx];
          _moving = null;
          _dirty = true;
        });
        await _redraw();
      }
      return;
    }
    if (_movingAnchor != null) {
      // Same precise-placement logic as the cue-move case above, for moving
      // an anchor exactly onto another existing anchor's position.
      final idx = _circleToAnchor[circle.id];
      if (idx != null) await _placeMovingAnchor(_trail.anchors[idx]);
      return;
    }
    final group = _circleToCueGroup[circle.id];
    if (group != null) {
      if (_cueMode) {
        await _cueGroupSheet(group);
      } else {
        await _addAnchor(group.first.position, snap: false);
      }
      return;
    }
    final cue = _circleToCue[circle.id];
    if (cue != null) {
      if (_cueMode) {
        await _editCue(cue);
      } else {
        await _addAnchor(cue.position, snap: false);
      }
      return;
    }
    final idx = _circleToAnchor[circle.id];
    if (idx == null) return;
    if (_cueMode) {
      // Drop a cue right on this path point (tapping the line worked already;
      // this covers landing exactly on a node).
      await _addCueAt(_trail.anchors[idx]);
      return;
    }
    // Tapping the current drawing point is a no-op; otherwise route through it.
    if (idx == _trail.anchors.length - 1) return;
    await _addAnchor(_trail.anchors[idx], snap: false);
  }

  /// Long-press on the map. In Cue mode, long-pressing a cue starts moving it
  /// (tap the map to drop it at the new spot, or Cancel). In Draw mode,
  /// long-pressing an anchor opens a Move/Delete choice; long-pressing the
  /// drawn *line* somewhere between two anchors (not on either of them)
  /// inserts a new anchor there instead, splitting that hop into two.
  Future<void> _onMapLongClick(Point<double> screen, LatLng latlng) async {
    final c = _c;
    if (c == null) return;

    if (_cueMode) {
      final cues = _trail.cues;
      var best = -1;
      var bestPx = 34.0;
      for (var i = 0; i < cues.length; i++) {
        final p = await c.toScreenLocation(cues[i].position);
        final dx = p.x.toDouble() - screen.x;
        final dy = p.y.toDouble() - screen.y;
        final px = sqrt(dx * dx + dy * dy);
        if (px < bestPx) {
          bestPx = px;
          best = i;
        }
      }
      if (best >= 0) {
        setState(() => _moving = cues[best]);
        await _redraw();
      }
      return;
    }

    final anchors = _trail.anchors;
    if (anchors.isEmpty) return;
    var best = -1;
    var bestPx = 34.0; // tap tolerance in logical pixels
    for (var i = 0; i < anchors.length; i++) {
      final p = await c.toScreenLocation(anchors[i]);
      final dx = p.x.toDouble() - screen.x;
      final dy = p.y.toDouble() - screen.y;
      final px = sqrt(dx * dx + dy * dy);
      if (px < bestPx) {
        bestPx = px;
        best = i;
      }
    }
    if (best >= 0) {
      await _anchorActionSheet(best);
    } else {
      await _insertAnchorNear(latlng);
    }
  }

  Future<void> _onStyleLoaded() async {
    _routeLayer = RouteLayer(_c!);
    await _routeLayer!.ensure();
    _boundaryLayer = BoundaryLayer(_c!);
    await _boundaryLayer!.ensure();
    _strokeLayer = RouteLayer(_c!, id: 'strokePreview');
    await _strokeLayer!.ensure();
    await _redraw();
  }

  /// Minimum spacing (logical px) between recorded drag points — keeps a
  /// slow/jittery drag from ballooning the point count, and caps how big
  /// the resulting polygon (and its point-in-polygon test) can get.
  static const _dragPointSpacing = 6.0;
  static const _dragPointCap = 150;

  Future<void> _toggleDrawBoundary() async {
    setState(() {
      _drawBoundaryMode = !_drawBoundaryMode;
      _dragPoints.clear();
      _dragPreview.clear();
    });
    // Cancelling mid-drag (or toggling the mode off) can leave the last
    // pushed live-preview shape on the map — restore whatever boundary was
    // actually confirmed before (or clear it if there wasn't one).
    await _boundaryLayer?.setPolygon(_genBoundary);
  }

  void _onBoundaryPanStart(DragStartDetails d) {
    setState(() {
      _dragPoints
        ..clear()
        ..add(d.localPosition);
      _dragPreview.clear();
    });
  }

  void _onBoundaryPanUpdate(DragUpdateDetails d) {
    if (_dragPoints.isNotEmpty &&
        (_dragPoints.length >= _dragPointCap ||
            (d.localPosition - _dragPoints.last).distance < _dragPointSpacing)) {
      return;
    }
    setState(() => _dragPoints.add(d.localPosition));
    _pushDragPreview(d.localPosition);
  }

  /// Best-effort live preview via the map's own rendering (see
  /// [_dragPreview]'s doc). Self-throttles by skipping a new conversion
  /// while one's still in flight rather than queueing — each pan-update
  /// naturally supplies a fresher point than any queued one would anyway,
  /// so this settles at whatever rate the platform channel can sustain
  /// instead of building a backlog.
  Future<void> _pushDragPreview(Offset p) async {
    final c = _c;
    if (c == null || _convertingDragPoint || !mounted) return;
    _convertingDragPoint = true;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final latlng = await c.toLatLng(Point(p.dx * dpr, p.dy * dpr));
      if (!mounted || !_drawBoundaryMode) return;
      _dragPreview.add(latlng);
      if (_dragPreview.length >= 3) {
        await _boundaryLayer?.setPolygon(_dragPreview);
      }
    } finally {
      _convertingDragPoint = false;
    }
  }

  Future<void> _onBoundaryPanEnd(DragEndDetails _) async {
    final c = _c;
    final points = List<Offset>.of(_dragPoints);
    setState(() {
      _dragPoints.clear();
      _dragPreview.clear();
    });
    // A negligible/near-straight-line drag (an accidental tap or flick
    // while in this mode) isn't a deliberate outline — ignore it rather
    // than setting a degenerate boundary that would empty the graph out
    // entirely.
    if (c == null || points.length < 3) {
      await _boundaryLayer?.setPolygon(_genBoundary);
      return;
    }
    final minX = points.map((p) => p.dx).reduce(min);
    final maxX = points.map((p) => p.dx).reduce(max);
    final minY = points.map((p) => p.dy).reduce(min);
    final maxY = points.map((p) => p.dy).reduce(max);
    if (maxX - minX < 20 && maxY - minY < 20) {
      await _boundaryLayer?.setPolygon(_genBoundary);
      return;
    }

    // GestureDetector reports Flutter's logical/dp pixels, but toLatLng —
    // like queryRenderedFeaturesInRect and toScreenLocation elsewhere in
    // this codebase — expects the MapView's native device pixels. Scaling
    // by devicePixelRatio is the exact, documented conversion between the
    // two (this is what produced a boundary shrunk toward the top-left on
    // a real device: the raw logical coordinates were being read as if
    // they were already native pixels).
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final boundary = await Future.wait(
        points.map((p) => c.toLatLng(Point(p.dx * dpr, p.dy * dpr))));
    if (!mounted) return;
    setState(() {
      _genBoundary = boundary;
      _drawBoundaryMode = false;
    });
    await _boundaryLayer?.setPolygon(boundary);
  }

  Future<void> _clearBoundary() async {
    setState(() => _genBoundary = null);
    await _boundaryLayer?.setPolygon(null);
  }

  Future<void> _toggleDragDraw() async {
    setState(() {
      _previewGeneration++;
      _dragDrawMode = !_dragDrawMode;
      _strokePoints.clear();
      _strokePreview.clear();
      if (_dragDrawMode) {
        _adjustLineMode = false;
        _grabSegIdx = null;
        _grabLocalIdx = null;
        _grabWindowLo = null;
        _grabWindowHi = null;
      }
    });
    await _strokeLayer?.setRoute(const [], _strokePreviewColor);
  }

  void _onStrokePanStart(DragStartDetails d) {
    setState(() {
      _previewGeneration++;
      _strokePoints
        ..clear()
        ..add(d.localPosition);
      _strokePreview.clear();
    });
  }

  void _onStrokePanUpdate(DragUpdateDetails d) {
    if (_strokePoints.isNotEmpty &&
        (_strokePoints.length >= _dragPointCap ||
            (d.localPosition - _strokePoints.last).distance < _dragPointSpacing)) {
      return;
    }
    setState(() => _strokePoints.add(d.localPosition));
    _pushStrokePreview(d.localPosition);
  }

  /// Best-effort live preview of the raw (unsnapped) drag, drawn via
  /// [_strokeLayer] so a finger/pointer drag is actually visible while it's
  /// happening — self-throttles like [_pushDragPreview] rather than queueing.
  Future<void> _pushStrokePreview(Offset p) async {
    final c = _c;
    if (c == null || _convertingStrokePoint || !mounted) return;
    final gen = _previewGeneration;
    _convertingStrokePoint = true;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final latlng = await c.toLatLng(Point(p.dx * dpr, p.dy * dpr));
      if (!mounted || !_dragDrawMode || gen != _previewGeneration) return;
      _strokePreview.add(latlng);
      if (_strokePreview.length >= 2) {
        await _strokeLayer?.setRoute(_strokePreview, _strokePreviewColor);
      }
    } finally {
      _convertingStrokePoint = false;
    }
  }

  /// Converts the finished drag into map points, then nudges each one onto
  /// the nearest trail/road within range — the same per-point local snap
  /// [record_trail_screen._cleanPath] uses, and for the same reason: routing
  /// between points (what "Follow trails" tap mode does via
  /// [TrailRouter.connect]) can send a whole stretch off toward an unrelated
  /// nearby trail when there's a gap; a local nudge can only pull a point a
  /// short bounded distance, so the drawn shape is always preserved.
  Future<void> _onStrokePanEnd(DragEndDetails _) async {
    final c = _c;
    final points = List<Offset>.of(_strokePoints);
    setState(() {
      _previewGeneration++;
      _strokePoints.clear();
      _strokePreview.clear();
    });
    unawaited(_strokeLayer?.setRoute(const [], _strokePreviewColor));
    if (c == null || points.length < 2 || _committingStroke) return;
    final minX = points.map((p) => p.dx).reduce(min);
    final maxX = points.map((p) => p.dx).reduce(max);
    final minY = points.map((p) => p.dy).reduce(min);
    final maxY = points.map((p) => p.dy).reduce(max);
    // A negligible drag (an accidental tap/flick in this mode) isn't a
    // deliberate stroke — ignore it rather than adding a near-zero-length
    // segment.
    if (maxX - minX < 12 && maxY - minY < 12) return;

    setState(() => _committingStroke = true);
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final raw = await Future.wait(
          points.map((p) => c.toLatLng(Point(p.dx * dpr, p.dy * dpr))));
      // A much tighter tolerance than record mode's cleanup (8m, sized to
      // remove real GPS jitter) — these points come from a precise on-screen
      // drag, not noisy GPS, so there's no jitter to remove. Collapsing the
      // stroke down to only a few widely-spaced anchors was the actual cause
      // of the drawn line jumping far from the real drag: each anchor snaps
      // independently, so if two survive far apart they can nudge onto two
      // different nearby trail fragments, turning the straight line between
      // them into a chord that cuts across whatever's between those trails.
      // Keeping far more points close together means neighbouring snaps
      // consistently land on the same real trail instead.
      final simplified = simplifyPath(raw, 2.5);
      if (simplified.length < 2) return;
      // snapStroke (not a per-point snapPoint loop) so the whole stroke is
      // queried as one consistent graph and consecutive points stay on the
      // same trail edge unless a different one is meaningfully closer — see
      // its doc for why an independent per-point search could zig-zag right
      // where two trails cross or run close together.
      final rawSnapped =
          await TrailRouter(c).snapStroke(simplified, maxMeters: 50);
      final snapped = <LatLng>[];
      for (final s in rawSnapped) {
        if (snapped.isEmpty || metersBetween(snapped.last, s) >= 3) {
          snapped.add(s);
        }
      }
      if (snapped.length < 2 || !mounted) return;
      setState(() {
        if (_trail.anchors.isEmpty) {
          _trail.anchors.add(snapped.first);
          _segments.add([snapped.first]);
        } else if (metersBetween(_trail.anchors.last, snapped.first) > 3) {
          _trail.anchors.add(snapped.first);
          _segments.add([_trail.anchors[_trail.anchors.length - 2], snapped.first]);
        }
        // Real anchors every ~_strokeAnchorIntervalMeters along the stroke,
        // not just at its start/end — a whole drag committed as one giant
        // segment (the previous behaviour) left the line-adjust tool with
        // only two real anchors on a long stroke, so it had to invent an
        // artificial bound (a fixed ripple-step cap) to keep a grab from
        // running the segment's entire length. Real, evenly-spaced anchors
        // give every stretch a genuine, already-existing boundary at roughly
        // the same scale a ripple would reach anyway, so an edit is bounded
        // by real trail structure instead of an arbitrary cap — while still
        // leaving several interior (non-anchor) points between consecutive
        // anchors for the grab tool to operate on.
        var last = _trail.anchors.last;
        var sinceAnchor = <LatLng>[last];
        for (var i = 1; i < snapped.length; i++) {
          sinceAnchor.add(snapped[i]);
          final isLast = i == snapped.length - 1;
          if (isLast || pathLength(sinceAnchor) >= _strokeAnchorIntervalMeters) {
            _trail.anchors.add(snapped[i]);
            _segments.add(sinceAnchor);
            last = snapped[i];
            sinceAnchor = [last];
          }
        }
        _trail.path = _composePath();
        _dirty = true;
      });
      await _redraw();
    } finally {
      if (mounted) setState(() => _committingStroke = false);
    }
  }

  Future<void> _toggleAdjustLine() async {
    setState(() {
      _previewGeneration++;
      _adjustLineMode = !_adjustLineMode;
      _grabSegIdx = null;
      _grabLocalIdx = null;
      _grabWindowLo = null;
      _grabWindowHi = null;
      _lastAdjustOffset = null;
      if (_adjustLineMode) {
        _dragDrawMode = false;
        _strokePoints.clear();
      }
    });
    await _strokeLayer?.setRoute(const [], _strokePreviewColor);
  }

  /// Finds the (segment index, local index) of the interior vertex in
  /// [_segments] closest to [p] — "grab the line" for [_adjustLineMode].
  /// Deliberately excludes each segment's first/last point (its anchors):
  /// those already have their own long-press-to-move interaction, and
  /// moving one would also have to stay in sync with the neighbouring
  /// segment that shares it, which this simpler per-segment tool doesn't
  /// attempt.
  (int, int)? _nearestSegmentVertex(LatLng p, {double maxMeters = 15}) {
    int? bestSeg, bestIdx;
    var bestDist = maxMeters;
    for (var s = 0; s < _segments.length; s++) {
      final seg = _segments[s];
      for (var i = 1; i < seg.length - 1; i++) {
        final d = metersBetween(p, seg[i]);
        if (d < bestDist) {
          bestDist = d;
          bestSeg = s;
          bestIdx = i;
        }
      }
    }
    if (bestSeg == null || bestIdx == null) return null;
    return (bestSeg, bestIdx);
  }

  /// Local index bounds around [grabIndex] within [seg], out to
  /// [TrailRouter.rippleMaxSteps] points in each direction — matches
  /// [TrailRouter.rippleRealign]'s own cap exactly (an index-count limit,
  /// not a distance one — see that method's doc for why a per-point-count
  /// bound is safer than a cumulative-metres one) so what's previewed here
  /// can never show a stretch larger than what a release could touch.
  (int, int) _previewWindow(List<LatLng> seg, int grabIndex) {
    final hi = (grabIndex + TrailRouter.rippleMaxSteps).clamp(0, seg.length - 1);
    final lo = (grabIndex - TrailRouter.rippleMaxSteps).clamp(0, seg.length - 1);
    return (lo, hi);
  }

  Future<void> _onAdjustPanStart(DragStartDetails d) async {
    final c = _c;
    if (c == null) return;
    final gen = ++_previewGeneration;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final latlng = await c
        .toLatLng(Point(d.localPosition.dx * dpr, d.localPosition.dy * dpr));
    if (!mounted || !_adjustLineMode || gen != _previewGeneration) return;
    final hit = _nearestSegmentVertex(latlng);
    final window =
        hit == null ? null : _previewWindow(_segments[hit.$1], hit.$2);
    setState(() {
      _grabSegIdx = hit?.$1;
      _grabLocalIdx = hit?.$2;
      _grabWindowLo = window?.$1;
      _grabWindowHi = window?.$2;
    });
  }

  void _onAdjustPanUpdate(DragUpdateDetails d) {
    _lastAdjustOffset = d.localPosition;
    _pushAdjustPreview(d.localPosition);
  }

  /// Live "string pull" preview: redraws only the bounded window around the
  /// grabbed vertex (see [_previewWindow]) with that vertex moved to the
  /// current drag position — not the whole segment, so dragging a small
  /// local kink on a long, sparsely-anchored segment (e.g. a whole
  /// auto-generated loop) doesn't visually imply the entire loop is up for
  /// editing. The rest of the trail (still shown by [_routeLayer]) doesn't
  /// change until release, when [TrailRouter.rippleRealign] recalculates
  /// the corrected shape within that same real bound.
  Future<void> _pushAdjustPreview(Offset p) async {
    final c = _c;
    final segIdx = _grabSegIdx, localIdx = _grabLocalIdx;
    final lo = _grabWindowLo, hi = _grabWindowHi;
    if (c == null ||
        segIdx == null ||
        localIdx == null ||
        lo == null ||
        hi == null ||
        _convertingAdjustPoint ||
        !mounted) {
      return;
    }
    final gen = _previewGeneration;
    _convertingAdjustPoint = true;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final latlng = await c.toLatLng(Point(p.dx * dpr, p.dy * dpr));
      if (!mounted ||
          !_adjustLineMode ||
          _grabSegIdx != segIdx ||
          gen != _previewGeneration) {
        return;
      }
      final preview = List<LatLng>.of(_segments[segIdx].sublist(lo, hi + 1));
      preview[localIdx - lo] = latlng;
      await _strokeLayer?.setRoute(preview, _strokePreviewColor);
    } finally {
      _convertingAdjustPoint = false;
    }
  }

  /// Commits the grab: re-aligns the dragged point and ripples the
  /// correction out to its neighbours within the same segment — see
  /// [TrailRouter.rippleRealign].
  Future<void> _onAdjustPanEnd(DragEndDetails _) async {
    final c = _c;
    final segIdx = _grabSegIdx, localIdx = _grabLocalIdx;
    final offset = _lastAdjustOffset;
    setState(() {
      _previewGeneration++;
      _grabSegIdx = null;
      _grabLocalIdx = null;
      _grabWindowLo = null;
      _grabWindowHi = null;
      _lastAdjustOffset = null;
    });
    unawaited(_strokeLayer?.setRoute(const [], _strokePreviewColor));
    if (c == null || segIdx == null || localIdx == null || offset == null) {
      return;
    }

    setState(() => _adjustingLine = true);
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final newPos =
          await c.toLatLng(Point(offset.dx * dpr, offset.dy * dpr));
      if (!mounted) return;
      final realigned =
          await TrailRouter(c).rippleRealign(_segments[segIdx], localIdx, newPos);
      setState(() {
        _segments[segIdx] = realigned;
        _trail.path = _composePath();
        _dirty = true;
      });
      await _redraw();
    } finally {
      if (mounted) setState(() => _adjustingLine = false);
    }
  }

  /// Flattens the per-anchor segments into the full route polyline.
  List<LatLng> _composePath() {
    final path = <LatLng>[];
    for (final seg in _segments) {
      if (path.isEmpty) {
        path.addAll(seg);
      } else {
        path.addAll(seg.skip(1)); // seg starts at the previous anchor
      }
    }
    return path;
  }

  CameraPosition get _initialCamera {
    final target = _trail.path.isNotEmpty ? _trail.path.first : _region.center;
    return CameraPosition(target: target, zoom: 15);
  }

  Future<void> _onMapClick(Point<double> _, LatLng latlng) async {
    if (_cueMode) {
      if (_moving != null) {
        await _placeMovingCue(latlng);
      } else {
        await _addCueAt(latlng);
      }
    } else if (_movingAnchor != null) {
      await _placeMovingAnchor(latlng);
    } else {
      await _addAnchor(latlng);
    }
  }

  /// Next stack position — the default a new cue's editor field is prefilled
  /// with (append to the end); the author can type a different number in
  /// directly to insert it elsewhere instead. Deliberately no geometric
  /// auto-guessing here — that was tried and broke exactly on a path that
  /// crosses itself, silently reshuffling cues far from where a fresh tap
  /// actually belonged.
  int get _nextCueOrder => _trail.cues.isEmpty
      ? 0
      : _trail.cues.map((c) => c.order).reduce((a, b) => a > b ? a : b) + 1;

  /// Inserts [cue] at [cue.order] (already the author's chosen position —
  /// see [showCueEditor]'s `initialOrder`), shifting every cue currently at
  /// or after that position up by one to make room.
  void _insertCueAtOrder(Cue cue) {
    for (final c in _trail.cues) {
      if (c.order >= cue.order) c.order++;
    }
    _trail.cues.add(cue);
  }

  /// Opens the cue editor at [position] and, if saved, adds the cue.
  Future<void> _addCueAt(LatLng position) async {
    final cue = await showCueEditor(context,
        position: position, initialOrder: _nextCueOrder);
    if (cue == null) return;
    setState(() => _insertCueAtOrder(cue));
    _dirty = true;
    await _redraw();
  }

  /// Commits [_moving] to [tapped] — snapped onto the drawn path by default,
  /// or placed exactly where tapped when Free placement is on.
  Future<void> _placeMovingCue(LatLng tapped) async {
    final cue = _moving;
    if (cue == null) return;
    final target =
        _freeMove ? tapped : nearestPointOnPath(tapped, _trail.path);
    setState(() {
      cue.position = target;
      _moving = null;
      _dirty = true;
    });
    await _redraw();
  }

  void _cancelMoving() => setState(() => _moving = null);

  /// Adds a trail anchor at [tap]. When [snap] is true the point snaps to a
  /// nearby trail; when false (e.g. linking an existing cue) its exact position
  /// is kept. With auto-follow on, the segment traces trail geometry from the
  /// previous anchor.
  Future<void> _addAnchor(LatLng tap, {bool snap = true}) async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final from = _trail.anchors.isEmpty ? null : _trail.anchors.last;
      List<LatLng> segment;
      LatLng end;
      if (_follow && snap) {
        final conn = await TrailRouter(c).connect(from: from, to: tap);
        end = conn.end;
        segment = conn.polyline;
      } else if (_follow) {
        end = tap;
        segment = from == null ? [tap] : await TrailRouter(c).between(from, tap);
      } else {
        end = tap;
        segment = from == null ? [tap] : [from, tap];
      }
      setState(() {
        _trail.anchors.add(end);
        _segments.add(segment);
        _trail.path = _composePath();
        _dirty = true;
      });
      await _redraw();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onCueTapped(Symbol s) async {
    final group = _symbolToCueGroup[s.id];
    if (group != null) {
      await _cueGroupSheet(group);
      return;
    }
    final cue = _symbolToCue[s.id];
    if (cue != null) await _editCue(cue);
  }

  /// Tapping a stacked-cue marker (2+ cues within a metre of each other)
  /// shows which cues live there and lets the author pick one to edit, or
  /// add a new one to the same spot — rather than guessing which was meant.
  Future<void> _cueGroupSheet(List<Cue> group) async {
    final display = _cueDisplayInfo();
    final sorted = List.of(group)
      ..sort((a, b) => (display.rank[a] ?? 0).compareTo(display.rank[b] ?? 0));
    final choice = await showModalBottomSheet<Cue>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${sorted.length} cues stacked here',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
            ),
            for (final cue in sorted)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: cueColor(cue.type),
                  child: Text('${display.rank[cue]}',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                title: Text(cue.label),
                subtitle:
                    Text(cue.spoken, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, cue),
              ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.add)),
              title: const Text('Add another cue at this same spot'),
              onTap: () => Navigator.pop(ctx, addAnotherCueSentinel),
            ),
            // Explicit nav-bar inset in addition to the SafeArea above — see
            // the same reasoning in cue_editor_sheet.dart.
            SizedBox(height: 8 + MediaQuery.viewPaddingOf(ctx).bottom),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (identical(choice, addAnotherCueSentinel)) {
      // Defaults to after the highest cue number anywhere on the trail — see
      // the same reasoning in _editCue's addAnotherCueSentinel branch.
      final another = await showCueEditor(context,
          position: sorted.first.position, initialOrder: _nextCueOrder);
      if (!mounted || another == null) return;
      setState(() => _insertCueAtOrder(another));
      _dirty = true;
      await _redraw();
    } else {
      await _editCue(choice);
    }
  }

  Future<void> _editCue(Cue cue) async {
    final result = await showCueEditor(context, position: cue.position, existing: cue);
    if (result == deletedCueSentinel) {
      setState(() => _trail.cues.remove(cue));
    } else if (result == addAnotherCueSentinel) {
      // Defaults to after the highest cue number anywhere on the trail, not
      // the one it's stacking with — a marker you pass on the way back might
      // fire after dozens of other cues, so "previous + 1" would be wrong.
      // Still editable in the field if that's not actually where it belongs.
      if (!mounted) return;
      final another = await showCueEditor(context,
          position: cue.position, initialOrder: _nextCueOrder);
      if (!mounted || another == null) return;
      setState(() => _insertCueAtOrder(another));
      _dirty = true;
      await _redraw();
      return;
    } else if (result != null) {
      // order is deliberately left untouched — editing a cue's type/text
      // shouldn't move its place in the firing sequence.
      setState(() {
        cue
          ..type = result.type
          ..label = result.label
          ..spoken = result.spoken
          ..radiusMeters = result.radiusMeters;
      });
    } else {
      return;
    }
    _dirty = true;
    await _redraw();
  }

  /// Long-press on an anchor opens this: move it, or delete it (existing
  /// confirm-dialog flow unchanged).
  Future<void> _anchorActionSheet(int index) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_with),
              title: const Text('Move this point'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete this point'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            SizedBox(height: MediaQuery.viewPaddingOf(ctx).bottom),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'move') {
      setState(() => _movingAnchor = index);
      await _redraw();
    } else if (action == 'delete') {
      await _confirmDeleteAnchor(index);
    }
  }

  void _cancelMovingAnchor() => setState(() => _movingAnchor = null);

  /// Commits the anchor at [_movingAnchor] to [tapped], re-routing the hop(s)
  /// on either side of it — same re-joining logic [_deleteAnchor] uses for a
  /// removed middle point, just re-targeted instead of closed up.
  Future<void> _placeMovingAnchor(LatLng tapped) async {
    final idx = _movingAnchor;
    if (idx == null) return;
    final c = _c;
    setState(() => _busy = true);
    try {
      final anchors = _trail.anchors;
      anchors[idx] = tapped;
      if (idx > 0) {
        final prev = anchors[idx - 1];
        _segments[idx] = (_follow && c != null)
            ? await TrailRouter(c).between(prev, tapped)
            : [prev, tapped];
      } else if (_segments.isNotEmpty) {
        _segments[0] = [tapped];
      }
      if (idx < anchors.length - 1) {
        final next = anchors[idx + 1];
        _segments[idx + 1] = (_follow && c != null)
            ? await TrailRouter(c).between(tapped, next)
            : [tapped, next];
      }
      _trail.path = _composePath();
      _dirty = true;
    } finally {
      _movingAnchor = null;
      if (mounted) setState(() => _busy = false);
    }
    await _redraw();
  }

  /// Inserts a new anchor between whichever existing hop [tapped] lands
  /// closest to (within tolerance), splitting that hop into two routed
  /// segments — for fixing a path drawn too coarsely to follow a real trail,
  /// without needing to delete and redraw everything after the gap.
  Future<void> _insertAnchorNear(LatLng tapped) async {
    final c = _c;
    if (c == null || _busy || _segments.length < 2) return;
    var bestHop = -1;
    var bestMeters = 20.0;
    for (var k = 1; k < _segments.length; k++) {
      final d = distanceToPath(tapped, _segments[k]);
      if (d < bestMeters) {
        bestMeters = d;
        bestHop = k;
      }
    }
    if (bestHop < 0) return; // not close enough to any existing line
    setState(() => _busy = true);
    try {
      final prev = _trail.anchors[bestHop - 1];
      final next = _trail.anchors[bestHop];
      final segA =
          _follow ? await TrailRouter(c).between(prev, tapped) : [prev, tapped];
      final segB =
          _follow ? await TrailRouter(c).between(tapped, next) : [tapped, next];
      setState(() {
        _trail.anchors.insert(bestHop, tapped);
        _segments[bestHop] = segA;
        _segments.insert(bestHop + 1, segB);
        _trail.path = _composePath();
        _dirty = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _redraw();
  }

  /// Confirms and deletes anchor [i], re-joining the trail across the gap.
  Future<void> _confirmDeleteAnchor(int i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this point?'),
        content: const Text('Removes the point and re-joins the trail.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await _deleteAnchor(i);
  }

  Future<void> _deleteAnchor(int i) async {
    final anchors = _trail.anchors;
    if (i < 0 || i >= anchors.length) return;
    final c = _c;
    setState(() => _busy = true);
    try {
      if (anchors.length == 1) {
        anchors.clear();
        _segments.clear();
      } else if (i == anchors.length - 1) {
        anchors.removeLast();
        if (_segments.isNotEmpty) _segments.removeLast();
      } else if (i == 0) {
        anchors.removeAt(0);
        if (_segments.isNotEmpty) _segments.removeAt(0);
        if (_segments.isNotEmpty) _segments[0] = [anchors.first];
      } else {
        // Middle: re-join anchors[i-1] → anchors[i+1].
        final prev = anchors[i - 1], next = anchors[i + 1];
        anchors.removeAt(i);
        _segments.removeAt(i); // old seg i (prev → deleted)
        _segments.removeAt(i); // old seg i+1 (deleted → next)
        final seg = (_follow && c != null)
            ? await TrailRouter(c).between(prev, next)
            : [prev, next];
        _segments.insert(i, seg);
      }
      _trail.path = _composePath();
      _dirty = true;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _redraw();
  }

  Future<void> _redraw() async {
    final c = _c;
    if (c == null) return;
    await c.clearCircles();
    await c.clearSymbols();
    _symbolToCue.clear();
    _circleToCue.clear();
    _circleToCueGroup.clear();
    _symbolToCueGroup.clear();
    _circleToAnchor.clear();

    // The route line + directional arrows (GeoJSON layer, taps pass through).
    await _routeLayer?.setRoute(_trail.path, _trail.color);

    // Anchor markers: start is green, the last (drawing-from) anchor is a
    // larger highlighted ring, the rest are small blue dots. Long-press for
    // move/delete. One awaiting a move is highlighted gold, like a moving cue.
    final anchors = _trail.anchors;
    for (var i = 0; i < anchors.length; i++) {
      final isLast = i == anchors.length - 1;
      final isFirst = i == 0;
      final isMovingAnchor = i == _movingAnchor;
      final color = isFirst ? '#2E7D32' : '#1565C0';
      final circle = await c.addCircle(CircleOptions(
        geometry: anchors[i],
        circleRadius: isMovingAnchor ? 12 : (isLast ? 12 : 7),
        circleColor: isLast ? '#ffffff' : color,
        circleStrokeColor: isMovingAnchor ? '#FFC107' : (isLast ? '#1565C0' : '#ffffff'),
        circleStrokeWidth: isMovingAnchor ? 5 : (isLast ? 5 : 2),
      ));
      _circleToAnchor[circle.id] = i;
      if (isLast && anchors.length > 1) {
        // Inner dot so the highlighted "from here" anchor reads as a target.
        final inner = await c.addCircle(CircleOptions(
          geometry: anchors[i],
          circleRadius: 4,
          circleColor: '#1565C0',
        ));
        _circleToAnchor[inner.id] = i;
      }
    }

    final display = _cueDisplayInfo();
    for (final group in display.groups) {
      final stacked = group.length > 1;
      if (stacked) {
        group.sort(
            (a, b) => (display.rank[a] ?? 0).compareTo(display.rank[b] ?? 0));
      }
      final cue = group.first;
      final isMoving = !stacked && identical(cue, _moving);
      final isHighlighted = !stacked && identical(cue, _highlighted);
      final cueCircle = await c.addCircle(CircleOptions(
        geometry: cue.position,
        circleRadius: stacked ? 13 : (isMoving || isHighlighted ? 15 : 11),
        circleColor: stacked ? stackedCueColorHex : cueColorHex(cue.type),
        // A cue pending a move is highlighted gold; one just located from the
        // cue list flashes cyan, so it's obvious which marker is which.
        circleStrokeColor: stacked
            ? '#ffffff'
            : (isMoving ? '#FFC107' : (isHighlighted ? '#00E5FF' : '#ffffff')),
        circleStrokeWidth: stacked ? 4 : (isMoving || isHighlighted ? 5 : 3),
      ));
      final symbol = await c.addSymbol(SymbolOptions(
        geometry: cue.position,
        // Rank (not the raw, possibly-gappy order value) ties the map
        // marker to its row in the cue list. A stacked spot lists every cue
        // there on its own line instead of hiding all but one.
        textField: stacked
            ? group.map((g) => '${display.rank[g]}. ${g.label}').join('\n')
            : '${display.rank[cue]}. ${cue.label}',
        textSize: 15,
        textColor: '#1a1a1a',
        textHaloColor: '#ffffff',
        textHaloWidth: 2,
        textAnchor: 'top',
        textOffset: const Offset(0, 1.1),
      ));
      if (stacked) {
        _circleToCueGroup[cueCircle.id] = group;
        _symbolToCueGroup[symbol.id] = group;
      } else {
        _circleToCue[cueCircle.id] = cue;
        _symbolToCue[symbol.id] = cue;
      }
    }
  }

  /// Display rank (sorted, always a clean 1..N regardless of what the
  /// underlying [Cue.order] integers actually are — manual entry and moves
  /// can leave gaps) and draw groups for every cue in [_trail]: cues within a
  /// metre of each other are grouped so they render as one "stacked" marker
  /// instead of hiding on top of one another. A cue mid-move or just located
  /// from the cue list is always kept in its own solo group so it can still
  /// be highlighted distinctly (gold / cyan) even if it shares a spot.
  ({Map<Cue, int> rank, List<List<Cue>> groups}) _cueDisplayInfo() {
    final sorted = List.of(_trail.cues)
      ..sort((a, b) => a.order.compareTo(b.order));
    final rank = <Cue, int>{
      for (var i = 0; i < sorted.length; i++) sorted[i]: i + 1,
    };

    final groups = <List<Cue>>[];
    for (final cue in _trail.cues) {
      if (identical(cue, _moving) || identical(cue, _highlighted)) {
        groups.add([cue]);
        continue;
      }
      final match = groups.where((g) =>
          !identical(g.first, _moving) &&
          !identical(g.first, _highlighted) &&
          metersBetween(g.first.position, cue.position) < 1.0);
      if (match.isNotEmpty) {
        match.first.add(cue);
      } else {
        groups.add([cue]);
      }
    }
    return (rank: rank, groups: groups);
  }

  /// Resolves the current GPS position, handling permission + service checks
  /// and surfacing a toast on failure. Returns null if unavailable.
  Future<LatLng?> _myLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _toast('Turn on location services first');
      return null;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      _toast('Location permission is needed to use your position');
      return null;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 12),
        ),
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      _toast('Could not get a GPS fix — try again in the open');
      return null;
    }
  }

  /// Centres the map on the author's current location (no marker placed).
  Future<void> _centerOnMe() async {
    final here = await _myLocation();
    if (here == null || !mounted) return;
    await _c?.animateCamera(CameraUpdate.newLatLngZoom(here, 16));
  }

  /// Adds a path point (or opens the cue editor) at the walker's current GPS
  /// position — so an author can build a trail by walking it.
  Future<void> _markHere() async {
    final here = await _myLocation();
    if (here == null || !mounted) return;
    await _c?.animateCamera(CameraUpdate.newLatLng(here));
    if (!mounted) return;
    if (_cueMode) {
      final cue = await showCueEditor(context,
          position: here, initialOrder: _nextCueOrder);
      if (!mounted || cue == null) return;
      setState(() => _insertCueAtOrder(cue));
      _dirty = true;
      await _redraw();
    } else {
      await _addAnchor(here);
    }
  }

  /// Suggests turn cues along the currently drawn path. Adds them alongside any
  /// existing cues (after confirming a replace when cues are already present).
  Future<void> _suggestCuesForPath() async {
    if (_trail.path.length < 2) {
      _toast('Draw or generate a path first');
      return;
    }
    if (_trail.cues.isNotEmpty &&
        !await _confirm('Replace the current cues with suggested ones?')) {
      return;
    }
    final suggested = suggestCues(_trail.path);
    setState(() {
      _trail.cues
        ..clear()
        ..addAll(suggested);
      _dirty = true;
    });
    await _redraw();
    _toast('Added ${suggested.length} suggested cues');
  }

  /// Opens the generator sheet, then auto-builds a route from the trails in the
  /// current map view. Replaces the existing path (after confirming).
  Future<void> _openGenerator() async {
    // Every exit from here now surfaces something — a toast, the sheet, or
    // the generated route itself — so a tap on "Auto-generate" never just
    // silently does nothing with no feedback at all.
    try {
      final choice = await showModalBottomSheet<_GenChoice>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        builder: (_) => _GeneratorSheet(hasBoundary: _genBoundary != null),
      );
      if (choice == null || !mounted) return;
      if (_trail.anchors.isNotEmpty &&
          !await _confirm('Replace the current path with a generated one?')) {
        return;
      }
      await _generateRoute(choice);
    } catch (_) {
      if (mounted) _toast('Could not open the generator — try again');
    }
  }

  Future<void> _generateRoute(_GenChoice choice) async {
    final c = _c;
    if (c == null) {
      _toast('Map is still loading — try again in a second');
      return;
    }
    if (_busy) {
      _toast('Still working on the last request — try again in a moment');
      return;
    }
    setState(() => _busy = true);
    try {
      final router = TrailRouter(c);
      final boundary = _genBoundary;
      // With a drawn boundary, center inside it rather than the camera's
      // (possibly much larger, or off-boundary) current view. The outline
      // can be concave, so its bounding-box midpoint (not a true centroid)
      // is used — spliceTempNode just needs a reasonable starting point
      // near the drawn area, not one guaranteed inside it.
      LatLng center;
      if (boundary != null) {
        final lats = boundary.map((p) => p.latitude);
        final lngs = boundary.map((p) => p.longitude);
        center = LatLng((lats.reduce(min) + lats.reduce(max)) / 2,
            (lngs.reduce(min) + lngs.reduce(max)) / 2);
      } else {
        final bounds = await c.getVisibleRegion();
        center = LatLng(
          (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
          (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
        );
      }
      final route = await router.generate(
        center: center,
        viewport: await router.visibleViewportRect(),
        targetMeters: choice.meters,
        preferLoop: choice.loop,
        boundaryPolygon: boundary,
        surface: choice.surface,
      );
      if (!mounted) return;
      if (route == null) {
        _toast(boundary != null
            ? 'No trails found in your drawn area — try a bigger outline'
            : 'No trails found here — zoom to a trail area and try again');
        return;
      }
      setState(() {
        _trail.path = route.path;
        _segments
          ..clear()
          ..addAll(_rebuildSegments(route.path, route.anchors));
        if (choice.cues) {
          // route.path already includes both legs of an out-and-back, so
          // walking it start to finish naturally assigns correct stack order.
          _trail.cues
            ..clear()
            ..addAll(suggestCues(route.path));
        }
        _dirty = true;
      });
      await _redraw();
      final dist = Settings.instance.formatDistance(route.meters);
      final cueNote = choice.cues ? ' · ${_trail.cues.length} cues' : '';
      // A boxed-in area can run out of fresh trail to pad the route with
      // (see TrailRouter.generate's coverage-walk) — say so plainly rather
      // than reporting a shortfall as if it were what was asked for.
      final shortfall = route.meters < choice.meters * 0.7;
      final note = shortfall
          ? ' — that\'s all the trail this area has room for, even with some doubling back'
          : route.surfaceFallback
              ? ' — not enough ${choice.surface == Surface.trails ? "trail" : "road"} '
                  'here, so this mixes in the other surface too'
              : '';
      _toast('${route.loop ? "Loop" : "Out-and-back"} generated — '
          '$dist$cueNote$note');
    } catch (_) {
      if (mounted) _toast('Could not generate a route here — try another spot');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Snaps the map back to north and flat (birds-eye).
  Future<void> _resetView() async {
    await _c?.animateCamera(CameraUpdate.bearingTo(0));
    await _c?.animateCamera(CameraUpdate.tiltTo(0));
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _undoLastPoint() {
    if (_trail.anchors.isEmpty) return;
    setState(() {
      _trail.anchors.removeLast();
      if (_segments.isNotEmpty) _segments.removeLast();
      _trail.path = _composePath();
      _dirty = true;
    });
    _redraw();
  }

  Future<bool> _confirm(String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _clearPath() async {
    if (_trail.anchors.isEmpty) return;
    if (!await _confirm('Clear the whole path?')) return;
    setState(() {
      _trail.anchors.clear();
      _segments.clear();
      _trail.path = [];
      _dirty = true;
    });
    await _redraw();
  }

  Future<void> _clearCues() async {
    if (_trail.cues.isEmpty) return;
    if (!await _confirm('Delete all cues?')) return;
    setState(() {
      _trail.cues.clear();
      _dirty = true;
    });
    await _redraw();
  }

  static Color _hexColor(String h) =>
      Color(int.parse(h.substring(1), radix: 16) | 0xFF000000);

  Future<void> _pickColor() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          // Explicit nav-bar inset in addition to the SafeArea above — see
          // the same reasoning in cue_editor_sheet.dart.
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.viewPaddingOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Trail colour',
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final c in kTrailColors)
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx, c.hex),
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: _hexColor(c.hex),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _trail.color == c.hex
                                ? Colors.black
                                : Colors.white,
                            width: _trail.color == c.hex ? 4 : 2,
                          ),
                        ),
                        child: _trail.color == c.hex
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() => _trail.color = picked);
      _dirty = true;
      await _redraw();
    }
  }

  Future<void> _clearAll() async {
    if (_trail.anchors.isEmpty && _trail.cues.isEmpty) return;
    if (!await _confirm('Clear the path and all cues?')) return;
    setState(() {
      _trail.anchors.clear();
      _segments.clear();
      _trail.path = [];
      _trail.cues.clear();
      _dirty = true;
    });
    await _redraw();
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _trail.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trail name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. River Loop'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      setState(() => _trail.name = name);
      _dirty = true;
    }
  }

  Future<void> _save() async {
    if (_trail.name.trim().isEmpty || _trail.name == 'New trail') {
      await _rename();
    }
    await TrailStore.instance.save(_trail);
    _dirty = false;
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved "${_trail.name}"')));
      Navigator.pop(context, true);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('This trail has unsaved changes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Opens the numbered cue list; edits/reorders/deletes there mutate
  /// _trail.cues in place, so just re-draw and mark dirty on return. Tapping
  /// a row's "show on map" action pops with that cue, which we then centre
  /// on and briefly highlight.
  Future<void> _openCueList() async {
    final located = await Navigator.push<Cue>(
        context, MaterialPageRoute(builder: (_) => CueListScreen(trail: _trail)));
    if (!mounted) return;
    setState(() => _dirty = true);
    await _redraw();
    if (located != null) await _locateCue(located);
  }

  Future<void> _locateCue(Cue cue) async {
    await _c?.animateCamera(CameraUpdate.newLatLngZoom(cue.position, 17));
    _highlightTimer?.cancel();
    setState(() => _highlighted = cue);
    await _redraw();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !identical(_highlighted, cue)) return;
      setState(() => _highlighted = null);
      _redraw();
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _rename,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(_trail.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                const Icon(Icons.edit, size: 18),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Trail colour',
              onPressed: _pickColor,
              icon: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: _hexColor(_trail.color),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Cue order',
              onPressed: _trail.cues.isEmpty ? null : _openCueList,
              icon: const Icon(Icons.format_list_numbered),
            ),
            IconButton(
              tooltip: 'Undo last point',
              onPressed: _undoLastPoint,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Save',
              onPressed: _save,
              icon: const Icon(Icons.save),
            ),
            PopupMenuButton<String>(
              tooltip: 'Clear',
              onSelected: (v) {
                if (v == 'suggest') _suggestCuesForPath();
                if (v == 'path') _clearPath();
                if (v == 'cues') _clearCues();
                if (v == 'all') _clearAll();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'suggest', child: Text('Suggest turn cues')),
                PopupMenuItem(value: 'path', child: Text('Clear path')),
                PopupMenuItem(value: 'cues', child: Text('Clear all cues')),
                PopupMenuItem(value: 'all', child: Text('Clear everything')),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            BaseMap(
              region: _region,
              initialCamera: _initialCamera,
              onMapCreated: _onMapCreated,
              onStyleLoaded: _onStyleLoaded,
              onMapClick: _onMapClick,
              onMapLongClick: _onMapLongClick,
              myLocationEnabled: true, // show the author's position dot
              gesturesEnabled:
                  !_drawBoundaryMode && !_dragDrawMode && !_adjustLineMode,
            ),
            // Absorbs drag input while drawing a generation-boundary outline
            // — only present in that mode, so it never steals ordinary taps
            // (path/cue placement) the rest of the time. Invisible itself —
            // the live preview is drawn by _boundaryLayer (see
            // _pushDragPreview), not a Flutter-side overlay: a CustomPaint
            // layered on top of the map's native platform view was tried
            // first but didn't reliably render during an active drag, so the
            // preview goes through the same rendering path already proven to
            // work for the final result.
            if (_drawBoundaryMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _onBoundaryPanStart,
                  onPanUpdate: _onBoundaryPanUpdate,
                  onPanEnd: _onBoundaryPanEnd,
                ),
              ),
            if (_drawBoundaryMode)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                // Clamped for the same reason as _ModeBar — a large system
                // font/display scale (Samsung's range in particular can go
                // well past stock Android's) has room to grow this bar
                // taller, but not to shatter "Drag to outline a boundary
                // area" into single-character lines.
                child: Center(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.3,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.draw),
                            const SizedBox(width: 10),
                            const Text('Drag to outline a boundary area'),
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: _toggleDrawBoundary,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // Absorbs drag input while tracing a trail stroke by hand —
            // same idea as the boundary drag detector above, but with no
            // live preview: the raw drag isn't converted/snapped until
            // release (see _onStrokePanEnd), matching how record mode's own
            // cleanup only nudges points after Stop, not while recording.
            if (_dragDrawMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _onStrokePanStart,
                  onPanUpdate: _onStrokePanUpdate,
                  onPanEnd: _onStrokePanEnd,
                ),
              ),
            if (_dragDrawMode)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.3,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _committingStroke
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.gesture),
                            const SizedBox(width: 10),
                            Text(_committingStroke
                                ? 'Snapping to trail…'
                                : 'Drag along the trail — it\'ll nudge onto the nearest mapped path'),
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: _toggleDragDraw,
                              child: const Text('Done'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // Absorbs drag input while grabbing/pulling a point on the drawn
            // line — see _onAdjustPanEnd/TrailRouter.rippleRealign.
            if (_adjustLineMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _onAdjustPanStart,
                  onPanUpdate: _onAdjustPanUpdate,
                  onPanEnd: _onAdjustPanEnd,
                ),
              ),
            if (_adjustLineMode)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.3,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _adjustingLine
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.tune),
                            const SizedBox(width: 10),
                            Text(_adjustingLine
                                ? 'Re-aligning…'
                                : 'Drag a point on the line to pull it onto the trail'),
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: _toggleAdjustLine,
                              child: const Text('Done'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_genBoundary != null &&
                !_drawBoundaryMode &&
                _moving == null &&
                _movingAnchor == null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 190 + MediaQuery.viewPaddingOf(context).bottom,
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.draw),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text('Boundary area set',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                          TextButton(
                            onPressed: _clearBoundary,
                            child: const Text('Clear'),
                          ),
                          FilledButton(
                            onPressed: _busy ? null : _openGenerator,
                            child: const Text('Generate here'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // Top-right so the (variable-height) mode bar never covers it.
            Positioned(
              right: 12,
              top: 12,
              child: FloatingActionButton.extended(
                heroTag: 'markHere',
                onPressed: _busy ? null : _markHere,
                icon: const Icon(Icons.my_location),
                label: const Text('Mark here'),
              ),
            ),
            Positioned(
              right: 12,
              top: 78,
              child: FloatingActionButton.small(
                heroTag: 'resetView',
                tooltip: 'Face north / flat',
                onPressed: _resetView,
                child: const Icon(Icons.explore),
              ),
            ),
            Positioned(
              right: 12,
              top: 132,
              child: FloatingActionButton.small(
                heroTag: 'centerMe',
                tooltip: 'Center on my location',
                onPressed: _centerOnMe,
                child: const Icon(Icons.gps_fixed),
              ),
            ),
            if (_busy)
              const Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('Following trail…'),
                      ]),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: _modeBarHidden ? null : 12,
              right: 12,
              // Lift above the Android nav bar (0 on gesture-nav phones).
              bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
              child: _modeBarHidden
                  // Hidden entirely — just a small corner FAB (same style as
                  // the map's other small FABs) to bring it back, restoring
                  // whatever expanded/collapsed state it was in before.
                  ? FloatingActionButton.small(
                      heroTag: 'modeBarRestore',
                      tooltip: 'Show trail controls',
                      onPressed: () => setState(() => _modeBarHidden = false),
                      child: Icon(_cueMode
                          ? Icons.add_location_alt
                          : Icons.timeline),
                    )
                  : _ModeBar(
                      cueMode: _cueMode,
                      follow: _follow,
                      anchorCount: _trail.anchors.length,
                      cueCount: _trail.cues.length,
                      lengthLabel: Settings.instance
                          .formatDistance(pathLength(_trail.path)),
                      freeMove: _freeMove,
                      expanded: _modeBarExpanded,
                      onModeChanged: (v) {
                        setState(() {
                          _cueMode = v;
                          if (v) {
                            _previewGeneration++;
                            _dragDrawMode = false;
                            _strokePoints.clear();
                            _strokePreview.clear();
                            _adjustLineMode = false;
                            _grabSegIdx = null;
                            _grabLocalIdx = null;
                            _grabWindowLo = null;
                            _grabWindowHi = null;
                          }
                        });
                        if (v) {
                          unawaited(
                              _strokeLayer?.setRoute(const [], _strokePreviewColor));
                        }
                      },
                      onFollowChanged: (v) => setState(() => _follow = v),
                      onFreeMoveChanged: (v) =>
                          setState(() => _freeMove = v),
                      onExpandedChanged: (v) =>
                          setState(() => _modeBarExpanded = v),
                      onHide: () => setState(() => _modeBarHidden = true),
                      // Stays tappable even while busy (rather than
                      // disabling and going silent) so a tap always gives
                      // some feedback instead of doing nothing visibly.
                      onGenerate: _busy
                          ? () => _toast(
                              'Still working on the last request — try again in a moment')
                          : _openGenerator,
                      drawBoundaryActive: _drawBoundaryMode,
                      onToggleDrawBoundary: _toggleDrawBoundary,
                      dragDrawActive: _dragDrawMode,
                      onToggleDragDraw: _toggleDragDraw,
                      adjustLineActive: _adjustLineMode,
                      onToggleAdjustLine: _toggleAdjustLine,
                    ),
            ),
            if (_moving != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 190 + MediaQuery.viewPaddingOf(context).bottom,
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: Card(
                    color: const Color(0xFFFFF8E1),
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.open_with, color: Color(0xFFF57F17)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                                'Moving "${_moving!.label}" — tap the map to place it',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                          TextButton(
                              onPressed: _cancelMoving,
                              child: const Text('Cancel')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_movingAnchor != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 190 + MediaQuery.viewPaddingOf(context).bottom,
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: Card(
                    color: const Color(0xFFFFF8E1),
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.open_with, color: Color(0xFFF57F17)),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text('Moving point — tap the map to place it',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                          TextButton(
                              onPressed: _cancelMovingAnchor,
                              child: const Text('Cancel')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The Path / Cue mode toggle, auto-follow switch, and a hint line. A small
/// expand/collapse button in the corner drops the switch + hint when the
/// card is getting in the way of actively drawing, keeping just the mode
/// toggle and trail length visible; a second button hides the card entirely
/// down to a small corner icon (see [_AuthorScreenState._modeBarHidden]) for
/// when even that's still in the way.
class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.cueMode,
    required this.follow,
    required this.anchorCount,
    required this.cueCount,
    required this.lengthLabel,
    required this.freeMove,
    required this.expanded,
    required this.onModeChanged,
    required this.onFollowChanged,
    required this.onFreeMoveChanged,
    required this.onExpandedChanged,
    required this.onHide,
    required this.onGenerate,
    required this.drawBoundaryActive,
    required this.onToggleDrawBoundary,
    required this.dragDrawActive,
    required this.onToggleDragDraw,
    required this.adjustLineActive,
    required this.onToggleAdjustLine,
  });

  final bool cueMode;
  final bool follow;
  final int anchorCount;
  final int cueCount;
  final String lengthLabel;
  final bool freeMove;
  final bool expanded;
  final ValueChanged<bool> onModeChanged;
  final ValueChanged<bool> onFollowChanged;
  final ValueChanged<bool> onFreeMoveChanged;
  final ValueChanged<bool> onExpandedChanged;
  final VoidCallback onHide;
  final VoidCallback onGenerate;

  /// Whether a boundary-box drag is currently in progress — see
  /// [_AuthorScreenState._drawBoundaryMode].
  final bool drawBoundaryActive;
  final VoidCallback onToggleDrawBoundary;

  /// Whether a hand-drawn trail stroke is currently being traced — see
  /// [_AuthorScreenState._dragDrawMode].
  final bool dragDrawActive;
  final VoidCallback onToggleDragDraw;

  /// Whether the line-adjust ("grab and pull a point") tool is active —
  /// see [_AuthorScreenState._adjustLineMode].
  final bool adjustLineActive;
  final VoidCallback onToggleAdjustLine;

  @override
  Widget build(BuildContext context) {
    // A few phones (Samsung's Settings → Display font/zoom range in
    // particular goes well past stock Android's usual max) can push the
    // system text scale high enough that this bar's fixed-height icon+label
    // rows have nowhere to grow, and "Draw path"/"Add cue" wrap down to one
    // character per line instead of just growing taller. Clamped rather
    // than disabled outright — 1.3x still gives real accessibility headroom,
    // just not enough to break the layout. The segmented button now also
    // gets its own full-width row (see below) rather than sharing one with
    // four other icon buttons — on a narrower phone, or any phone at a
    // large system font size, that left it almost no room and its labels
    // wrapped one character per line ("Draw path" as "D/r/a/w"). Splitting
    // the icon buttons onto their own row above fixes that regardless of
    // text scale, instead of just further lowering the clamp (which would
    // shrink accessibility headroom without addressing the real cause: not
    // enough width, not too-large text).
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Card(
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 2, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Auto-generate a trail here',
                    icon: const Icon(Icons.auto_awesome),
                    onPressed: onGenerate,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: drawBoundaryActive
                        ? 'Cancel drawing boundary area'
                        : 'Draw a boundary area to constrain generation',
                    isSelected: drawBoundaryActive,
                    icon: const Icon(Icons.draw),
                    onPressed: onToggleDrawBoundary,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: cueMode
                        ? 'Switch to Draw path to trace a trail by hand'
                        : dragDrawActive
                            ? 'Stop tracing'
                            : 'Trace a trail by dragging — nudges onto the nearest mapped path',
                    isSelected: dragDrawActive,
                    icon: const Icon(Icons.gesture),
                    onPressed: cueMode ? null : onToggleDragDraw,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: cueMode
                        ? 'Switch to Draw path to adjust the line'
                        : adjustLineActive
                            ? 'Stop adjusting'
                            : 'Grab a point on the line and pull it onto the trail',
                    isSelected: adjustLineActive,
                    icon: const Icon(Icons.tune),
                    onPressed: cueMode ? null : onToggleAdjustLine,
                  ),
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    iconSize: 20,
                    tooltip: expanded ? 'Show less' : 'Show more',
                    icon: Icon(
                        expanded ? Icons.unfold_less : Icons.unfold_more),
                    onPressed: () => onExpandedChanged(!expanded),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    iconSize: 20,
                    tooltip:
                        'Hide — tap the icon in the corner to bring it back',
                    icon: const Icon(Icons.close),
                    onPressed: onHide,
                  ),
                ],
              ),
              // Its own row, full width — see the comment above this method
              // for why this used to share a row with four other buttons.
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: false,
                        icon: Icon(Icons.timeline),
                        label: Text('Draw path')),
                    ButtonSegment(
                        value: true,
                        icon: Icon(Icons.add_location_alt),
                        label: Text('Add cue')),
                  ],
                  selected: {cueMode},
                  onSelectionChanged: (s) => onModeChanged(s.first),
                ),
              ),
            const SizedBox(height: 8),
            // Live planned length of the trail as it's drawn.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.straighten, size: 20),
                const SizedBox(width: 6),
                Text('Trail length: $lengthLabel',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
            if (expanded) ...[
              // Same slot either way (so the bar height — and thus the
              // Draw/Cue buttons — never jump between modes): Follow-trails
              // in Draw mode, Free-placement in Cue mode.
              cueMode
                  ? SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: freeMove,
                      onChanged: onFreeMoveChanged,
                      secondary: const Icon(Icons.open_with),
                      title: const Text('Free placement'),
                      subtitle: Text(freeMove
                          ? 'Moved cues drop exactly where you tap'
                          : 'Moved cues snap onto the drawn trail line'),
                    )
                  : SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: follow,
                      onChanged: onFollowChanged,
                      secondary: const Icon(Icons.alt_route),
                      title: const Text('Follow trails'),
                      subtitle: Text(follow
                          ? 'Route bends along real trails between taps'
                          : 'Straight lines between taps'),
                    ),
              const SizedBox(height: 4),
              Text(
                cueMode
                    ? 'Tap map to drop a cue • tap to edit/delete • long-press to move • $cueCount placed'
                    : 'Tap map to add • tap a point to route through it • long-press a point to move/delete, or long-press the line to insert one • $anchorCount ${anchorCount == 1 ? "point" : "points"}',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}

/// A chosen target length + shape for auto-generation.
class _GenChoice {
  const _GenChoice(this.meters, this.loop, this.cues, this.surface);
  final double meters;
  final bool loop;

  /// Whether to auto-drop turn cues along the generated route.
  final bool cues;

  final Surface surface;
}

/// Bottom sheet to pick a walk length and loop vs out-and-back, then generate.
class _GeneratorSheet extends StatefulWidget {
  const _GeneratorSheet({required this.hasBoundary});

  /// Whether a boundary box is currently drawn — changes the description
  /// text so it's clear generation is constrained to it.
  final bool hasBoundary;

  @override
  State<_GeneratorSheet> createState() => _GeneratorSheetState();
}

class _GeneratorSheetState extends State<_GeneratorSheet> {
  // Slider bounds in metres (~0.5 km to 15 km covers a walk).
  static const _minMeters = 500.0;
  static const _maxMeters = 15000.0;

  double _meters = 4000;
  bool _loop = true;
  bool _cues = true;
  Surface _surface = Surface.mixed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = Settings.instance;
    // Scrollable content + a Generate button pinned outside the scroll area
    // (same structure as cue_editor_sheet.dart) — without this, a sheet that
    // isn't isScrollControlled is capped to a fraction of the screen height,
    // and content taller than that can push the final button below the
    // sheet's actual layout bounds: still visible-ish, but not reliably
    // tappable. Confirmed as the likely cause of "Generate doesn't respond
    // to a finger tap, but works when clicked via Phone Link's mouse" — a
    // difference in reserved nav-bar space could be exactly enough to tip
    // this over on one input path and not the other.
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Auto-generate a trail', style: text.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                      widget.hasBoundary
                          ? 'Builds a route using only the trails inside your '
                              'drawn boundary area, looping back over them if '
                              'needed to reach the target length.'
                          : 'Builds a route from the trails shown on screen now.',
                      style: text.bodyMedium),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('Length', style: text.titleMedium),
                      const Spacer(),
                      // Live, units-aware readout of the chosen distance.
                      Text(s.formatDistance(_meters),
                          style: text.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: _meters,
                    min: _minMeters,
                    max: _maxMeters,
                    divisions: 58, // ~250 m steps
                    label: s.formatDistance(_meters),
                    onChanged: (v) => setState(() => _meters = v),
                  ),
                  // Reference zones along the scale.
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Text('Short',
                            style: TextStyle(color: Color(0xFF4A4A4A))),
                        Spacer(),
                        Text('Medium',
                            style: TextStyle(color: Color(0xFF4A4A4A))),
                        Spacer(),
                        Text('Long',
                            style: TextStyle(color: Color(0xFF4A4A4A))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Shape', style: text.titleMedium),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: true,
                          icon: Icon(Icons.loop),
                          label: Text('Loop')),
                      ButtonSegment(
                          value: false,
                          icon: Icon(Icons.swap_horiz),
                          label: Text('There & back')),
                    ],
                    selected: {_loop},
                    onSelectionChanged: (s) => setState(() => _loop = s.first),
                  ),
                  const SizedBox(height: 16),
                  Text('Surface', style: text.titleMedium),
                  const SizedBox(height: 8),
                  SegmentedButton<Surface>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: Surface.trails,
                          icon: Icon(Icons.park_outlined),
                          label: Text('Trails')),
                      ButtonSegment(
                          value: Surface.mixed,
                          icon: Icon(Icons.shuffle),
                          label: Text('Mixed')),
                      ButtonSegment(
                          value: Surface.roads,
                          icon: Icon(Icons.add_road),
                          label: Text('Roads')),
                    ],
                    selected: {_surface},
                    onSelectionChanged: (s) =>
                        setState(() => _surface = s.first),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      switch (_surface) {
                        Surface.trails =>
                          'Sticks to singletrack/park trails where possible.',
                        Surface.mixed =>
                          'Uses whichever of trails, sidewalks, or roads is shortest.',
                        Surface.roads =>
                          'Sticks to streets and sidewalks where possible.',
                      },
                      style: text.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _cues,
                    onChanged: (v) => setState(() => _cues = v ?? true),
                    secondary: const Icon(Icons.signpost_outlined),
                    title: const Text('Add turn directions'),
                    subtitle:
                        const Text('Drops spoken "turn left / right" cues'),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 12 + MediaQuery.viewPaddingOf(context).bottom),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(
                    context, _GenChoice(_meters, _loop, _cues, _surface)),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Generate'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

