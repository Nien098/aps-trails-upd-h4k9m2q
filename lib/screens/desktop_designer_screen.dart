import 'dart:math' show Point, min, max;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/trail.dart';
import '../services/boundary_layer.dart';
import '../services/cue_gen.dart';
import '../services/cue_layer.dart';
import '../services/geo.dart';
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
/// finger, and avoids needing the same raw-pointer-drag capture
/// infrastructure mobile's drawing tools use (`_DrawGestureSurface`), which
/// this screen doesn't have.
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
enum _Tool { draw, moveAnchor, deleteAnchor, addCue, drawBoundary }

class _DesktopDesignerScreenState extends State<DesktopDesignerScreen> {
  static const _initialCamera =
      CameraPosition(target: LatLng(49.2606, -123.1140), zoom: 12);

  MapLibreMapController? _c;
  RouteLayer? _route;
  CueLayer? _points;
  BoundaryLayer? _boundary;
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

  /// Vertices placed so far in [_Tool.drawBoundary] mode, drawn live via
  /// [_boundary]. Committed to [_genBoundary] by "Finish boundary".
  final List<LatLng> _boundaryPoints = [];

  /// The finished generation-boundary outline, or null — mirrors
  /// `AuthorScreen._genBoundary`. Constrains [TrailRouter.generate] to this
  /// area when set.
  List<LatLng>? _genBoundary;

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
        await _addCueAt(coords);
      case _Tool.drawBoundary:
        setState(() => _boundaryPoints.add(coords));
        await _boundary?.setPolygon(_boundaryPoints);
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

  /// Re-routes the segment(s) touching anchor [idx] to [pos] — identical to
  /// `AuthorScreen._commitAnchorPosition`. Caller pushes undo beforehand.
  Future<void> _commitAnchorPosition(int idx, LatLng pos) async {
    final c = _c;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final anchors = _trail.anchors;
      anchors[idx] = pos;
      if (idx > 0) {
        final prev = anchors[idx - 1];
        _segments[idx] =
            _followTrails ? await TrailRouter(c).between(prev, pos) : [prev, pos];
      } else if (_segments.isNotEmpty) {
        _segments[0] = [pos];
      }
      if (idx < anchors.length - 1) {
        final next = anchors[idx + 1];
        _segments[idx + 1] =
            _followTrails ? await TrailRouter(c).between(pos, next) : [pos, next];
      }
      setState(() => _trail.path = _composePath());
      await _redraw();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              child: sorted.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No cues yet — use "Add cue" or "Suggest cues".'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
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

  Future<void> _redraw() async {
    await _route?.setRoute(_trail.path, _trail.color);
    await _points?.setMarkers([
      for (var i = 0; i < _trail.anchors.length; i++)
        CueMarker(
          position: _trail.anchors[i],
          radius: i == _pendingMoveAnchorIndex ? 9 : 7,
          color: i == _pendingMoveAnchorIndex ? '#EF6C00' : '#1565C0',
          strokeWidth: 2,
          text: '${i + 1}',
          textColor: '#1A1A1A',
        ),
      for (final cue in _trail.cues)
        CueMarker(
          position: cue.position,
          radius: 9,
          color: '#2E7D32',
          strokeWidth: 2,
          text: cue.label,
          textColor: '#1A1A1A',
        ),
    ]);
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
      _genBoundary = null;
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
      _genBoundary = null;
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
          maxHeight: 260,
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
    if (_boundaryPoints.length < 3) {
      _toast('Click at least 3 points to outline an area');
      return;
    }
    setState(() {
      _genBoundary = List.of(_boundaryPoints);
      _boundaryPoints.clear();
      _tool = _Tool.draw;
    });
    await _boundary?.setPolygon(_genBoundary);
  }

  Future<void> _cancelBoundary() async {
    setState(() {
      _boundaryPoints.clear();
      _tool = _Tool.draw;
    });
    await _boundary?.setPolygon(_genBoundary);
  }

  Future<void> _clearGenBoundary() async {
    setState(() => _genBoundary = null);
    await _boundary?.setPolygon(null);
  }

  /// Opens the auto-generate dialog and, if a choice is made, generates —
  /// mirrors `AuthorScreen._openGenerator`.
  Future<void> _openGenerator() async {
    final choice = await _showModal(() => showOpaqueDialog<_GenChoice>(
          context,
          maxHeight: 620,
          builder: (_) => _GeneratorDialog(hasBoundary: _genBoundary != null),
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
      final boundary = _genBoundary;
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
        if (boundary != null) _genBoundary = null;
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
              if (_genBoundary != null)
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
            ],
            selected: {_tool},
            onSelectionChanged: (s) => setState(() {
              _tool = s.first;
              _pendingMoveAnchorIndex = null;
            }),
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
