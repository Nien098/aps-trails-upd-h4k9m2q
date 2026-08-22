import 'dart:math' show Point, exp, max, min, sqrt;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../cue_style.dart';
import '../models/trail.dart';
import '../services/boundary_layer.dart';
import '../services/cue_gen.dart';
import '../services/cue_layer.dart';
import '../services/geo.dart';
import '../services/map_drag_lock.dart';
import '../services/pointer_probe.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/trail_router.dart';
import '../services/web_file_io.dart';
import '../services/web_map_style.dart';
import '../trail_colors.dart';
import '../widgets/cue_editor_sheet.dart';
import '../widgets/opaque_dialog.dart';

/// Desktop trail designer (Flutter Web, installed as a PWA) — a purpose-built
/// desktop UI, not a resized phone screen: a full-window map (like a desktop
/// mapping app, not a phone-shaped viewport), a top toolbar instead of a
/// bottom sheet/FABs, and mouse-click drawing instead of touch gestures.
///
/// Drawing follows the same anchors/segments split and snap-to-trail-network
/// model as `AuthorScreen._addAnchor` on mobile (see `route_graph_store.dart`'s
/// conditional export for how `TrailRouter` — previously mobile-only because
/// it imported the `dart:io`/`sqlite3`-backed `RouteGraphStore` — was made
/// web-safe: it now resolves to a no-op stub on web instead, so routing here
/// uses only whatever trail/road geometry is currently rendered on screen,
/// same as `queryRenderedFeaturesInRect` already limits mobile routing to
/// when no offline region data is loaded). Persistence is `.trail` file
/// open/save only (via [WebTrailIo]) — no local trail database, matching the
/// "design here, carry the file to the phone" workflow the desktop tool
/// exists for.
///
/// Cue add/edit/delete reuses mobile's exact [showCueEditor] sheet and
/// `_addCueAt`/`_editCue` logic verbatim (that widget already has no
/// `dart:io` dependency). Anchor move/delete mirrors `AuthorScreen`'s
/// `_commitAnchorPosition`/`_deleteAnchor` byte-for-byte, but reaches an
/// anchor by nearest-distance hit-testing ([_nearestAnchorIndex]) instead of
/// a native tappable `Symbol` — `CueLayer`'s markers are plain
/// (`enableInteraction: false`) GeoJSON circles/symbols, and there's no
/// on-map interactive-annotation layer here the way `AuthorScreen`'s
/// `addSymbol`-based cue markers have; a distance check against the click's
/// `LatLng` is simpler and doesn't need one. Cue editing similarly goes
/// through a plain list dialog ([_showCueList]) rather than an on-map tap,
/// for the same reason.
///
/// Auto-generate mirrors `AuthorScreen._generateRoute`/`_GeneratorSheet`
/// logic and copy closely, adapted to click-based boundary drawing
/// ([_Tool.drawBoundary]) instead of mobile's drag-lasso
/// (`_onBoundaryPanStart`/etc.) — clicking each corner and hitting "Finish
/// boundary" is the natural mouse equivalent of drag-lassoing an area with a
/// finger, and doesn't need a live-toggled pointer-drag-capture overlay the
/// way [_Tool.dragDraw] (below) does.
///
/// [_Tool.dragDraw] (freehand trace) and [_Tool.lineAdjust] (grab-and-bend)
/// both capture a raw mouse drag — mirroring `AuthorScreen`'s
/// `_onStrokePanStart`/`Update`/`End` and `_onAdjustPanStart`/`Update`/`End`
/// closely — via a `GestureDetector` overlay on top of the map. That alone
/// isn't enough on Flutter Web, though: `MapLibreMap.dragEnabled` (the
/// constructor flag that looked like the obvious way to disable the map's
/// *own* camera-drag while a capture overlay is active) turns out to do
/// nothing of the kind on web — reading `maplibre_gl_web`'s source showed it
/// only gates listeners for *annotation* dragging, never `map.dragPan`, the
/// actual interaction handler that pans the camera. Confirmed live: the map
/// could still be grabbed and panned out from under the freehand tool even
/// with `dragEnabled: false`. [setMapDragLocked] (see its doc) is the real
/// fix — it sets `pointer-events: none` directly on MapLibre's own canvas
/// element while either tool is active, so the browser never delivers the
/// drag to the map's native handlers in the first place, leaving the
/// overlay as the only thing that sees it. This replaced an earlier,
/// incorrect approach that rebuilt the whole `MapLibreMap` widget (via a
/// `key` tied to the tool) purely to re-run its constructor with a
/// different `dragEnabled` — unnecessary now that the real lock doesn't
/// need a fresh platform view at all.
///
/// Every overlay here (cue editor/list, rename, colour picker, confirmations,
/// the generator dialog) goes through [showOpaqueDialog] rather than
/// `showDialog`/`showModalBottomSheet` — see that function's doc for why: a
/// translucent barrier does not reliably block clicks from reaching
/// MapLibre's platform-view canvas underneath on Flutter Web.
class DesktopDesignerScreen extends StatefulWidget {
  const DesktopDesignerScreen({super.key});

  @override
  State<DesktopDesignerScreen> createState() => _DesktopDesignerScreenState();
}

/// Which click behaviour is active — mutually exclusive, like
/// `AuthorScreen`'s drawing-mode flags.
enum _Tool {
  draw,
  moveAnchor,
  deleteAnchor,
  addCue,
  drawBoundary,
  dragDraw,
  lineAdjust,
}

class _DesktopDesignerScreenState extends State<DesktopDesignerScreen> {
  static const _initialCamera =
      CameraPosition(target: LatLng(49.2606, -123.1140), zoom: 12);

  MapLibreMapController? _c;
  RouteLayer? _route;
  CueLayer? _points;
  BoundaryLayer? _boundary;

  /// Live preview line for a freehand drag stroke ([_Tool.dragDraw]) — a
  /// second [RouteLayer] (`splitOutAndBack: false`, no need for the
  /// out-and-back dash/arrow treatment on a still-being-drawn preview),
  /// mirroring `AuthorScreen._strokeLayer`.
  RouteLayer? _strokeLayer;

  Trail _trail = Trail(name: 'New trail', regionId: 'web-design');

  /// Per-anchor-hop coordinate arrays, one entry per anchor, aligned by
  /// index — same split `AuthorScreen._segments` uses, so a routed hop's
  /// real trail geometry survives undo instead of collapsing back to a
  /// straight line. [_composePath] flattens this into `_trail.path`.
  final List<List<LatLng>> _segments = [];

  _Tool _tool = _Tool.draw;

  /// Mirrors `AuthorScreen._follow`: when on, drawing/moving/reconnecting
  /// snaps onto the nearest trail/road currently rendered and routes along
  /// real geometry; when off, points connect with a raw straight line.
  bool _followTrails = true;

  /// Anchor index picked in [_Tool.moveAnchor] mode, awaiting the click that
  /// places it — a simple click-then-click flow (mirrors the older tap-to-
  /// place flow `AuthorScreen._placeMovingAnchor` still supports) rather than
  /// a drag gesture, since there's no tappable/draggable native anchor
  /// annotation here (see the class doc).
  int? _pendingMoveAnchorIndex;

  /// The generation-boundary outline, built up one click at a time in
  /// [_Tool.drawBoundary] mode and drawn live via [_boundary] on every
  /// click. This is the *only* copy of the boundary — earlier this also had
  /// a separate "committed" `_genBoundary` set only by a "Finish boundary"
  /// button, but that meant a boundary that was fully drawn and visibly
  /// rendered on screen silently had zero effect on generation if the
  /// button wasn't clicked (confirmed live: the outline still looked
  /// finished, [TrailRouter.generate] just never got a `boundaryPolygon` and
  /// used the whole viewport instead). Treating whatever's currently drawn
  /// as the live boundary the moment it has ≥3 points removes that failure
  /// mode entirely — "Finish boundary" now just switches the tool back to
  /// drawing, it doesn't gate whether the outline counts.
  final List<LatLng> _boundaryPoints = [];

  bool get _hasBoundary => _boundaryPoints.length >= 3;

  /// Map-canvas-relative drag-in-progress trace for [_Tool.dragDraw] —
  /// mirrors `AuthorScreen._strokePoints`/`_onStrokePanStart`/`Update`/`End`,
  /// but stores real map-relative points (see [_mapPoint]/[PointerProbe])
  /// captured at event time rather than Flutter `Offset`s to be converted
  /// later.
  final List<Point<double>> _strokePoints = [];
  List<LatLng> _strokePreview = [];
  bool _convertingStrokePoint = false;
  bool _committingStroke = false;
  int _previewGeneration = 0;

  static const _strokePreviewColor = '#FF6D00';

  /// Minimum on-screen distance (px) between accepted drag points, and a
  /// hard cap on how many can accumulate — keeps a slow/jittery drag from
  /// ballooning the point count. Same values as
  /// `AuthorScreen._dragPointSpacing`/`_dragPointCap`.
  static const _dragPointSpacing = 6.0;
  static const _dragPointCap = 150;

  /// Real-anchor spacing (m) along a committed drag-draw stroke — see
  /// `AuthorScreen._strokeAnchorIntervalMeters`'s doc for why real,
  /// evenly-spaced anchors matter (real bend points for [_Tool.lineAdjust]
  /// to grab, not just the stroke's two endpoints).
  static const _strokeAnchorIntervalMeters = 25.0;

  /// Which segment/local-index of [_segments] is currently grabbed in
  /// [_Tool.lineAdjust] mode, or null when nothing's being dragged — mirrors
  /// `AuthorScreen._grabSegIdx`/`_grabLocalIdx`. Never an anchor (a
  /// segment's first/last point): those set [_draggingAnchorIndex] instead,
  /// checked first in [_onAdjustPanStart].
  int? _grabSegIdx;
  int? _grabLocalIdx;

  /// Snapshot of `_segments[_grabSegIdx]` taken the moment it was grabbed,
  /// and that vertex's pre-drag position — every preview/commit frame
  /// deforms fresh from this, never from an already-deformed array, so a
  /// wandering drag can't compound distortion. Mirrors
  /// `AuthorScreen._grabOriginalSeg`/`_grabOriginalPoint`.
  List<LatLng>? _grabOriginalSeg;
  LatLng? _grabOriginalPoint;

  /// Anchor index being free-dragged in [_Tool.lineAdjust] mode instead of
  /// the mid-line grab-and-bend above — mirrors
  /// `AuthorScreen._draggingAnchorIndex`.
  int? _draggingAnchorIndex;

  /// Real map-canvas-relative point (see [_mapPoint]) for the most recent
  /// [_Tool.lineAdjust] drag update — captured at event time, not derived
  /// later from a stale current pointer position.
  Point<double>? _lastAdjustPoint;
  bool _convertingAdjustPoint = false;

  /// How far a grab-and-bend edit reaches from the grabbed point, in metres
  /// of original-path distance, and the Gaussian falloff sigma for how much
  /// each point along that reach moves — identical tuning to
  /// `AuthorScreen._influenceRadiusMeters`/`_falloffSigmaMeters` (see that
  /// doc for the "0m→100%, ~5m→66%, ~15m→2%" fit this was tuned against).
  static const _influenceRadiusMeters = 20.0;
  static const _falloffSigmaMeters = 5.5;

  double _falloffWeight(double distanceMeters) {
    final d = distanceMeters;
    return exp(-(d * d) / (2 * _falloffSigmaMeters * _falloffSigmaMeters));
  }

  /// Max real-world gap (m) [_densify] allows between consecutive points of
  /// an editable segment — see that method's doc.
  static const _maxEditVertexGapMeters = 8.0;

  bool _busy = false;
  String? _status;

  /// True while a cue-editor/cue-list overlay is open — guards [_onMapClick]
  /// against a confirmed Flutter-Web platform-view issue: clicks meant for
  /// a modal (including its own Save/Cancel buttons) were also reaching
  /// MapLibre's canvas underneath, and with "Add cue" mode still active
  /// that immediately reopened another editor, making it look permanently
  /// stuck. The real fix was switching those overlays from a translucent
  /// `Dialog`/`showModalBottomSheet` to a full opaque `MaterialPageRoute`
  /// (see [showOpaqueDialog] — a `Dialog`'s barrier alone did *not* stop
  /// this, confirmed live, even though it's Flutter's normal modal-barrier
  /// mechanism), but this flag is kept as a second, unconditional guard —
  /// belt and suspenders against the same class of platform-view
  /// click-through for any future overlay added here.
  bool _modalOpen = false;

  Future<T?> _showModal<T>(Future<T?> Function() show) async {
    _modalOpen = true;
    try {
      return await show();
    } finally {
      if (mounted) _modalOpen = false;
    }
  }

  /// Snapshot stack for undo — identical shape and push-before-mutate
  /// discipline as `AuthorScreen._EditSnapshot`/`_pushUndo`/`_undo`. Mobile
  /// has no redo either; matched here rather than adding scope beyond that
  /// established pattern.
  final List<_EditSnapshot> _undoStack = [];
  static const _maxUndo = 30;

  @override
  void initState() {
    super.initState();
    PointerProbe.ensureStarted();
  }

  void _onMapCreated(MapLibreMapController c) => _c = c;

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null) return;
    _route = RouteLayer(c);
    await _route!.ensure();
    _points = CueLayer(c, id: 'designerPoints');
    await _points!.ensure();
    _boundary = BoundaryLayer(c);
    await _boundary!.ensure();
    _strokeLayer = RouteLayer(c, id: 'strokePreview', splitOutAndBack: false);
    await _strokeLayer!.ensure();
    await _redraw();
  }

  /// Flattens [_segments] into the full route polyline — identical to
  /// `AuthorScreen._composePath`.
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

  void _pushUndo() {
    _undoStack.add(_EditSnapshot(
      anchors: List.of(_trail.anchors),
      segments: [for (final s in _segments) List.of(s)],
      cues: [for (final c in _trail.cues) _cloneCue(c)],
    ));
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  static Cue _cloneCue(Cue c) => Cue(
        type: c.type,
        position: c.position,
        order: c.order,
        label: c.label,
        spoken: c.spoken,
        radiusMeters: c.radiusMeters,
      );

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    final snap = _undoStack.removeLast();
    setState(() {
      _trail.anchors
        ..clear()
        ..addAll(snap.anchors);
      _segments
        ..clear()
        ..addAll(snap.segments);
      _trail.cues
        ..clear()
        ..addAll(snap.cues);
      _trail.path = _composePath();
      _pendingMoveAnchorIndex = null;
    });
    await _redraw();
  }

  /// Nearest anchor to [p] within [maxMeters], or null — the desktop
  /// stand-in for a native tappable anchor marker (see the class doc).
  int? _nearestAnchorIndex(LatLng p, {double maxMeters = 20}) {
    var bestIdx = -1;
    var bestMeters = maxMeters;
    for (var i = 0; i < _trail.anchors.length; i++) {
      final d = metersBetween(p, _trail.anchors[i]);
      if (d < bestMeters) {
        bestMeters = d;
        bestIdx = i;
      }
    }
    return bestIdx < 0 ? null : bestIdx;
  }

  /// Nearest cue to [p] within [maxMeters], or null — same idea as
  /// [_nearestAnchorIndex], used so a click in [_Tool.addCue] mode on top of
  /// an existing cue opens *that* cue's editor (with Delete/"Add another")
  /// instead of always creating a brand-new one at the exact same spot.
  int? _nearestCueIndex(LatLng p, {double maxMeters = 15}) {
    var bestIdx = -1;
    var bestMeters = maxMeters;
    for (var i = 0; i < _trail.cues.length; i++) {
      final d = metersBetween(p, _trail.cues[i].position);
      if (d < bestMeters) {
        bestMeters = d;
        bestIdx = i;
      }
    }
    return bestIdx < 0 ? null : bestIdx;
  }

  Future<void> _onMapClick(Point<double> _, LatLng coords) async {
    final c = _c;
    if (c == null || _busy || _modalOpen) return;
    switch (_tool) {
      case _Tool.draw:
        await _addAnchor(coords);
      case _Tool.moveAnchor:
        await _handleMoveAnchorClick(coords);
      case _Tool.deleteAnchor:
        final idx = _nearestAnchorIndex(coords);
        if (idx != null) await _confirmDeleteAnchor(idx);
      case _Tool.addCue:
        // Snapped onto the trail, not the raw click — mirrors
        // AuthorScreen._placeMovingCue's default (non-"Free placement")
        // behaviour: a cue belongs on the trail it's guiding, not wherever
        // the mouse happened to land. Without this, a click even a few
        // metres off the line placed the cue there permanently, and a
        // later "Add another cue at this same spot" from a *different*
        // stray cue (found by the on-map hit-test, which only searches
        // within its own small radius) could easily land somewhere
        // visibly different rather than genuinely stacking — confirmed as
        // the likely cause of a real report of "stacked" cues scattering
        // to different, off-trail spots.
        final snapped =
            _trail.path.length >= 2 ? nearestPointOnPath(coords, _trail.path) : coords;
        final idx = _nearestCueIndex(snapped);
        if (idx != null) {
          await _editCue(_trail.cues[idx]);
        } else {
          await _addCueAt(snapped);
        }
      case _Tool.drawBoundary:
        setState(() => _boundaryPoints.add(coords));
        await _boundary?.setPolygon(_boundaryPoints);
      case _Tool.dragDraw:
      case _Tool.lineAdjust:
        // No-op: both tools draw via the full-screen GestureDetector
        // overlay's pan callbacks while active, not map clicks — the
        // overlay's HitTestBehavior.opaque means this callback shouldn't
        // even fire, but the switch must stay exhaustive regardless.
        break;
    }
  }

  /// Adds a trail anchor at [tap] — same connect()/between()-vs-straight
  /// logic as `AuthorScreen._addAnchor`.
  Future<void> _addAnchor(LatLng tap) async {
    final c = _c;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final from = _trail.anchors.isEmpty ? null : _trail.anchors.last;
      List<LatLng> segment;
      LatLng end;
      if (_followTrails) {
        final conn = await TrailRouter(c).connect(from: from, to: tap);
        end = conn.end;
        segment = conn.polyline;
      } else {
        end = tap;
        segment = from == null ? [tap] : [from, tap];
      }
      _pushUndo();
      setState(() {
        _trail.anchors.add(end);
        _segments.add(segment);
        _trail.path = _composePath();
      });
      await _redraw();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleMoveAnchorClick(LatLng coords) async {
    final pending = _pendingMoveAnchorIndex;
    if (pending == null) {
      final idx = _nearestAnchorIndex(coords);
      if (idx != null) setState(() => _pendingMoveAnchorIndex = idx);
      return;
    }
    _pushUndo();
    await _commitAnchorPosition(pending, coords);
    if (mounted) setState(() => _pendingMoveAnchorIndex = null);
  }

  /// Re-routes the segment(s) touching anchor [idx] to [pos] — mirrors
  /// `AuthorScreen._commitAnchorPosition`, plus one improvement: [pos] is
  /// first snapped onto the nearest trail/road edge (same `nearestOnEdge`
  /// snap `connect()` already applies when drawing a new point) before
  /// being stored or routed to. Without this, a drag that landed a few
  /// metres short of the intended trail left the anchor floating there
  /// permanently — `between()` alone has no snapping of its own, it just
  /// pathfinds between exactly the two points it's given, so an unsnapped
  /// drop produced an ugly straight "spur" off the real trail instead of
  /// the clean re-route the Adjust tool is meant to help fix a poorly
  /// drawn line into. Caller pushes undo beforehand.
  Future<void> _commitAnchorPosition(int idx, LatLng pos) async {
    final c = _c;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final router = TrailRouter(c);
      // The whole visible viewport, not a tight box around just the two
      // points being joined — [TrailRouter.between]'s doc explains why: a
      // real connecting trail that loops or bulges out from the straight
      // line between two widely-spaced anchors can fall entirely outside a
      // tight query box, making a genuinely connected trail look
      // disconnected and silently degrading to a straight-line "shortcut"
      // that visibly cuts across terrain.
      final rect = _followTrails ? await router.visibleViewportRect() : null;
      if (_followTrails) pos = await router.snapPoint(pos, rect: rect);
      var noRouteFound = false;
      final anchors = _trail.anchors;
      anchors[idx] = pos;
      if (idx > 0) {
        final prev = anchors[idx - 1];
        if (_followTrails) {
          final seg = await router.between(prev, pos, rect: rect);
          if (seg.length <= 2) noRouteFound = true;
          _segments[idx] = seg;
        } else {
          _segments[idx] = [prev, pos];
        }
      } else if (_segments.isNotEmpty) {
        _segments[0] = [pos];
      }
      if (idx < anchors.length - 1) {
        final next = anchors[idx + 1];
        if (_followTrails) {
          final seg = await router.between(pos, next, rect: rect);
          if (seg.length <= 2) noRouteFound = true;
          _segments[idx + 1] = seg;
        } else {
          _segments[idx + 1] = [pos, next];
        }
      }
      setState(() => _trail.path = _composePath());
      await _redraw();
      // Not proof there's genuinely no trail there (a very short real edge
      // can also legitimately be 2 points) — but worth a heads-up rather
      // than silently drawing what can look like a fabricated shortcut.
      if (noRouteFound) {
        _toast('No connected trail found here — drew a straight line instead');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Real map-canvas-relative point for the pointer event underlying [p] —
  /// see [PointerProbe]'s doc for why this, not Flutter's own [Offset], is
  /// what must be fed to `toLatLng`/`toScreenLocation` on web. Falls back to
  /// [p] itself if the probe hasn't found the canvas yet (shouldn't happen
  /// mid-drag in practice, but never worth crashing over).
  Point<double> _mapPoint(Offset p) {
    final probe = PointerProbe.mapRelativePosition();
    return probe == null ? Point(p.dx, p.dy) : Point(probe.x, probe.y);
  }

  /// Forwards mouse-wheel scroll straight to the camera while the drag-tool
  /// overlay is up — without this, scroll-zoom stopped working the moment
  /// either drag tool was turned on: [setMapDragLocked] sets
  /// `pointer-events: none` on the map's own canvas so it never sees the
  /// wheel event either, and a plain `GestureDetector` doesn't handle wheel
  /// input at all. Mirrors `AuthorScreen._DrawGestureSurface._onWheel`
  /// exactly (see the gotcha in that file's history: mobile hit the same
  /// "a full-screen capture overlay silently breaks the map's own wheel
  /// handling" bug when its drawing tools first shipped).
  void _onOverlayWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _c?.animateCamera(
        event.scrollDelta.dy < 0 ? CameraUpdate.zoomIn() : CameraUpdate.zoomOut());
  }

  /// True for the duration of a gesture that started as a camera-pan
  /// override (middle-mouse button, or Shift/Ctrl held) rather than a
  /// draw/adjust drag — decided once at [_onOverlayPointerDown] and held
  /// for the rest of that gesture, so switching modifier keys mid-drag
  /// can't flip behaviour underneath the user's finger.
  bool _overlayPanningCamera = false;
  Offset? _overlayPanLast;

  /// Replaces a plain `GestureDetector` for the drag-tool overlay so a
  /// gesture can be routed to camera-pan instead of drawing *before* it
  /// starts, based on which mouse button or modifier key was down at
  /// pointer-down — a `GestureDetector`'s pan callbacks don't expose either
  /// of those. Lets the user pan the map with the middle mouse button, or
  /// by holding Shift/Ctrl, without having to switch the tool off and back
  /// on just to reposition the view mid-edit.
  void _onOverlayPointerDown(PointerDownEvent e) {
    final panOverride = e.buttons == kMiddleMouseButton ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed;
    _overlayPanningCamera = panOverride;
    if (panOverride) {
      _overlayPanLast = e.localPosition;
      return;
    }
    if (_tool == _Tool.dragDraw) {
      _onStrokePanStart(e.localPosition);
    } else {
      _onAdjustPanStart(e.localPosition);
    }
  }

  void _onOverlayPointerMove(PointerMoveEvent e) {
    if (_overlayPanningCamera) {
      final last = _overlayPanLast;
      if (last != null) {
        final delta = e.localPosition - last;
        _c?.moveCamera(CameraUpdate.scrollBy(delta.dx, delta.dy));
      }
      _overlayPanLast = e.localPosition;
      return;
    }
    if (_tool == _Tool.dragDraw) {
      _onStrokePanUpdate(e.localPosition);
    } else {
      _onAdjustPanUpdate(e.localPosition);
    }
  }

  void _onOverlayPointerUp(PointerUpEvent e) {
    if (_overlayPanningCamera) {
      _overlayPanningCamera = false;
      _overlayPanLast = null;
      return;
    }
    if (_tool == _Tool.dragDraw) {
      _onStrokePanEnd();
    } else {
      _onAdjustPanEnd();
    }
  }

  void _onOverlayPointerCancel(PointerCancelEvent e) {
    if (_overlayPanningCamera) {
      _overlayPanningCamera = false;
      _overlayPanLast = null;
    }
  }

  void _onStrokePanStart(Offset p) {
    final mapped = _mapPoint(p);
    setState(() {
      _previewGeneration++;
      _strokePoints
        ..clear()
        ..add(mapped);
      _strokePreview = [];
    });
  }

  void _onStrokePanUpdate(Offset p) {
    final mapped = _mapPoint(p);
    if (_strokePoints.isNotEmpty &&
        (_strokePoints.length >= _dragPointCap ||
            _pointDistance(mapped, _strokePoints.last) < _dragPointSpacing)) {
      return;
    }
    setState(() => _strokePoints.add(mapped));
    _pushStrokePreview(mapped);
  }

  static double _pointDistance(Point<double> a, Point<double> b) {
    final dx = a.x - b.x, dy = a.y - b.y;
    return sqrt(dx * dx + dy * dy);
  }

  /// Best-effort live preview of the raw (unsnapped) drag — self-throttles
  /// (skips a point if a previous conversion is still in flight) rather
  /// than queueing, same as `AuthorScreen._pushStrokePreview`. Takes an
  /// already map-relative [p] (see [_mapPoint]) rather than converting
  /// itself, so every point in [_strokePoints] is captured in that space at
  /// the moment it happened, not re-derived later from a stale current
  /// pointer position.
  Future<void> _pushStrokePreview(Point<double> p) async {
    final c = _c;
    if (c == null || _convertingStrokePoint || !mounted) return;
    final gen = _previewGeneration;
    _convertingStrokePoint = true;
    try {
      final latlng = await c.toLatLng(p);
      if (!mounted || _tool != _Tool.dragDraw || gen != _previewGeneration) return;
      _strokePreview.add(latlng);
      if (_strokePreview.length >= 2) {
        await _strokeLayer?.setRoute(_strokePreview, _strokePreviewColor);
      }
    } finally {
      _convertingStrokePoint = false;
    }
  }

  /// Converts the finished drag into map points, then snaps the whole
  /// stroke onto the trail/road network as one pass — identical logic to
  /// `AuthorScreen._onStrokePanEnd` (see its doc for why `snapStroke`, not
  /// a per-point `snapPoint` loop, and why real anchors are dropped every
  /// [_strokeAnchorIntervalMeters] along it instead of just at the ends).
  Future<void> _onStrokePanEnd() async {
    final c = _c;
    final points = List<Point<double>>.of(_strokePoints);
    setState(() {
      _previewGeneration++;
      _strokePoints.clear();
      _strokePreview = [];
    });
    await _strokeLayer?.setRoute(const [], _strokePreviewColor);
    if (!mounted || c == null || points.length < 2 || _committingStroke) return;
    final minX = points.map((p) => p.x).reduce(min);
    final maxX = points.map((p) => p.x).reduce(max);
    final minY = points.map((p) => p.y).reduce(min);
    final maxY = points.map((p) => p.y).reduce(max);
    if (maxX - minX < 12 && maxY - minY < 12) return;

    setState(() => _committingStroke = true);
    try {
      final raw = await Future.wait(points.map((p) => c.toLatLng(p)));
      final simplified = simplifyPath(raw, 2.5);
      if (simplified.length < 2) return;
      final rawSnapped =
          _followTrails ? await TrailRouter(c).snapStroke(simplified, maxMeters: 50) : simplified;
      final snapped = <LatLng>[];
      for (final s in rawSnapped) {
        if (snapped.isEmpty || metersBetween(snapped.last, s) >= 3) {
          snapped.add(s);
        }
      }
      if (snapped.length < 2 || !mounted) return;
      _pushUndo();
      setState(() {
        if (_trail.anchors.isEmpty) {
          _trail.anchors.add(snapped.first);
          _segments.add([snapped.first]);
        } else if (metersBetween(_trail.anchors.last, snapped.first) > 3) {
          _trail.anchors.add(snapped.first);
          _segments.add([_trail.anchors[_trail.anchors.length - 2], snapped.first]);
        }
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
      });
      await _redraw();
    } finally {
      if (mounted) setState(() => _committingStroke = false);
    }
  }

  /// Inserts straight-line-interpolated points along [seg] wherever two
  /// consecutive points are more than [_maxEditVertexGapMeters] apart —
  /// identical to `AuthorScreen._densify`. Without this, a stretch of real
  /// trail data with few source vertices (a long straight OSM way) leaves
  /// [_Tool.lineAdjust] nothing to grab there except a distant existing
  /// vertex, forcing a correction to land away from the actual problem
  /// spot — confirmed the hard way on mobile before this was added there.
  /// Every inserted point sits exactly on the line between its two real
  /// neighbours, so this never changes the segment's shape, only how
  /// finely it can be grabbed.
  List<LatLng> _densify(List<LatLng> seg) {
    if (seg.length < 2) return seg;
    final out = <LatLng>[seg.first];
    for (var i = 1; i < seg.length; i++) {
      final a = seg[i - 1], b = seg[i];
      final gap = metersBetween(a, b);
      final steps =
          gap > _maxEditVertexGapMeters ? (gap / _maxEditVertexGapMeters).ceil() : 1;
      for (var s = 1; s <= steps; s++) {
        final t = s / steps;
        out.add(LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        ));
      }
    }
    return out;
  }

  /// Deforms [original] (a snapshot of a segment taken at grab time) by
  /// moving the vertex at [grabIndex] from [from] to [to], and moving its
  /// neighbours on each side by the same displacement scaled down with
  /// distance — like bending a flexible wire at one point. Identical to
  /// `AuthorScreen._deformSegment`: always computes from [original], never
  /// from an already-deformed array, so repeated calls during one drag
  /// never compound distortion, and stops at each direction's first/last
  /// index (the segment's own anchors) even if [_influenceRadiusMeters]
  /// would otherwise reach further, so an anchor shared with the
  /// neighbouring segment never moves here.
  List<LatLng> _deformSegment(
      List<LatLng> original, int grabIndex, LatLng from, LatLng to) {
    final dLat = to.latitude - from.latitude;
    final dLng = to.longitude - from.longitude;
    final out = List<LatLng>.of(original);

    var traveled = 0.0;
    for (var i = grabIndex; i < original.length - 1; i++) {
      if (i > grabIndex) traveled += metersBetween(original[i - 1], original[i]);
      if (traveled > _influenceRadiusMeters) break;
      final w = _falloffWeight(traveled);
      out[i] =
          LatLng(original[i].latitude + dLat * w, original[i].longitude + dLng * w);
    }

    traveled = 0.0;
    for (var i = grabIndex - 1; i > 0; i--) {
      traveled += metersBetween(original[i + 1], original[i]);
      if (traveled > _influenceRadiusMeters) break;
      final w = _falloffWeight(traveled);
      out[i] =
          LatLng(original[i].latitude + dLat * w, original[i].longitude + dLng * w);
    }

    return out;
  }

  /// Grabs the line for [_Tool.lineAdjust]: finds the nearest point lying ON
  /// any segment's dense polyline (not just an existing vertex) within
  /// reach of [p], splicing a new vertex in at that exact spot if it falls
  /// strictly between two existing ones, so a drag can start truly anywhere
  /// along the line. Mirrors `AuthorScreen._onAdjustPanStart`: anchors are
  /// checked first (freely draggable here too, taking priority over the
  /// mid-line search) and a hit too close to a segment's own anchor is
  /// skipped, since that endpoint is shared with the neighbouring segment.
  Future<void> _onAdjustPanStart(Offset p) async {
    final c = _c;
    if (c == null) return;
    final gen = ++_previewGeneration;
    final mapped = _mapPoint(p);
    final screenX = mapped.x, screenY = mapped.y;
    final latlng = await c.toLatLng(mapped);
    if (!mounted || _tool != _Tool.lineAdjust || gen != _previewGeneration) return;

    final anchors = _trail.anchors;
    var bestAnchor = -1;
    var bestAnchorPx = 34.0;
    for (var i = 0; i < anchors.length; i++) {
      final sp = await c.toScreenLocation(anchors[i]);
      final dx = sp.x.toDouble() - screenX;
      final dy = sp.y.toDouble() - screenY;
      final px = sqrt(dx * dx + dy * dy);
      if (px < bestAnchorPx) {
        bestAnchorPx = px;
        bestAnchor = i;
      }
    }
    if (!mounted || _tool != _Tool.lineAdjust || gen != _previewGeneration) return;
    if (bestAnchor >= 0) {
      _pushUndo();
      setState(() {
        _grabSegIdx = null;
        _grabLocalIdx = null;
        _grabOriginalSeg = null;
        _grabOriginalPoint = null;
        _draggingAnchorIndex = bestAnchor;
      });
      return;
    }

    int? bestSeg, bestEdge;
    LatLng? bestPoint;
    var bestDist = 15.0;
    for (var s = 0; s < _segments.length; s++) {
      final seg = _densify(_segments[s]);
      final hit = nearestPointOnPolyline(latlng, seg, maxMeters: bestDist);
      if (hit == null) continue;
      if (metersBetween(hit.point, seg.first) < 2 ||
          metersBetween(hit.point, seg.last) < 2) {
        continue;
      }
      _segments[s] = seg;
      bestSeg = s;
      bestEdge = hit.edgeIndex;
      bestPoint = hit.point;
      bestDist = hit.meters;
    }

    if (bestSeg == null || bestEdge == null || bestPoint == null) {
      setState(() {
        _grabSegIdx = null;
        _grabLocalIdx = null;
        _grabOriginalSeg = null;
        _grabOriginalPoint = null;
      });
      return;
    }

    final winningSeg = bestSeg, edge = bestEdge, point = bestPoint;
    _pushUndo();
    setState(() {
      final seg = _segments[winningSeg];
      int grabIdx;
      if (metersBetween(point, seg[edge]) < 0.5) {
        grabIdx = edge;
      } else if (metersBetween(point, seg[edge + 1]) < 0.5) {
        grabIdx = edge + 1;
      } else {
        seg.insert(edge + 1, point);
        grabIdx = edge + 1;
      }
      _grabSegIdx = winningSeg;
      _grabLocalIdx = grabIdx;
      _grabOriginalSeg = List.of(seg);
      _grabOriginalPoint = seg[grabIdx];
    });
  }

  void _onAdjustPanUpdate(Offset p) {
    final mapped = _mapPoint(p);
    _lastAdjustPoint = mapped;
    if (_draggingAnchorIndex != null) {
      _pushAnchorDragPreview(mapped);
    } else {
      _pushAdjustPreview(mapped);
    }
  }

  /// Live preview for a free-dragged anchor ([_draggingAnchorIndex]): a
  /// cheap straight-line stretch to its immediate neighbours, not a live
  /// re-route — matches how [_handleMoveAnchorClick]'s click-then-click flow
  /// also only re-routes once, on commit. Mirrors
  /// `AuthorScreen._pushAnchorDragPreview` (minus the live-moving marker
  /// circle: this screen's anchor markers are plain non-interactive
  /// GeoJSON, redrawn wholesale by [_redraw] on commit, same as every other
  /// anchor edit here already does).
  Future<void> _pushAnchorDragPreview(Point<double> p) async {
    final c = _c;
    final idx = _draggingAnchorIndex;
    if (c == null || idx == null || _convertingAdjustPoint || !mounted) return;
    final gen = _previewGeneration;
    _convertingAdjustPoint = true;
    try {
      final latlng = await c.toLatLng(p);
      if (!mounted ||
          _tool != _Tool.lineAdjust ||
          _draggingAnchorIndex != idx ||
          gen != _previewGeneration) {
        return;
      }
      final anchors = _trail.anchors;
      final preview = [
        if (idx > 0) anchors[idx - 1],
        latlng,
        if (idx < anchors.length - 1) anchors[idx + 1],
      ];
      await _strokeLayer?.setRoute(preview, _strokePreviewColor);
    } finally {
      _convertingAdjustPoint = false;
    }
  }

  /// Live preview of the wire-bend: deforms fresh from [_grabOriginalSeg]
  /// toward the current drag position and pushes the whole result to
  /// [_strokeLayer]. Pure on-screen geometry — no trail lookup happens
  /// here, so nothing about the surrounding trail can be implied or
  /// affected while dragging. Mirrors `AuthorScreen._pushAdjustPreview`.
  Future<void> _pushAdjustPreview(Point<double> p) async {
    final c = _c;
    final segIdx = _grabSegIdx,
        original = _grabOriginalSeg,
        grabIdx = _grabLocalIdx,
        grabOriginal = _grabOriginalPoint;
    if (c == null ||
        segIdx == null ||
        original == null ||
        grabIdx == null ||
        grabOriginal == null ||
        _convertingAdjustPoint ||
        !mounted) {
      return;
    }
    final gen = _previewGeneration;
    _convertingAdjustPoint = true;
    try {
      final latlng = await c.toLatLng(p);
      if (!mounted ||
          _tool != _Tool.lineAdjust ||
          _grabSegIdx != segIdx ||
          gen != _previewGeneration) {
        return;
      }
      final deformed = _deformSegment(original, grabIdx, grabOriginal, latlng);
      await _strokeLayer?.setRoute(deformed, _strokePreviewColor);
    } finally {
      _convertingAdjustPoint = false;
    }
  }

  /// Commits the grab: deforms [_grabOriginalSeg] one final time toward the
  /// drop position and writes the result into [_segments], or (for a
  /// free-dragged anchor) re-routes via [_commitAnchorPosition] exactly
  /// like the click-then-click move tool does. Mirrors
  /// `AuthorScreen._onAdjustPanEnd`.
  Future<void> _onAdjustPanEnd() async {
    final c = _c;
    final draggingAnchor = _draggingAnchorIndex;
    final segIdx = _grabSegIdx,
        original = _grabOriginalSeg,
        grabIdx = _grabLocalIdx,
        grabOriginal = _grabOriginalPoint;
    final point = _lastAdjustPoint;
    setState(() {
      _previewGeneration++;
      _grabSegIdx = null;
      _grabLocalIdx = null;
      _grabOriginalSeg = null;
      _grabOriginalPoint = null;
      _draggingAnchorIndex = null;
      _lastAdjustPoint = null;
    });
    await _strokeLayer?.setRoute(const [], _strokePreviewColor);
    if (!mounted || c == null || point == null) return;

    final newPos = await c.toLatLng(point);
    if (!mounted) return;

    if (draggingAnchor != null) {
      await _commitAnchorPosition(draggingAnchor, newPos);
      return;
    }

    if (segIdx == null || original == null || grabIdx == null || grabOriginal == null) {
      return;
    }
    // Snap the drop point onto the nearest trail/road edge before bending
    // toward it — the same improvement [_commitAnchorPosition] got, applied
    // here too: without it, a mid-line grab-and-bend was purely geometric
    // (matching `AuthorScreen`'s deliberately non-snapping wire-bend) and
    // never actually pulled the line onto nearby trail data, only wherever
    // the mouse released.
    final snapped =
        _followTrails ? await TrailRouter(c).snapPoint(newPos) : newPos;
    final deformed = _deformSegment(original, grabIdx, grabOriginal, snapped);
    setState(() {
      _segments[segIdx] = deformed;
      _trail.path = _composePath();
    });
    await _redraw();
  }

  Future<void> _confirmDeleteAnchor(int i) async {
    if (!await _confirm('Delete this point?')) return;
    await _deleteAnchor(i);
  }

  /// Deletes anchor [i], re-joining its neighbours — identical to
  /// `AuthorScreen._deleteAnchor`.
  Future<void> _deleteAnchor(int i) async {
    final anchors = _trail.anchors;
    if (i < 0 || i >= anchors.length) return;
    final c = _c;
    _pushUndo();
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
        final prev = anchors[i - 1], next = anchors[i + 1];
        anchors.removeAt(i);
        _segments.removeAt(i); // old seg i (prev -> deleted)
        _segments.removeAt(i); // old seg i+1 (deleted -> next)
        final seg = (_followTrails && c != null)
            ? await TrailRouter(c).between(prev, next)
            : [prev, next];
        _segments.insert(i, seg);
      }
      setState(() => _trail.path = _composePath());
      await _redraw();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int get _nextCueOrder => _trail.cues.isEmpty
      ? 0
      : _trail.cues.map((c) => c.order).reduce((a, b) => a > b ? a : b) + 1;

  void _insertCueAtOrder(Cue cue) {
    for (final c in _trail.cues) {
      if (c.order >= cue.order) c.order++;
    }
    _trail.cues.add(cue);
  }

  Future<void> _addCueAt(LatLng position) async {
    final cue = await _showModal(() => showCueEditor(context,
        position: position, initialOrder: _nextCueOrder, asDialog: true));
    if (cue == null || !mounted) return;
    _pushUndo();
    setState(() => _insertCueAtOrder(cue));
    await _redraw();
  }

  /// Edits [cue] — identical logic to `AuthorScreen._editCue`.
  Future<void> _editCue(Cue cue) async {
    final currentRank =
        (List.of(_trail.cues)..sort((a, b) => a.order.compareTo(b.order)))
            .indexOf(cue);
    final result = await _showModal(() => showCueEditor(context,
        position: cue.position,
        existing: cue,
        initialOrder: currentRank,
        asDialog: true));
    if (!mounted) return;
    if (result == deletedCueSentinel) {
      _pushUndo();
      setState(() => _trail.cues.remove(cue));
    } else if (result == addAnotherCueSentinel) {
      final another = await _showModal(() => showCueEditor(context,
          position: cue.position, initialOrder: _nextCueOrder, asDialog: true));
      if (!mounted || another == null) return;
      _pushUndo();
      setState(() => _insertCueAtOrder(another));
      await _redraw();
      return;
    } else if (result != null) {
      _pushUndo();
      setState(() {
        cue
          ..type = result.type
          ..label = result.label
          ..spoken = result.spoken
          ..radiusMeters = result.radiusMeters;
        if (result.order != currentRank) _trail.reorderCue(cue, result.order);
      });
    } else {
      return;
    }
    await _redraw();
  }

  /// Lists every cue with an Edit action — the desktop stand-in for tapping
  /// an on-map cue marker directly (see the class doc).
  Future<void> _showCueList() async {
    final sorted = List<Cue>.of(_trail.cues)
      ..sort((a, b) => a.order.compareTo(b.order));
    await _showModal(() => showOpaqueDialog<void>(
          context,
          maxHeight: 560,
          builder: (ctx) => AlertDialog(
            title: const Text('Cues'),
            content: SizedBox(
              width: 420,
              // A fixed height (not shrinkWrap) so a long cue list scrolls
              // internally instead of trying to grow past what the dialog
              // was given — the same silent-overflow risk fixed in
              // _pickColor, just with a variable-length list instead of a
              // fixed grid.
              height: 360,
              child: sorted.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No cues yet — use "Add cue" or "Suggest cues".'),
                    )
                  : ListView.builder(
                      itemCount: sorted.length,
                      itemBuilder: (ctx, i) {
                        final cue = sorted[i];
                        return ListTile(
                          leading: CircleAvatar(child: Text('${i + 1}')),
                          title: Text(cue.label),
                          subtitle: Text(cue.type.label),
                          trailing: IconButton(
                            tooltip: 'Edit cue',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              await _editCue(cue);
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            ],
          ),
        ));
  }

  /// Metres a stacked marker's *rendered* position is nudged north of its
  /// real one, per line already stacked at ~the same spot — an anchor and a
  /// cue (or two cues) at the same point is common (a "Start"/"Finish" cue
  /// almost always sits exactly on the first/last anchor), and without this
  /// their circles/labels painted at the identical coordinate overlap into
  /// illegible interleaved text (confirmed live — "Start" over anchor "1"
  /// rendered as garbled "1"/"Start" character soup). Mirrors the idea in
  /// `GuideScreen._drawCues`'s stacked-cue nudging: offset the geometry
  /// itself, since a data-driven `text-offset` isn't reliably supported by
  /// this map/style combination (see `cue_layer.dart`'s own doc on that).
  static const _stackLineMeters = 6.0;
  static const _stackClusterMeters = 3.0;

  /// Real (unnudged) positions seen so far this redraw, parallel-indexed
  /// with how many markers have already claimed each — reset per redraw.
  final List<LatLng> _stackAnchors = [];
  final List<int> _stackCounts = [];

  /// Returns [pos] nudged north by however many earlier markers this redraw
  /// already claimed a spot within [_stackClusterMeters] of it (0 for the
  /// first marker at a given spot, i.e. unmoved).
  LatLng _stackedPosition(LatLng pos) {
    for (var i = 0; i < _stackAnchors.length; i++) {
      if (metersBetween(_stackAnchors[i], pos) < _stackClusterMeters) {
        final line = ++_stackCounts[i];
        final dLat = (_stackLineMeters * line) / 111320.0;
        return LatLng(pos.latitude + dLat, pos.longitude);
      }
    }
    _stackAnchors.add(pos);
    _stackCounts.add(0);
    return pos;
  }

  Future<void> _redraw() async {
    await _route?.setRoute(_trail.path, _trail.color);
    _stackAnchors.clear();
    _stackCounts.clear();

    final markers = <CueMarker>[
      for (var i = 0; i < _trail.anchors.length; i++)
        CueMarker(
          position: _stackedPosition(_trail.anchors[i]),
          radius: i == _pendingMoveAnchorIndex ? 9 : 7,
          color: i == _pendingMoveAnchorIndex ? '#EF6C00' : '#1565C0',
          strokeWidth: 2,
          text: '${i + 1}',
          textColor: '#1A1A1A',
        ),
    ];

    // Group cues that share (almost) the same spot so they render as one
    // merged marker (a distinct stacked colour) with every cue there listed
    // on its own text line, instead of splitting into separate, overlapping
    // dots — mirrors `AuthorScreen._cueDisplayInfo`/`GuideScreen._drawCues`
    // exactly, including the merge distance (7m, matched to
    // `cue_gen.dart`'s own `cueMergeMeters` default so this display grouping
    // agrees with what auto-generated cues already consider "the same
    // spot").
    final sorted = List<Cue>.of(_trail.cues)..sort((a, b) => a.order.compareTo(b.order));
    final rank = <Cue, int>{for (var i = 0; i < sorted.length; i++) sorted[i]: i + 1};
    final groups = <List<Cue>>[];
    for (final cue in _trail.cues) {
      final match =
          groups.where((g) => metersBetween(g.first.position, cue.position) < 7.0);
      if (match.isNotEmpty) {
        match.first.add(cue);
      } else {
        groups.add([cue]);
      }
    }

    for (final group in groups) {
      final stacked = group.length > 1;
      if (stacked) {
        group.sort((a, b) => (rank[a] ?? 0).compareTo(rank[b] ?? 0));
      }
      final pos = _stackedPosition(group.first.position);
      final color = stacked ? stackedCueColorHex : cueColorHex(group.first.type);
      // Every cue in the group sits at the *exact same* position — vertical
      // separation between stacked lines is done by [CueLayer] itself, via
      // one fixed-offset style layer per [CueMarker.lineIndex] (see that
      // class's doc). A geographic nudge here (what this used to do)
      // necessarily looks bigger zoomed in and smaller zoomed out, since
      // it's a real-world distance — confirmed live (2026-08-22): stacked
      // text squished together zoomed out and spread apart zoomed in, no
      // matter how the metre gap was computed. The style-layer offset is
      // genuinely zoom-independent instead.
      for (var i = 0; i < group.length; i++) {
        final cue = group[i];
        // Every group member past the first is meant to be a text-only line
        // (radius 0) — but on this map/style combination, a *stroked*
        // circle of radius 0 still paints a small solid dot the size of the
        // stroke width instead of nothing at all (confirmed live: this was
        // the real cause of "extra dots" appearing below a merged cue
        // marker, not a grouping failure — the group itself was already
        // merging correctly). Zeroing strokeWidth for i>0 too, not just
        // radius, is what actually makes it invisible.
        final isPrimary = i == 0;
        markers.add(CueMarker(
          position: pos,
          radius: isPrimary ? (stacked ? 13 : 11) : 0,
          color: color,
          strokeWidth: isPrimary ? (stacked ? 4 : 3) : 0,
          text: '${rank[cue] ?? "–"}. ${cue.label}',
          textColor: '#1A1A1A',
          lineIndex: i,
        ));
      }
    }

    await _points?.setMarkers(markers);
    if (mounted) {
      setState(() => _status =
          '${_trail.anchors.length} points · ${(pathLength(_trail.path) / 1000).toStringAsFixed(2)} km');
    }
  }

  Future<void> _newTrail() async {
    setState(() {
      _trail = Trail(name: 'New trail', regionId: 'web-design');
      _segments.clear();
      _undoStack.clear();
      _pendingMoveAnchorIndex = null;
      _boundaryPoints.clear();
    });
    await _boundary?.setPolygon(null);
    await _redraw();
  }

  /// Splits an opened trail's saved [path] back into per-anchor segments
  /// (so routed geometry survives undo after opening a file) — same idea
  /// as `AuthorScreen._rebuildSegments`, without that method's extra
  /// `_densify` step, which desktop has no deforming/grab-and-bend tool to
  /// need. Legacy trails with no separate `anchors` treat every path point
  /// as its own anchor.
  List<List<LatLng>> _rebuildSegments(List<LatLng> path, List<LatLng> anchors) {
    if (path.isEmpty) return [];
    final marks = anchors.isNotEmpty ? anchors : path;
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

  Future<void> _autoCues() async {
    if (_trail.path.length < 2) return;
    _pushUndo();
    setState(() => _trail.cues = suggestCues(_trail.path));
    await _redraw();
  }

  Future<void> _open() async {
    final opened = await WebTrailIo.open();
    if (opened == null || !mounted) return;
    setState(() {
      _trail = opened;
      _segments
        ..clear()
        ..addAll(_rebuildSegments(_trail.path, _trail.anchors));
      _undoStack.clear();
      _pendingMoveAnchorIndex = null;
      _boundaryPoints.clear();
    });
    await _boundary?.setPolygon(null);
    await _redraw();
  }

  void _save() => WebTrailIo.save(_trail);

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<bool> _confirm(String title) async {
    final ok = await _showModal(() => showOpaqueDialog<bool>(
          context,
          maxHeight: 200,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('OK')),
            ],
          ),
        ));
    return ok ?? false;
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _trail.name);
    final name = await _showModal(() => showOpaqueDialog<String>(
          context,
          maxHeight: 220,
          builder: (ctx) => AlertDialog(
            title: const Text('Trail name'),
            content: TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'e.g. River Loop'),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('OK')),
            ],
          ),
        ));
    if (name != null && name.isNotEmpty) {
      setState(() => _trail.name = name);
    }
  }

  static Color _hexColor(String h) =>
      Color(int.parse(h.substring(1), radix: 16) | 0xFF000000);

  Future<void> _pickColor() async {
    final picked = await _showModal(() => showOpaqueDialog<String>(
          context,
          // AlertDialog doesn't scroll its own content, so this needs to be
          // tall enough for the whole (fixed, small) swatch grid up front —
          // 260 was too short, silently causing the bottom row to overflow
          // past the dialog's Material and become unclickable even though
          // it kept painting (confirmed live).
          maxHeight: 420,
          builder: (ctx) => AlertDialog(
            title: const Text('Trail colour'),
            content: Wrap(
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
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            ],
          ),
        ));
    if (picked != null) {
      setState(() => _trail.color = picked);
      await _redraw();
    }
  }

  Future<void> _clearPath() async {
    if (_trail.anchors.isEmpty) return;
    if (!await _confirm('Clear the whole path?')) return;
    _pushUndo();
    setState(() {
      _trail.anchors.clear();
      _segments.clear();
      _trail.path = [];
    });
    await _redraw();
  }

  Future<void> _clearCuesOnly() async {
    if (_trail.cues.isEmpty) return;
    if (!await _confirm('Delete all cues?')) return;
    _pushUndo();
    setState(() => _trail.cues.clear());
    await _redraw();
  }

  Future<void> _clearAll() async {
    if (_trail.anchors.isEmpty && _trail.cues.isEmpty) return;
    if (!await _confirm('Clear the path and all cues?')) return;
    _pushUndo();
    setState(() {
      _trail.anchors.clear();
      _segments.clear();
      _trail.path = [];
      _trail.cues.clear();
    });
    await _redraw();
  }

  Future<void> _finishBoundary() async {
    if (!_hasBoundary) {
      _toast('Click at least 3 points to outline an area');
      return;
    }
    setState(() => _tool = _Tool.draw);
  }

  Future<void> _cancelBoundary() async {
    setState(() {
      _boundaryPoints.clear();
      _tool = _Tool.draw;
    });
    await _boundary?.setPolygon(null);
  }

  Future<void> _clearGenBoundary() async {
    setState(() => _boundaryPoints.clear());
    await _boundary?.setPolygon(null);
  }

  /// Opens the auto-generate dialog and, if a choice is made, generates —
  /// mirrors `AuthorScreen._openGenerator`.
  Future<void> _openGenerator() async {
    final choice = await _showModal(() => showOpaqueDialog<_GenChoice>(
          context,
          maxHeight: 620,
          builder: (_) => _GeneratorDialog(hasBoundary: _hasBoundary),
        ));
    if (choice == null || !mounted) return;
    if (_trail.anchors.isNotEmpty &&
        !await _confirm('Replace the current path with a generated one?')) {
      return;
    }
    await _generateRoute(choice);
  }

  /// Generates a route via [TrailRouter.generate] — mirrors
  /// `AuthorScreen._generateRoute`.
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
      final boundary = _hasBoundary ? List<LatLng>.of(_boundaryPoints) : null;
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
      final viewport = await router.visibleViewportRect();
      final route = await router.generate(
        center: center,
        viewport: viewport,
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
      final junctions =
          choice.cues ? await router.junctionsNear(route.path, viewport) : const <LatLng>[];
      if (!mounted) return;
      _pushUndo();
      setState(() {
        _trail.path = route.path;
        _segments
          ..clear()
          ..addAll(_rebuildSegments(route.path, route.anchors));
        if (choice.cues) {
          _trail.cues
            ..clear()
            ..addAll(suggestCues(route.path, junctions: junctions));
        }
        if (boundary != null) _boundaryPoints.clear();
      });
      if (boundary != null) await _boundary?.setPolygon(null);
      await _redraw();
      final dist = Settings.instance.formatDistance(route.meters);
      final cueNote = choice.cues ? ' · ${_trail.cues.length} cues' : '';
      final shortfall = route.meters < choice.meters * 0.7;
      final note = shortfall
          ? ' — that\'s all the trail this area has room for, even with some doubling back'
          : route.surfaceFallback
              ? ' — not enough ${choice.surface == Surface.trails ? "trail" : "road"} '
                  'here, so this mixes in the other surface too'
              : '';
      _toast('${route.loop ? "Loop" : "Out-and-back"} generated — $dist$cueNote$note');
    } catch (_) {
      if (mounted) _toast('Could not generate a route here — try another spot');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _toolHint() => switch (_tool) {
        _Tool.draw => 'Click the map to add a point.',
        _Tool.moveAnchor => _pendingMoveAnchorIndex == null
            ? 'Click an existing point to pick it up.'
            : 'Click where it should go.',
        _Tool.deleteAnchor => 'Click a point to delete it.',
        _Tool.addCue => 'Click the map to place a cue there.',
        _Tool.drawBoundary =>
          'Click each corner of the area, then "Finish boundary" (${_boundaryPoints.length} so far).',
        _Tool.dragDraw => 'Click and drag to trace a trail freehand. '
            'Middle-click-drag, or hold Shift/Ctrl and drag, to pan the map instead.',
        _Tool.lineAdjust =>
          'Drag a point on the line to bend it, or drag a marked point to move it. '
              'Middle-click-drag, or hold Shift/Ctrl and drag, to pan the map instead.',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _rename,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(_trail.name, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              const Icon(Icons.edit, size: 16),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'New trail',
            icon: const Icon(Icons.insert_drive_file_outlined),
            onPressed: _newTrail,
          ),
          IconButton(
            tooltip: 'Open .trail file',
            icon: const Icon(Icons.folder_open),
            onPressed: _open,
          ),
          IconButton(
            tooltip: 'Save as .trail file',
            icon: const Icon(Icons.save_outlined),
            onPressed: _save,
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: _undoStack.isEmpty ? null : _undo,
          ),
          IconButton(
            tooltip: 'Trail colour',
            icon: Icon(Icons.circle, color: _hexColor(_trail.color)),
            onPressed: _pickColor,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'clearPath', child: Text('Clear path')),
              const PopupMenuItem(value: 'clearCues', child: Text('Clear all cues')),
              const PopupMenuItem(value: 'clearAll', child: Text('Clear everything')),
              if (_hasBoundary)
                const PopupMenuItem(
                    value: 'clearBoundary', child: Text('Clear generation boundary')),
            ],
            onSelected: (v) => switch (v) {
              'clearPath' => _clearPath(),
              'clearCues' => _clearCuesOnly(),
              'clearAll' => _clearAll(),
              'clearBoundary' => _clearGenBoundary(),
              _ => null,
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Suggest turn cues',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _autoCues,
          ),
          IconButton(
            tooltip: 'Manage cues',
            icon: const Icon(Icons.list_alt_outlined),
            onPressed: _showCueList,
          ),
          IconButton(
            tooltip: 'Auto-generate a route',
            icon: const Icon(Icons.route_outlined),
            onPressed: _openGenerator,
          ),
          const SizedBox(width: 8),
          SegmentedButton<_Tool>(
            segments: const [
              ButtonSegment(
                  value: _Tool.draw, icon: Icon(Icons.edit), label: Text('Draw')),
              ButtonSegment(
                  value: _Tool.moveAnchor,
                  icon: Icon(Icons.open_with),
                  label: Text('Move')),
              ButtonSegment(
                  value: _Tool.deleteAnchor,
                  icon: Icon(Icons.remove_circle_outline),
                  label: Text('Delete')),
              ButtonSegment(
                  value: _Tool.addCue,
                  icon: Icon(Icons.add_location_alt_outlined),
                  label: Text('Add cue')),
              ButtonSegment(
                  value: _Tool.drawBoundary,
                  icon: Icon(Icons.crop_free),
                  label: Text('Boundary')),
              ButtonSegment(
                  value: _Tool.dragDraw,
                  icon: Icon(Icons.gesture),
                  label: Text('Freehand')),
              ButtonSegment(
                  value: _Tool.lineAdjust,
                  icon: Icon(Icons.polyline_outlined),
                  label: Text('Adjust')),
            ],
            selected: {_tool},
            onSelectionChanged: (s) {
              final next = s.first;
              final wasCapturing =
                  _tool == _Tool.dragDraw || _tool == _Tool.lineAdjust;
              final willCapture =
                  next == _Tool.dragDraw || next == _Tool.lineAdjust;
              if (wasCapturing != willCapture) setMapDragLocked(willCapture);
              setState(() {
                _tool = next;
                _pendingMoveAnchorIndex = null;
              });
            },
          ),
          if (_tool == _Tool.drawBoundary) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: _finishBoundary, child: const Text('Finish boundary')),
            TextButton(onPressed: _cancelBoundary, child: const Text('Cancel')),
          ],
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Follow trails'),
            tooltip: 'Snap clicks onto trails/roads and route between them',
            selected: _followTrails,
            onSelected: (v) => setState(() => _followTrails = v),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: FutureBuilder<String>(
        future: buildWebMapStyle(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Map load error:\n${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Stack(
            children: [
              MapLibreMap(
                styleString: snap.data!,
                initialCameraPosition: _initialCamera,
                onMapCreated: _onMapCreated,
                onStyleLoadedCallback: _onStyleLoaded,
                onMapClick: _onMapClick,
                compassEnabled: true,
              ),
              if (_tool == _Tool.dragDraw || _tool == _Tool.lineAdjust)
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: _onOverlayWheel,
                    onPointerDown: _onOverlayPointerDown,
                    onPointerMove: _onOverlayPointerMove,
                    onPointerUp: _onOverlayPointerUp,
                    onPointerCancel: _onOverlayPointerCancel,
                  ),
                ),
              Positioned(
                left: 16,
                bottom: 16,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_toolHint(),
                            style: const TextStyle(
                                fontSize: 13, fontStyle: FontStyle.italic)),
                        if (_status != null)
                          Text(_status!, style: const TextStyle(fontSize: 15)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A restore point for [_DesktopDesignerScreenState._undo] — identical shape
/// to `AuthorScreen`'s private `_EditSnapshot`.
class _EditSnapshot {
  const _EditSnapshot(
      {required this.anchors, required this.segments, required this.cues});
  final List<LatLng> anchors;
  final List<List<LatLng>> segments;
  final List<Cue> cues;
}

/// A chosen target length + shape for auto-generation — mirrors
/// `AuthorScreen`'s private `_GenChoice`.
class _GenChoice {
  const _GenChoice(this.meters, this.loop, this.cues, this.surface);
  final double meters;
  final bool loop;
  final bool cues;
  final Surface surface;
}

/// Length/shape/surface picker for auto-generation — content mirrors
/// `AuthorScreen._GeneratorSheet` closely, shown via [showOpaqueDialog]
/// instead of a bottom sheet.
class _GeneratorDialog extends StatefulWidget {
  const _GeneratorDialog({required this.hasBoundary});
  final bool hasBoundary;

  @override
  State<_GeneratorDialog> createState() => _GeneratorDialogState();
}

class _GeneratorDialogState extends State<_GeneratorDialog> {
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
    return Column(
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
                    Text(s.formatDistance(_meters),
                        style: text.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _meters,
                  min: _minMeters,
                  max: _maxMeters,
                  divisions: 58,
                  label: s.formatDistance(_meters),
                  onChanged: (v) => setState(() => _meters = v),
                ),
                const SizedBox(height: 8),
                Text('Shape', style: text.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: true, icon: Icon(Icons.loop), label: Text('Loop')),
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
                  onSelectionChanged: (s) => setState(() => _surface = s.first),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _cues,
                  title: const Text('Add turn directions'),
                  onChanged: (v) => setState(() => _cues = v ?? true),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(
                    context, _GenChoice(_meters, _loop, _cues, _surface)),
                child: const Text('Generate'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
