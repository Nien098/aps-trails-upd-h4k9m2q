import 'dart:async' show Timer, unawaited;
import 'dart:math' show Point, exp, max, min, sqrt;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../cue_style.dart';
import '../models/trail.dart';
import '../services/boundary_layer.dart';
import '../services/cue_gen.dart';
import '../services/cue_layer.dart';
import '../services/debug_log.dart';
import '../services/geo.dart';
import '../services/map_drag_lock.dart';
import '../services/pointer_probe.dart';
import '../services/route_graph_store.dart';
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

  /// "You're holding this" marker shown at the live cursor position during
  /// an anchor/cue drag — see [_DragGhostLayer]'s doc.
  _DragGhostLayer? _dragGhost;

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

  /// Whether the diagnostics panel (see the bug-icon toolbar button) is
  /// open. Toggling this also flips [DebugLog.enabled] — logging only runs
  /// while someone's actually watching, so it costs nothing the rest of the
  /// time.
  bool _debugPanelOpen = false;


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
  /// `AuthorScreen._draggingAnchorIndex`. Also set by [_onMovePanStart] for
  /// the Move tool/Ctrl-drag's own anchor-drag — see [_anchorDragViaMove]
  /// for why those two producers of this same field must stay
  /// distinguishable.
  int? _draggingAnchorIndex;

  /// True when the anchor currently in [_draggingAnchorIndex] was picked up
  /// by [_onMovePanStart] (Move tool / Ctrl-drag) rather than
  /// [_onAdjustPanStart] (Adjust mode's own free-anchor-drag) — both set the
  /// same field, so this is what the pointer-move/up dispatch and the drag
  /// preview use to tell which family of behaviour should keep driving the
  /// rest of the gesture. Missing this distinction was a real, shipped bug
  /// (confirmed live 2026-08-23): a plain `_draggingAnchorIndex != null`
  /// check in the dispatch (added so a Ctrl-drag released mid-gesture still
  /// routes correctly, see [_ctrlMoveActive]'s doc) also matched Adjust
  /// mode's own anchor-drag, silently diverting its commit through the
  /// Move tool's no-reroute [_commitAnchorPositionOnPath] instead of
  /// Adjust's intended full-reroute [_commitAnchorPosition] — reported as
  /// "Adjust no longer properly aligns the path to the trail."
  bool _anchorDragViaMove = false;

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

  /// Raw data for the bottom-left status line — kept unformatted (rather
  /// than a pre-built "N points · X km" string) so the distance renders
  /// live via [Settings.metric]/[Settings.format] instead of freezing
  /// whatever unit was selected the last time [_redraw] ran.
  ({int points, double meters})? _status;

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
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _prefetchDebounce?.cancel();
    super.dispose();
  }

  /// Tracks Ctrl up/down so [_Tool.draw]/[_Tool.addCue] can temporarily
  /// behave like [_Tool.moveAnchor] while held — see [_ctrlMoveActive]. Never
  /// swallows the event (`return false`) so normal shortcuts (undo, etc.)
  /// keep working while Ctrl is held. If a keyup is ever missed (e.g. the
  /// browser tab loses focus mid-hold, a known general limitation of
  /// tracking modifier keys this way), [_onOverlayPointerCancel] also clears
  /// this as a safety net.
  bool _ctrlHeld = false;

  bool _handleKeyEvent(KeyEvent event) {
    final isCtrl = event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight;
    if (!isCtrl) return false;
    final held = event is! KeyUpEvent;
    if (held != _ctrlHeld) {
      setState(() => _ctrlHeld = held);
      setMapDragLocked(_captureOverlayActive);
    }
    return false;
  }

  /// True while Ctrl is held and the active tool is one where a click
  /// normally *creates* something ([_Tool.draw]/[_Tool.addCue]) — Ctrl
  /// temporarily redirects a click-drag on an existing anchor/cue to moving
  /// it instead, without switching tools. See the "hold Ctrl to move"
  /// request this was built for.
  bool get _ctrlMoveActive =>
      _ctrlHeld && (_tool == _Tool.draw || _tool == _Tool.addCue);

  /// True whenever the full-screen pointer-capturing overlay should be
  /// mounted (and the native map's own drag-panning disabled via
  /// [setMapDragLocked]) — every tool that needs raw drag gestures instead
  /// of (or in addition to) a plain click, plus the Ctrl-held case above.
  bool get _captureOverlayActive =>
      _tool == _Tool.dragDraw ||
      _tool == _Tool.lineAdjust ||
      _tool == _Tool.moveAnchor ||
      _ctrlMoveActive;

  void _onMapCreated(MapLibreMapController c) => _c = c;

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null) return;
    suppressMapContextMenu();
    _route = RouteLayer(c);
    await _route!.ensure(
        arrowScale: Settings.instance.chevronScale.value,
        arrowVisible: Settings.instance.chevronVisible.value);
    _points = CueLayer(c, id: 'designerPoints');
    await _points!.ensure();
    _dragGhost = _DragGhostLayer(c);
    await _dragGhost!.ensure();
    _boundary = BoundaryLayer(c);
    await _boundary!.ensure();
    _strokeLayer = RouteLayer(c, id: 'strokePreview', splitOutAndBack: false);
    await _strokeLayer!.ensure(
        arrowScale: Settings.instance.chevronScale.value,
        arrowVisible: Settings.instance.chevronVisible.value);
    await _redraw();
    _prefetchRouteGraph();
  }

  /// Debounce for [_prefetchRouteGraph] — a rapid burst of mouse-wheel
  /// zoom ticks fires MapLibre's `onCameraIdle` once per tick as each
  /// zoom-in/zoom-out animation settles, not once per gesture. Confirmed
  /// live via the debug panel (2026-08-22): an undebounced version called
  /// `getVisibleRegion()`/`waysInBounds()` well over a hundred times in
  /// under two seconds during one scroll-wheel zoom burst — each call
  /// individually cheap once cached, but the sheer volume of platform-
  /// channel round-trips and map lookups is real, wasteful churn that
  /// could itself contribute to jank on a fresh (not-yet-cached) area,
  /// working against the whole point of this prefetch. Only the *last*
  /// idle event in a burst actually triggers a fetch, ~400ms after
  /// activity stops.
  Timer? _prefetchDebounce;

  /// Fire-and-forget: warms [RouteGraphStore]'s per-cell cache for whatever's
  /// currently visible, so a real click/drag a moment later usually finds
  /// its cells already fetched instead of paying that network round-trip
  /// itself. Wired to both the initial style-load and the map's
  /// `onCameraIdle` — the same idea as mobile always having its whole
  /// bundled region already on disk, just warmed just-in-time instead of
  /// bundled ahead of time. Never awaited by any caller and swallows its
  /// own errors: a failed/slow prefetch must never block or visibly affect
  /// anything, it can only help.
  void _prefetchRouteGraph() {
    _prefetchDebounce?.cancel();
    _prefetchDebounce = Timer(const Duration(milliseconds: 400), () {
      final c = _c;
      if (c == null) return;
      unawaited(c.getVisibleRegion().then(
        (bounds) => RouteGraphStore.instance.prefetch(bounds),
        onError: (_) {},
      ));
    });
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
    });
    await _redraw();
  }

  /// Nearest anchor to click-point [screenPoint] within [maxPx] *screen*
  /// pixels, or null — the desktop stand-in for a native tappable anchor
  /// marker (see the class doc). Screen-space, not [metersBetween] on the
  /// real coordinates: a fixed real-world-metres radius is zoom-dependent
  /// by construction (tiny in screen terms zoomed out, enormous zoomed in),
  /// the same class of bug already found and fixed twice this session for
  /// cue-marker rendering — [screenPoint] comes straight from
  /// `onMapClick`'s own `point` param, already in the same native pixel
  /// space `toScreenLocation` returns (confirmed via `maplibre_gl_web`'s
  /// source — see `pointer_probe.dart`'s doc), so no devicePixelRatio
  /// conversion is needed here the way a raw Flutter `Offset` would.
  Future<int?> _nearestAnchorIndex(Point<double> screenPoint,
      {double maxPx = 24}) async {
    final c = _c;
    if (c == null) return null;
    var bestIdx = -1;
    var bestPx = maxPx;
    for (var i = 0; i < _trail.anchors.length; i++) {
      final sp = await c.toScreenLocation(_trail.anchors[i]);
      final dx = sp.x.toDouble() - screenPoint.x;
      final dy = sp.y.toDouble() - screenPoint.y;
      final px = sqrt(dx * dx + dy * dy);
      if (px < bestPx) {
        bestPx = px;
        bestIdx = i;
      }
    }
    return bestIdx < 0 ? null : bestIdx;
  }

  /// Nearest cue to click-point [screenPoint] within [maxPx] *screen*
  /// pixels, or null — same idea as [_nearestAnchorIndex] (see its doc for
  /// why screen pixels, not real-world metres), used so a click in
  /// [_Tool.addCue] mode on top of an existing cue opens *that* cue's
  /// editor (with Delete/"Add another") instead of always creating a
  /// brand-new one at the exact same spot. The previous 15-metre version
  /// of this was reported live (2026-08-22) as actively blocking legit
  /// closely-spaced cue placement — at a normal editing zoom, 15 real
  /// metres is far wider than the drawn circle, so clicking anywhere near
  /// an *existing* cue silently redirected into editing it instead of
  /// creating the *next* one, exactly the kind of accuracy-critical
  /// placement this app exists for.
  Future<int?> _nearestCueIndex(Point<double> screenPoint,
      {double maxPx = 20}) async {
    final c = _c;
    if (c == null) return null;
    var bestIdx = -1;
    var bestPx = maxPx;
    for (var i = 0; i < _trail.cues.length; i++) {
      final sp = await c.toScreenLocation(_trail.cues[i].position);
      final dx = sp.x.toDouble() - screenPoint.x;
      final dy = sp.y.toDouble() - screenPoint.y;
      final px = sqrt(dx * dx + dy * dy);
      if (px < bestPx) {
        bestPx = px;
        bestIdx = i;
      }
    }
    return bestIdx < 0 ? null : bestIdx;
  }

  Future<void> _onMapClick(Point<double> screenPoint, LatLng coords) async {
    final c = _c;
    if (c == null || _busy || _modalOpen) return;
    switch (_tool) {
      case _Tool.draw:
        await _addAnchor(coords);
      case _Tool.deleteAnchor:
        final idx = await _nearestAnchorIndex(screenPoint);
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
        final idx = await _nearestCueIndex(screenPoint);
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
      case _Tool.moveAnchor:
        // No-op: all three tools act via the full-screen Listener overlay's
        // pointer callbacks while active (drag-to-move for moveAnchor, see
        // _onMovePanStart/Update/End), not map clicks — the overlay's
        // HitTestBehavior.opaque means this callback shouldn't even fire,
        // but the switch must stay exhaustive regardless.
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
        // A straight fallback is a legitimate result (there may genuinely be
        // no mapped trail between the two taps, especially while the live
        // Overpass-backed offline supplement is unavailable/rate-limited —
        // see route_graph_store_stub.dart), but it's easy to mistake for a
        // routing bug when it silently cuts across terrain. Tell the author
        // what happened so they know to redraw/adjust rather than assume
        // "Follow trails" is broken — mirrors AuthorScreen._addAnchor.
        if (from != null && !conn.followed) {
          final why = conn.debugReason;
          _toast('No connected trail found here — drew a straight line'
              '${why != null ? ' ($why)' : ''}');
        }
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

  /// Right-click on the drawn line (Draw mode only) inserts a real,
  /// permanent anchor exactly at the click, splitting whichever hop it
  /// landed closest to into two routed segments — the desktop port of
  /// `AuthorScreen._insertAnchorNear` (mobile reaches this via long-press,
  /// since mobile has no right mouse button; confirmed live 2026-08-23 that
  /// right-click is the web equivalent the user actually wants).
  ///
  /// [screenPoint] is used twice, for two different jobs that must NOT be
  /// conflated: first, converted to a `LatLng` to search `_segments` (a
  /// real-metres computation — `nearestPointOnPolyline` is a plain geometric
  /// nearest-point search, the same kind cue-snapping already does, not a
  /// click hit-test), *then* the winning candidate is projected back to
  /// screen space to make the actual accept/reject decision in **pixels**.
  /// That second check is deliberate, not redundant: a fixed real-world
  /// tolerance for "is this right-click close enough to the line to count"
  /// would be huge in screen terms zoomed out and razor-thin zoomed in — the
  /// exact "metres where it should be pixels" bug class already fixed this
  /// session for anchor/cue click detection, avoided here from the start.
  Future<void> _insertAnchorNear(Point<double> screenPoint) async {
    final c = _c;
    if (c == null || _busy || _segments.length < 2) return;
    final tapped = await c.toLatLng(screenPoint);
    if (!mounted || _tool != _Tool.draw) return;

    var bestHop = -1;
    LatLng? bestPoint;
    var bestMeters = double.infinity;
    for (var k = 1; k < _segments.length; k++) {
      final hit =
          nearestPointOnPolyline(tapped, _segments[k], maxMeters: double.infinity);
      if (hit != null && hit.meters < bestMeters) {
        bestMeters = hit.meters;
        bestHop = k;
        bestPoint = hit.point;
      }
    }
    if (bestHop < 0 || bestPoint == null) return; // no line here — no-op

    final bestScreen = await c.toScreenLocation(bestPoint);
    final dx = bestScreen.x.toDouble() - screenPoint.x;
    final dy = bestScreen.y.toDouble() - screenPoint.y;
    if (sqrt(dx * dx + dy * dy) > 24) return; // right-click landed too far away

    _pushUndo();
    setState(() => _busy = true);
    try {
      final prev = _trail.anchors[bestHop - 1];
      final next = _trail.anchors[bestHop];
      final segA =
          _followTrails ? await TrailRouter(c).between(prev, tapped) : [prev, tapped];
      final segB =
          _followTrails ? await TrailRouter(c).between(tapped, next) : [tapped, next];
      setState(() {
        _trail.anchors.insert(bestHop, tapped);
        _segments[bestHop] = segA;
        _segments.insert(bestHop + 1, segB);
        _trail.path = _composePath();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _redraw();
  }

  /// Right-click handler for the always-present (Draw-mode-only) secondary-
  /// button listener — see the `Listener` in `build()`. Only the secondary
  /// mouse button is acted on; anything else (a normal left click/drag)
  /// passes straight through untouched, since this listener is translucent.
  void _onDrawSecondaryPointerDown(PointerDownEvent e) {
    if (_tool != _Tool.draw || _busy || _modalOpen) return;
    if (e.buttons != kSecondaryMouseButton) return;
    _insertAnchorNear(_mapPoint(e.localPosition));
  }

  /// Which cue is being drag-relocated in [_Tool.moveAnchor] mode (or via
  /// [_ctrlMoveActive]), or null — mutually exclusive with
  /// [_draggingAnchorIndex] (a single grab picks up at most one of the two).
  int? _draggingCueIndex;

  /// Picks up whatever's under [p] — an anchor first (checked first since
  /// an anchor and a cue can legitimately sit at/near the same spot, e.g. a
  /// "Start" cue right on anchor 1), then a cue — for a live drag-to-move,
  /// replacing the old click-then-click flow (reported live as "clunky and
  /// weird": pick a point, then click again elsewhere to drop it, with no
  /// visual feedback in between). [_draggingAnchorIndex] then drives the
  /// exact same live preview [_Tool.lineAdjust]'s own free-dragged-anchor
  /// case already uses ([_pushAnchorDragPreview]/[_commitAnchorPosition]) —
  /// this is that same underlying gesture, just reachable from a dedicated
  /// Move tool (and temporarily via Ctrl) instead of only from Adjust.
  Future<void> _onMovePanStart(Offset p) async {
    final c = _c;
    if (c == null) return;
    final gen = ++_previewGeneration;
    final mapped = _mapPoint(p);
    final anchorIdx = await _nearestAnchorIndex(mapped);
    if (!mounted || gen != _previewGeneration) return;
    if (anchorIdx != null) {
      _pushUndo();
      setState(() {
        _draggingAnchorIndex = anchorIdx;
        _anchorDragViaMove = true;
        _draggingCueIndex = null;
      });
      return;
    }
    final cueIdx = await _nearestCueIndex(mapped);
    if (!mounted || gen != _previewGeneration) return;
    if (cueIdx != null) {
      _pushUndo();
      setState(() {
        _draggingCueIndex = cueIdx;
        _draggingAnchorIndex = null;
      });
    }
    // Neither found: a Ctrl-held click (or a Move-tool click) on empty map
    // is deliberately a no-op — Ctrl's whole point is "move something that's
    // already there", not "also draw/place something new".
  }

  void _onMovePanUpdate(Offset p) {
    final mapped = _mapPoint(p);
    _lastAdjustPoint = mapped;
    if (_draggingAnchorIndex != null) {
      _pushAnchorDragPreview(mapped);
    } else if (_draggingCueIndex != null) {
      _pushCueDragPreview(mapped);
    }
  }

  bool _convertingCuePoint = false;

  /// Live preview for a dragged cue: shows [_dragGhost] at the cursor's
  /// live map position. Does *not* touch the real [Cue.position] or call
  /// [_redraw] on every update — [CueLayer]'s full teardown-and-rebuild per
  /// update (needed for its own text layers, see its class doc) would be
  /// too slow to track the cursor smoothly; the ghost gives instant visual
  /// feedback instead, and the real marker only moves once, on commit (see
  /// [_onMovePanEnd]). Self-throttles (skips an update if a previous one is
  /// still converting) rather than queueing, same pattern as
  /// [_pushStrokePreview]/[_pushAdjustPreview].
  Future<void> _pushCueDragPreview(Point<double> p) async {
    final c = _c;
    final idx = _draggingCueIndex;
    if (c == null || idx == null || _convertingCuePoint || !mounted) return;
    final gen = _previewGeneration;
    _convertingCuePoint = true;
    try {
      final latlng = await c.toLatLng(p);
      if (!mounted || _draggingCueIndex != idx || gen != _previewGeneration) return;
      await _dragGhost?.show(latlng);
    } finally {
      _convertingCuePoint = false;
    }
  }

  /// Commits whichever grab is active: an anchor re-routes exactly like the
  /// old click-then-click flow did ([_commitAnchorPosition]); a cue snaps
  /// onto the trail's own path (always, regardless of "Follow trails" — a
  /// cue belongs on the line it's guiding, same rule [_onMapClick]'s
  /// add-cue case already applies) and redraws once more with the final,
  /// snapped position.
  Future<void> _onMovePanEnd() async {
    final c = _c;
    final draggingAnchor = _draggingAnchorIndex;
    final draggingCue = _draggingCueIndex;
    final point = _lastAdjustPoint;
    setState(() {
      _previewGeneration++;
      _draggingAnchorIndex = null;
      _draggingCueIndex = null;
      _lastAdjustPoint = null;
    });
    await _strokeLayer?.setRoute(const [], _strokePreviewColor);
    await _dragGhost?.hide();
    if (!mounted || c == null || point == null) return;

    final newPos = await c.toLatLng(point);
    if (!mounted) return;

    if (draggingAnchor != null) {
      await _commitAnchorPositionOnPath(draggingAnchor, newPos);
    } else if (draggingCue != null) {
      final snapped = _trail.path.length >= 2
          ? nearestPointOnPath(newPos, _trail.path)
          : newPos;
      setState(() => _trail.cues[draggingCue].position = snapped);
      await _redraw();
    }
  }

  /// Re-splits the path around anchor [idx] to reflect its new position
  /// [pos] — the Move tool / Ctrl-drag's own commit, deliberately different
  /// from [_commitAnchorPosition] (which Adjust mode's own anchor-drag still
  /// uses, unchanged). Confirmed live (2026-08-23): a live
  /// `TrailRouter.between()` reroute on every Move-tool drop made it feel
  /// like "adjusting the whole line" — the user's own words — which is
  /// Adjust mode's job, not Move's. This method never calls `TrailRouter`
  /// at all: [pos] is constrained to slide along the *existing, unchanged*
  /// line, the same way a cue is always constrained to `_trail.path`.
  ///
  /// The search for where [pos] lands is deliberately restricted to the one
  /// or two hops immediately touching [idx] — `[..._segments[idx],
  /// ..._segments[idx + 1].skip(1)]` for an interior anchor, just the one
  /// real hop for an endpoint anchor — rather than the whole `_trail.path`.
  /// A hop boundary only makes structural sense *between adjacent anchors*;
  /// snapping onto some unrelated, far-away leg of a looping trail would
  /// leave `_segments`' one-hop-per-anchor invariant incoherent (which hops
  /// belong to which anchors would no longer line up along the trail). If
  /// [pos] doesn't land within the local stretch at all (only possible if
  /// it's on the wrong side of a self-intersection, since there's no
  /// distance cap otherwise), the drag is a no-op — the anchor stays
  /// exactly where it was, rather than doing something structurally
  /// undefined.
  Future<void> _commitAnchorPositionOnPath(int idx, LatLng pos) async {
    final anchors = _trail.anchors;
    final isFirst = idx == 0;
    final isLast = idx == anchors.length - 1;
    if (isFirst && isLast) return; // single-anchor trail — nothing to slide along

    final combined = isFirst
        ? List<LatLng>.of(_segments[idx + 1])
        : isLast
            ? List<LatLng>.of(_segments[idx])
            : [..._segments[idx], ..._segments[idx + 1].skip(1)];
    if (combined.length < 2) return;

    // No distance cap (mirrors nearestPointOnPath's own uncapped cue-snap
    // behaviour) — the local-stretch restriction above already bounds how
    // far this can reasonably reach, so an extra cap here would only add a
    // second, arbitrary threshold on top of that.
    final hit = nearestPointOnPolyline(pos, combined, maxMeters: double.infinity);
    if (hit == null) return;

    _pushUndo();
    setState(() {
      final point = hit.point, edge = hit.edgeIndex;
      final before = [...combined.sublist(0, edge + 1), point];
      final after = [point, ...combined.sublist(edge + 1)];
      if (isFirst) {
        _segments[0] = [point];
        _segments[1] = after;
      } else if (isLast) {
        _segments[idx] = before;
      } else {
        _segments[idx] = before;
        _segments[idx + 1] = after;
      }
      anchors[idx] = point;
      _trail.path = _composePath();
    });
    await _redraw();
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
      final beforeSnap = pos;
      if (_followTrails) {
        pos = await router.snapPoint(pos, rect: rect);
        if (metersBetween(beforeSnap, pos) < 0.01) {
          // MapLibre GL JS's queryRenderedFeaturesInRect only sees tiles
          // that have actually finished rendering *right now* — confirmed
          // live (2026-08-22, via the debug panel) that the exact same rect,
          // queried moments apart within one commit, found 0 features here
          // and then 3 features in the between() calls that naturally ran
          // ~500ms later (while this method's own offline-fetch timeout was
          // pending) — a real rendering race on a just-settled camera, not
          // a genuine absence of data. One short retry gives the map the
          // same breathing room between() was accidentally getting.
          await Future.delayed(const Duration(milliseconds: 400));
          pos = await router.snapPoint(pos, rect: rect);
        }
      }
      DebugLog.instance.log('_commitAnchorPosition: snapPoint moved '
          '${metersBetween(beforeSnap, pos).toStringAsFixed(1)}m '
          '(dropped at $beforeSnap, snapped to $pos)');
      var noRouteFound = false;
      final anchors = _trail.anchors;
      anchors[idx] = pos;
      if (idx > 0) {
        final prev = anchors[idx - 1];
        if (_followTrails) {
          final seg = await router.between(prev, pos, rect: rect);
          if (seg.length <= 2) noRouteFound = true;
          DebugLog.instance.log('_commitAnchorPosition: between(prev, pos) '
              '-> ${seg.length} points'
              '${seg.length <= 2 ? " (NO ROUTE FOUND, straight fallback)" : ""}');
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
          DebugLog.instance.log('_commitAnchorPosition: between(pos, next) '
              '-> ${seg.length} points'
              '${seg.length <= 2 ? " (NO ROUTE FOUND, straight fallback)" : ""}');
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
  /// on just to reposition the view mid-edit. Ctrl is excluded from that
  /// pan-override check while [_ctrlMoveActive] — Ctrl is already spoken
  /// for there (hold to move an anchor/cue), so it can't also mean "pan" in
  /// that state; Shift and the middle button still work.
  void _onOverlayPointerDown(PointerDownEvent e) {
    final panOverride = e.buttons == kMiddleMouseButton ||
        HardwareKeyboard.instance.isShiftPressed ||
        (!_ctrlMoveActive && HardwareKeyboard.instance.isControlPressed);
    _overlayPanningCamera = panOverride;
    if (panOverride) {
      _overlayPanLast = e.localPosition;
      return;
    }
    switch (_tool) {
      case _Tool.dragDraw:
        _onStrokePanStart(e.localPosition);
      case _Tool.moveAnchor:
        _onMovePanStart(e.localPosition);
      default:
        // _Tool.lineAdjust, or a Ctrl-held draw/addCue click (_ctrlMoveActive).
        if (_ctrlMoveActive) {
          _onMovePanStart(e.localPosition);
        } else {
          _onAdjustPanStart(e.localPosition);
        }
    }
  }

  void _onOverlayPointerMove(PointerMoveEvent e) {
    if (_overlayPanningCamera) {
      final last = _overlayPanLast;
      if (last != null) {
        final delta = e.localPosition - last;
        // Negated — this is the *opposite* of the established mobile
        // gotcha for a native two-finger pan (`CameraUpdate.scrollBy`'s
        // doc says positive dx moves the camera target east, but the
        // native Android SDK's actual on-screen effect is reversed from
        // that, so mobile passes the raw delta straight through
        // unnegated). Confirmed live on web (2026-08-22) that passing the
        // raw delta here made the map move in the *same* direction as the
        // drag instead of the content following the cursor like grabbing
        // and pulling it — i.e. web's `scrollBy` behaves like its own
        // documented sense, not like mobile's native SDK override. One
        // more platform-specific divergence in this same API, not a typo.
        _c?.moveCamera(CameraUpdate.scrollBy(-delta.dx, -delta.dy));
      }
      _overlayPanLast = e.localPosition;
      return;
    }
    if (_tool == _Tool.dragDraw) {
      _onStrokePanUpdate(e.localPosition);
    } else if (_tool == _Tool.moveAnchor ||
        _draggingCueIndex != null ||
        (_draggingAnchorIndex != null && _anchorDragViaMove)) {
      _onMovePanUpdate(e.localPosition);
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
    } else if (_tool == _Tool.moveAnchor ||
        _draggingCueIndex != null ||
        (_draggingAnchorIndex != null && _anchorDragViaMove)) {
      _onMovePanEnd();
    } else {
      _onAdjustPanEnd();
    }
  }

  void _onOverlayPointerCancel(PointerCancelEvent e) {
    if (_overlayPanningCamera) {
      _overlayPanningCamera = false;
      _overlayPanLast = null;
    }
    if (_draggingAnchorIndex != null || _draggingCueIndex != null) {
      setState(() {
        _draggingAnchorIndex = null;
        _draggingCueIndex = null;
      });
      _dragGhost?.hide();
    }
    // Safety net for a missed keyup (see _handleKeyEvent's doc) — a pointer
    // cancel (e.g. the browser tab losing focus mid-drag) is exactly the
    // scenario where a stuck _ctrlHeld would otherwise leave the overlay
    // wrongly locked on afterward.
    if (_ctrlHeld) {
      setState(() => _ctrlHeld = false);
      setMapDragLocked(_captureOverlayActive);
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
        _anchorDragViaMove = false;
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

  /// Live preview for a free-dragged anchor ([_draggingAnchorIndex]):
  /// [_dragGhost] always tracks the actual cursor position so the anchor
  /// itself visibly follows the mouse even though its real marker (plain
  /// non-interactive GeoJSON, redrawn wholesale by [_redraw]) stays put
  /// until commit. Shared by both [_Tool.lineAdjust]'s own
  /// free-dragged-anchor case and [_Tool.moveAnchor]/[_ctrlMoveActive]'s
  /// drag-to-move ([_draggingAnchorIndex] is the same field either way,
  /// disambiguated by [_anchorDragViaMove]) — but the two differ on the
  /// connecting-line stretch: Adjust mode also draws it via [_strokeLayer]
  /// (a legitimate preview of the reshape it's about to commit), while
  /// Move/Ctrl deliberately does NOT — confirmed live (2026-08-23) as
  /// actively misleading there, since it visually reads identically to
  /// Adjust's own line-bending preview even though Move never touches the
  /// line's shape at all (see [_commitAnchorPositionOnPath]). Move's drag
  /// shows only the ghost dot, same as a dragged cue.
  Future<void> _pushAnchorDragPreview(Point<double> p) async {
    final c = _c;
    final idx = _draggingAnchorIndex;
    if (c == null || idx == null || _convertingAdjustPoint || !mounted) return;
    final gen = _previewGeneration;
    _convertingAdjustPoint = true;
    try {
      final latlng = await c.toLatLng(p);
      final validContext =
          _tool == _Tool.lineAdjust || _tool == _Tool.moveAnchor || _ctrlMoveActive;
      if (!mounted ||
          !validContext ||
          _draggingAnchorIndex != idx ||
          gen != _previewGeneration) {
        return;
      }
      if (!_anchorDragViaMove) {
        final anchors = _trail.anchors;
        final preview = [
          if (idx > 0) anchors[idx - 1],
          latlng,
          if (idx < anchors.length - 1) anchors[idx + 1],
        ];
        await _strokeLayer?.setRoute(preview, _strokePreviewColor);
      }
      await _dragGhost?.show(latlng);
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
    await _dragGhost?.hide();
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
    // Deliberately NOT snapped to the trail network — reverted back to pure
    // geometric deformation to match `AuthorScreen._onAdjustPanEnd` exactly.
    // An earlier iteration snapped the drop point onto the nearest edge
    // before bending toward it, but live testing showed this made the
    // wire-bend feel unpredictable (the deform origin could jump to wherever
    // the snap landed rather than exactly where the mouse released) — the
    // opposite of what mobile's proven, purely-geometric wire-bend delivers.
    final deformed = _deformSegment(original, grabIdx, grabOriginal, newPos);
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

  /// Toolbar/text size, trail-direction-arrow size, and distance units —
  /// the web designer's only settings surface (there's no dedicated
  /// Settings screen here the way mobile's SettingsScreen is). All are the
  /// same Settings.uiScale/chevronScale/metric values mobile uses; changing
  /// them here takes effect immediately (uiScale via main_web.dart's
  /// app-wide ValueListenableBuilder, chevronScale via an explicit
  /// setArrowScale call below, metric via the status line's own
  /// ValueListenableBuilder) rather than needing a page reload — useful for
  /// a designer actually comparing sizes live rather than just picking a
  /// number blind.
  Future<void> _showDisplaySize() async {
    await _showModal(() => showOpaqueDialog<void>(
          context,
          // Generous — this dialog's own rows grow with uiScale itself (see
          // _ScaleSliderRow's plain, unscaled font today vs. a future bump),
          // and the established gotcha here is a *silently* uninteractable
          // overflow past whatever's given, not a visible clipped edge.
          maxHeight: 520,
          builder: (ctx) => AlertDialog(
            title: const Text('Display size'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ScaleSliderRow(
                    label: 'Toolbar & text size',
                    valueListenable: Settings.instance.uiScale,
                    min: 0.85,
                    max: 1.75,
                    onChanged: Settings.instance.setUiScale,
                  ),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<bool>(
                    valueListenable: Settings.instance.chevronVisible,
                    builder: (context, visible, _) => SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: visible,
                      title: const Text('Show trail direction arrows'),
                      onChanged: (v) {
                        Settings.instance.setChevronVisible(v);
                        _route?.setArrowVisible(v);
                        _strokeLayer?.setArrowVisible(v);
                      },
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: Settings.instance.chevronVisible,
                    builder: (context, visible, _) => Opacity(
                      opacity: visible ? 1 : 0.4,
                      child: IgnorePointer(
                        ignoring: !visible,
                        child: _ScaleSliderRow(
                          label: 'Arrow size',
                          valueListenable: Settings.instance.chevronScale,
                          min: 0.1,
                          max: 1.5,
                          onChanged: (v) {
                            Settings.instance.setChevronScale(v);
                            _route?.setArrowScale(v);
                            _strokeLayer?.setArrowScale(v);
                          },
                        ),
                      ),
                    ),
                  ),
                  const Divider(),
                  ValueListenableBuilder<bool>(
                    valueListenable: Settings.instance.metric,
                    builder: (context, metric, _) => SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: metric,
                      title: const Text('Distance units'),
                      subtitle: Text(metric ? 'Kilometres' : 'Miles'),
                      onChanged: Settings.instance.setMetric,
                    ),
                  ),
                ],
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
  static const _stackClusterMeters = 3.0;

  /// Real (unmoved) positions seen so far this redraw — reset per redraw.
  final List<LatLng> _stackAnchors = [];

  /// True if [pos] is within [_stackClusterMeters] of an already-claimed
  /// marker position this redraw — signals that the caller's marker needs
  /// [CueMarker.nudged]'s screen-space-only visual separation, never an
  /// altered coordinate (see that field's doc for why a *real* geographic
  /// nudge was wrong here: it's misleading at best, and a genuine accuracy
  /// risk for a cue's real trigger point at worst). Also registers [pos] so
  /// later markers checked against it collide too.
  bool _needsNudge(LatLng pos) {
    for (final claimed in _stackAnchors) {
      if (metersBetween(claimed, pos) < _stackClusterMeters) return true;
    }
    _stackAnchors.add(pos);
    return false;
  }

  /// Registers [pos] as a claimed marker spot for this redraw's collision
  /// bookkeeping (above) — used for anchor markers, which should never move
  /// off their real clicked position no matter how close together several
  /// end up. Confirmed unwanted live (2026-08-22): clicking near-identical
  /// spots repeatedly in Draw mode used to nudge each new anchor into a
  /// vertical stack the same way overlapping cues used to — but a cluster
  /// of anchors isn't a meaningful "feature" the way a genuine multi-cue
  /// junction is; an anchor sitting almost on top of another is just where
  /// it was actually placed, and hiding that by moving it is more
  /// confusing than an overlapping dot. Still updates the shared tracker so
  /// a *cue* landing on the same spot as this anchor knows to nudge its
  /// own marker (not its stored position) away from it.
  void _registerStackPosition(LatLng pos) {
    for (final claimed in _stackAnchors) {
      if (metersBetween(claimed, pos) < _stackClusterMeters) return;
    }
    _stackAnchors.add(pos);
  }

  Future<void> _redraw() async {
    await _route?.setRoute(_trail.path, _trail.color);
    _stackAnchors.clear();

    final markers = <CueMarker>[];
    for (var i = 0; i < _trail.anchors.length; i++) {
      final pos = _trail.anchors[i];
      _registerStackPosition(pos);
      markers.add(CueMarker(
        position: pos,
        radius: i == _draggingAnchorIndex ? 9 : 7,
        color: i == _draggingAnchorIndex ? '#EF6C00' : '#1565C0',
        strokeWidth: 2,
        text: '${i + 1}',
        textColor: '#1A1A1A',
      ));
    }

    // Group cues that share (almost) the same spot so they render as one
    // merged marker (a distinct stacked colour) with every cue there listed
    // on its own text line, instead of splitting into separate, overlapping
    // dots — mirrors `AuthorScreen._cueDisplayInfo`/`GuideScreen._drawCues`.
    // 1m, matching `GuideScreen._drawCues` — deliberately much tighter than
    // `cue_gen.dart`'s 7m `cueMergeMeters` (that constant decides whether
    // two *auto-generated* waypoints represent the same real junction, a
    // different question). Confirmed live (2026-08-22): at 7m, two distinct
    // cues placed at genuinely separate nearby junctions silently rendered
    // as one merged marker, making it look like only one had been placed —
    // real cues should only ever share a marker when the author explicitly
    // chose "Add another cue" at the exact same spot, never just because
    // they happened to land within a few metres of each other.
    final sorted = List<Cue>.of(_trail.cues)..sort((a, b) => a.order.compareTo(b.order));
    final rank = <Cue, int>{for (var i = 0; i < sorted.length; i++) sorted[i]: i + 1};
    final groups = <List<Cue>>[];
    for (final cue in _trail.cues) {
      final match =
          groups.where((g) => metersBetween(g.first.position, cue.position) < 1.0);
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
      // Real position, always — never altered. A cue landing at/near an
      // anchor (the common "Start"/"Finish" case) only gets a
      // screen-space-only marker nudge (see [CueMarker.nudged]), same as
      // stacked lines only get a style-layer text offset, never a
      // geographic one — a cue's stored coordinate is what actually fires
      // during a walk, so it must stay exactly where it was placed.
      final pos = group.first.position;
      final nudged = _needsNudge(pos);
      final color = stacked ? stackedCueColorHex : cueColorHex(group.first.type);
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
          nudged: nudged,
        ));
      }
    }

    await _points?.setMarkers(markers);
    if (mounted) {
      setState(() => _status =
          (points: _trail.anchors.length, meters: pathLength(_trail.path)));
    }
  }

  Future<void> _newTrail() async {
    setState(() {
      _trail = Trail(name: 'New trail', regionId: 'web-design');
      _segments.clear();
      _undoStack.clear();
      _draggingAnchorIndex = null;
      _draggingCueIndex = null;
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
      _draggingAnchorIndex = null;
      _draggingCueIndex = null;
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
          // Was 200 — too tight once Settings.uiScale exists: at higher
          // scale a longer confirmation title (e.g. "Clear the path and
          // all cues?") wraps to more lines than this budget had room for,
          // pushing Cancel/OK into the same silent, uninteractable overflow
          // this file's own established gotcha warns about (painted, but
          // not actually clickable) — confirmed live (2026-08-23) as
          // exactly why Cancel/OK stopped responding. Generous, not exact.
          maxHeight: 320,
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
          // Same fix as _confirm's own maxHeight bump — see its comment.
          maxHeight: 320,
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
        _Tool.draw => 'Click the map to add a point, or right-click the '
            'line to insert one there. Hold Ctrl and drag a point or cue '
            'to move it.',
        _Tool.moveAnchor => 'Drag a point or cue to move it along the trail. '
            'Middle-click-drag, or hold Shift and drag, to pan the map instead.',
        _Tool.deleteAnchor => 'Click a point to delete it.',
        _Tool.addCue => 'Click the map to place a cue there. '
            'Hold Ctrl and drag a point or cue to move it.',
        _Tool.drawBoundary =>
          'Click each corner of the area, then "Finish boundary" (${_boundaryPoints.length} so far).',
        _Tool.dragDraw => 'Click and drag to trace a trail freehand. '
            'Middle-click-drag, or hold Shift/Ctrl and drag, to pan the map instead.',
        _Tool.lineAdjust =>
          'Drag a point on the line to bend it, or drag a marked point to move it. '
              'Middle-click-drag, or hold Shift/Ctrl and drag, to pan the map instead.',
      };

  /// Below this width (a phone-portrait browser), the `AppBar.actions` row
  /// no longer fits at all — confirmed live (2026-08-23) as cutting off
  /// most of the toolbar entirely on a phone browser. Picked with margin
  /// under the wide toolbar's own ~1750-1850px minimum width; tune further
  /// if real narrow-screen testing shows it's still too tight or looser
  /// than it needs to be.
  static const _narrowBreakpoint = 700.0;

  /// The debug panel's own fixed footprint (`width: 420` + 16px margins on
  /// both sides below) — named so the capture-overlay exclusion math that
  /// depends on it (`right: _debugPanelOpen ? _debugPanelExclusion : 0`,
  /// used in three places in this build method) has one definition instead
  /// of a repeated bare `452` magic number.
  static const _debugPanelWidth = 420.0;
  static const _debugPanelMargin = 16.0;
  static const _debugPanelExclusion = _debugPanelWidth + 2 * _debugPanelMargin;

  /// The tool `SegmentedButton` — shared by the wide `AppBar.actions` row
  /// and the narrow layout's own dedicated `AppBar.bottom` row (mirroring
  /// how mobile's `AuthorScreen` fixed an identical "shared a row, wrapped
  /// to one-character-per-line" overflow by giving its own tool selector a
  /// dedicated full-width row). [compact] drops the text labels, icon-only,
  /// for the narrow case.
  Widget _toolSelector({bool compact = false}) {
    ButtonSegment<_Tool> seg(_Tool value, IconData icon, String label) =>
        ButtonSegment(value: value, icon: Icon(icon), label: compact ? null : Text(label));
    return SegmentedButton<_Tool>(
      segments: [
        seg(_Tool.draw, Icons.edit, 'Draw'),
        seg(_Tool.moveAnchor, Icons.open_with, 'Move'),
        seg(_Tool.deleteAnchor, Icons.remove_circle_outline, 'Delete'),
        seg(_Tool.addCue, Icons.add_location_alt_outlined, 'Add cue'),
        seg(_Tool.drawBoundary, Icons.crop_free, 'Boundary'),
        seg(_Tool.dragDraw, Icons.gesture, 'Freehand'),
        seg(_Tool.lineAdjust, Icons.polyline_outlined, 'Adjust'),
      ],
      selected: {_tool},
      onSelectionChanged: (s) {
        final next = s.first;
        final wasCapturing = _tool == _Tool.dragDraw ||
            _tool == _Tool.lineAdjust ||
            _tool == _Tool.moveAnchor;
        final willCapture = next == _Tool.dragDraw ||
            next == _Tool.lineAdjust ||
            next == _Tool.moveAnchor;
        if (wasCapturing != willCapture) setMapDragLocked(willCapture);
        setState(() => _tool = next);
      },
    );
  }

  /// Today's exact wide-viewport toolbar — byte-for-byte what shipped
  /// before the narrow-layout rework, never touched by it.
  List<Widget> _wideActions() => [
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
        _toolSelector(),
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
        IconButton(
          icon: const Icon(Icons.format_size),
          tooltip: 'Display size',
          onPressed: _showDisplaySize,
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.bug_report_outlined),
          tooltip: 'Diagnostics log',
          isSelected: _debugPanelOpen,
          onPressed: () => setState(() {
            _debugPanelOpen = !_debugPanelOpen;
            DebugLog.instance.enabled = _debugPanelOpen;
          }),
        ),
        const SizedBox(width: 16),
      ];

  /// Narrow-viewport toolbar: everything except the tool selector (which
  /// gets its own `AppBar.bottom` row, see [_toolSelector]) collapses into
  /// one overflow menu grouped the same way the wide toolbar's own visual
  /// spacing already groups it. The boundary-mode Finish/Cancel buttons are
  /// deliberately not in here — they're a transient in-context action, not
  /// a settings-style toggle, so they stay next to the tool selector below.
  List<Widget> _narrowActions() => [
        PopupMenuButton<String>(
          tooltip: 'Menu',
          itemBuilder: (ctx) => [
            const PopupMenuItem(value: 'new', child: Text('New trail')),
            const PopupMenuItem(value: 'open', child: Text('Open .trail file')),
            const PopupMenuItem(value: 'save', child: Text('Save as .trail file')),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'undo',
              enabled: _undoStack.isNotEmpty,
              child: const Text('Undo'),
            ),
            const PopupMenuItem(value: 'color', child: Text('Trail colour')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'clearPath', child: Text('Clear path')),
            const PopupMenuItem(value: 'clearCues', child: Text('Clear all cues')),
            const PopupMenuItem(value: 'clearAll', child: Text('Clear everything')),
            if (_hasBoundary)
              const PopupMenuItem(
                  value: 'clearBoundary', child: Text('Clear generation boundary')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'autoCues', child: Text('Suggest turn cues')),
            const PopupMenuItem(value: 'manageCues', child: Text('Manage cues')),
            const PopupMenuItem(value: 'generate', child: Text('Auto-generate a route')),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(
              value: 'followTrails',
              checked: _followTrails,
              child: const Text('Follow trails'),
            ),
            const PopupMenuItem(value: 'displaySize', child: Text('Display size')),
            CheckedPopupMenuItem(
              value: 'debug',
              checked: _debugPanelOpen,
              child: const Text('Diagnostics log'),
            ),
          ],
          onSelected: (v) => switch (v) {
            'new' => _newTrail(),
            'open' => _open(),
            'save' => _save(),
            'undo' => _undoStack.isEmpty ? null : _undo(),
            'color' => _pickColor(),
            'clearPath' => _clearPath(),
            'clearCues' => _clearCuesOnly(),
            'clearAll' => _clearAll(),
            'clearBoundary' => _clearGenBoundary(),
            'autoCues' => _autoCues(),
            'manageCues' => _showCueList(),
            'generate' => _openGenerator(),
            'followTrails' => setState(() => _followTrails = !_followTrails),
            'displaySize' => _showDisplaySize(),
            'debug' => setState(() {
                _debugPanelOpen = !_debugPanelOpen;
                DebugLog.instance.enabled = _debugPanelOpen;
              }),
            _ => null,
          },
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.sizeOf(context).width < _narrowBreakpoint;
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
        actions: isNarrow ? _narrowActions() : _wideActions(),
        bottom: isNarrow
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _toolSelector(compact: true),
                      if (_tool == _Tool.drawBoundary) ...[
                        const SizedBox(width: 8),
                        TextButton(
                            onPressed: _finishBoundary,
                            child: const Text('Finish boundary')),
                        TextButton(onPressed: _cancelBoundary, child: const Text('Cancel')),
                      ],
                    ],
                  ),
                ),
              )
            : null,
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
                onCameraIdle: _prefetchRouteGraph,
                // Rotate/tilt are a mobile walking-view concept (facing
                // direction of travel) that don't belong in a top-down
                // desktop drawing tool — confirmed unwanted live
                // (2026-08-23). Disabling both also frees up right-click-
                // drag (MapLibre's default rotate gesture) for the new
                // right-click-to-insert-anchor feature below, with no
                // native handler left to compete with it.
                compassEnabled: false,
                rotateGesturesEnabled: false,
                tiltGesturesEnabled: false,
              ),
              // Right-click-to-insert-anchor (Draw mode only) — translucent
              // (not opaque, unlike the capture overlay below) so an
              // ordinary left click/drag still reaches the map underneath
              // untouched; only the secondary mouse button is acted on, see
              // _onDrawSecondaryPointerDown. Placed before the capture
              // overlay in this Stack so that overlay (opaque, mounted
              // whenever Ctrl is also held) still takes priority over this
              // one when both could apply.
              if (_tool == _Tool.draw)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  right: _debugPanelOpen ? _debugPanelExclusion : 0,
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _onDrawSecondaryPointerDown,
                  ),
                ),
              // Geometrically excludes the debug panel's own rectangle
              // (right:16/top:16/bottom:16/width:420 below) rather than
              // relying on Flutter's Stack-order hit-testing to keep this
              // full-screen `Listener` from also seeing clicks meant for the
              // panel's buttons. A plain `Listener` doesn't participate in
              // the gesture-arena exclusivity a `GestureDetector`/`IconButton`
              // does — it can receive the *same* raw pointer event as a
              // widget drawn on top of it, confirmed live (2026-08-22) as
              // the cause of clicks on the panel's copy/clear/close buttons
              // also reaching the draw/adjust tool underneath. Making the
              // two widgets not overlap at all, geometrically, sidesteps the
              // ambiguity entirely rather than fighting hit-test ordering.
              if (_captureOverlayActive)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  right: _debugPanelOpen ? _debugPanelExclusion : 0,
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
                          ValueListenableBuilder<bool>(
                            valueListenable: Settings.instance.metric,
                            builder: (context, metric, _) => Text(
                              '${_status!.points} points · '
                              '${Settings.format(_status!.meters, metric)}',
                              style: const TextStyle(fontSize: 15),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_debugPanelOpen)
                Positioned(
                  right: _debugPanelMargin,
                  top: _debugPanelMargin,
                  bottom: _debugPanelMargin,
                  width: _debugPanelWidth,
                  // Excluding this rect from the drag-tool overlay (above)
                  // only stops *that* Flutter Listener from also seeing a
                  // click — it does nothing for MapLibreMap itself, which is
                  // a real native platform view (a genuine DOM canvas, not
                  // something Flutter paints) that can still receive clicks
                  // directly wherever Flutter's platform-view occlusion
                  // doesn't fully cover it. Confirmed live (2026-08-22): the
                  // panel's header row (icon buttons) let clicks reach the
                  // map underneath — cursor even showed MapLibre's own hand
                  // hover state — while the scrollable body happened not to.
                  // Rather than chase exactly why occlusion differs between
                  // the two, this reuses the same proven mechanism
                  // `setMapDragLocked` already uses for the drag tools:
                  // disable the real `<canvas>` element's `pointer-events`
                  // at the DOM level for as long as the mouse is anywhere
                  // over the panel, restoring whatever the *current tool*
                  // wants on exit rather than unconditionally unlocking (so
                  // this can't clobber Freehand/Adjust's own lock).
                  child: MouseRegion(
                    onEnter: (_) => setMapDragLocked(true),
                    onExit: (_) => setMapDragLocked(_captureOverlayActive),
                    child: _DebugPanel(onClose: () => setState(() {
                      _debugPanelOpen = false;
                      DebugLog.instance.enabled = false;
                    })),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Live-scrolling diagnostics panel — see [DebugLog]. Not a route/dialog (no
/// `showOpaqueDialog`/`showDialog` involved), just an ordinary opaque widget
/// placed directly in the map screen's own `Stack`, so it doesn't have (or
/// need to guard against) the translucent-barrier click-bleed-through issue
/// documented for this screen's actual dialogs. "Copy" is the intended
/// hand-off path: paste the result straight into chat.
class _DebugPanel extends StatefulWidget {
  const _DebugPanel({required this.onClose});
  final VoidCallback onClose;

  @override
  State<_DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<_DebugPanel> {
  final _scroll = ScrollController();

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: DebugLog.instance.text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Debug log copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                const Expanded(
                    child: Text('Diagnostics log',
                        style: TextStyle(fontWeight: FontWeight.bold))),
                IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy log',
                    onPressed: _copy),
                IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Clear log',
                    onPressed: () => DebugLog.instance.clear()),
                IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Close',
                    onPressed: widget.onClose),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: DebugLog.instance.version,
              builder: (context, _) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _scrollToEnd());
                final lines = DebugLog.instance.lines;
                return Scrollbar(
                  controller: _scroll,
                  child: SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(8),
                      itemCount: lines.length,
                      itemBuilder: (context, i) => Text(
                        lines[i],
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Slider + "Nx" readout for a plain multiplier setting — used by
/// [_DesktopDesignerScreenState._showDisplaySize]. Mirrors
/// `settings_screen.dart`'s `_ScaleSliderControl` (mobile's Settings
/// screen); kept as its own small copy here rather than shared since the
/// two live in different screens with no existing shared-widgets file for
/// this narrow a thing, matching how every other small helper widget in
/// this file (`_DebugPanel`, etc.) is local to whichever screen uses it.
class _ScaleSliderRow extends StatelessWidget {
  const _ScaleSliderRow({
    required this.label,
    required this.valueListenable,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final ValueListenable<double> valueListenable;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: valueListenable,
      builder: (context, value, _) => Row(
        children: [
          SizedBox(width: 170, child: Text(label)),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: ((max - min) / 0.05).round(),
              label: '${value.toStringAsFixed(2)}x',
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text('${value.toStringAsFixed(2)}x',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// A single "you're holding this" marker shown at the live cursor position
/// while dragging an anchor or cue in Move/Ctrl-move mode — see
/// [_DesktopDesignerScreenState._pushAnchorDragPreview]/
/// [_pushCueDragPreview]. Deliberately its own tiny GeoJSON source + one
/// circle layer rather than routed through [CueLayer]: that layer's full
/// teardown-and-rebuild per update (needed so its *text* layers reliably
/// refresh, see its own class doc) would be far too slow for a marker meant
/// to track the cursor on every pointer-move — a plain circle has no text,
/// so a cheap in-place [MapLibreMapController.setGeoJsonSource] position
/// update is all this ever needs.
class _DragGhostLayer {
  _DragGhostLayer(this.controller);
  final MapLibreMapController controller;

  static const _sourceId = 'dragGhost';
  static const _layerId = 'dragGhost_circle';
  bool _ready = false;

  static const _empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};

  /// Call once after the style loads, after [CueLayer.ensure] — layer add
  /// order is paint order on MapLibre, so this must come after the anchor/
  /// cue markers to actually paint on top of them while dragging.
  Future<void> ensure() async {
    if (_ready) return;
    await controller.addGeoJsonSource(_sourceId, Map.of(_empty));
    await controller.addCircleLayer(
      _sourceId,
      _layerId,
      const CircleLayerProperties(
        circleRadius: 12,
        // Matches the orange used to highlight a dragged anchor's own
        // marker elsewhere in this file — reads as "this is what's moving".
        circleColor: '#EF6C00',
        circleOpacity: 0.85,
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 2,
      ),
      enableInteraction: false,
    );
    _ready = true;
  }

  Future<void> show(LatLng pos) async {
    if (!_ready) return;
    await controller.setGeoJsonSource(_sourceId, {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [pos.longitude, pos.latitude],
          },
          'properties': <String, dynamic>{},
        },
      ],
    });
  }

  Future<void> hide() async {
    if (!_ready) return;
    await controller.setGeoJsonSource(_sourceId, Map.of(_empty));
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
