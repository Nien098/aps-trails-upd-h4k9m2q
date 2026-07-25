import 'dart:math' show Point, sqrt;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../cue_style.dart';
import '../models/region.dart';
import '../models/trail.dart';
import '../trail_colors.dart';
import '../services/cue_gen.dart';
import '../services/geo.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/trail_router.dart';
import '../services/trail_store.dart';
import '../widgets/base_map.dart';

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
  bool _cueMode = false;
  bool _dirty = false;
  bool _follow = true; // auto-follow trail lines between anchors
  bool _busy = false; // a routing query is in flight

  /// The cue awaiting a new position (long-pressed in Cue mode), or null.
  Cue? _moving;
  /// When true, the next tap places [_moving] exactly where tapped; when
  /// false (default), it snaps onto the nearest point of the drawn path.
  bool _freeMove = false;

  /// Route segments parallel to [_trail.anchors]: segment i connects anchor
  /// i-1 → i (segment 0 is just [anchor0]). Undo drops the last of each.
  final List<List<LatLng>> _segments = [];

  // Map drawn markers back to their data for tap-to-edit / tap-to-delete.
  final Map<String, Cue> _symbolToCue = {};
  final Map<String, Cue> _circleToCue = {};
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
  /// - Cue circle in Draw-path mode → link that cue into the trail (connect
  ///   the dots), routing to its exact position.
  /// - Cue circle in Add-cue mode → edit / delete the cue (unless a move is
  ///   already pending, see [_moving] — then all circle taps are ignored so
  ///   the user must tap empty map to place it, or Cancel).
  /// - Anchor circle in Draw-path mode → continue/return the trail *through*
  ///   that existing point (so a loop can retrace its own line). Long-press an
  ///   anchor to delete it instead.
  Future<void> _onCircleTapped(Circle circle) async {
    if (_moving != null) return;
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
  /// long-pressing an anchor deletes it (re-joining the trail) — deletion is
  /// off single-tap there so tapping can retrace an existing line instead.
  Future<void> _onMapLongClick(Point<double> screen, LatLng _) async {
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
    if (best >= 0) await _confirmDeleteAnchor(best);
  }

  Future<void> _onStyleLoaded() async {
    _routeLayer = RouteLayer(_c!);
    await _routeLayer!.ensure();
    await _redraw();
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
    } else {
      await _addAnchor(latlng);
    }
  }

  /// Opens the cue editor at [position] and, if saved, adds the cue.
  Future<void> _addCueAt(LatLng position) async {
    final cue = await _showCueEditor(position: position);
    if (cue == null) return;
    setState(() => _trail.cues.add(cue));
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
    final cue = _symbolToCue[s.id];
    if (cue != null) await _editCue(cue);
  }

  Future<void> _editCue(Cue cue) async {
    final result = await _showCueEditor(position: cue.position, existing: cue);
    if (result == _deletedSentinel) {
      setState(() => _trail.cues.remove(cue));
    } else if (result != null) {
      setState(() {
        cue
          ..type = result.type
          ..label = result.label
          ..spoken = result.spoken
          ..radiusMeters = result.radiusMeters
          ..onReturn = result.onReturn
          ..returnEnabled = result.returnEnabled
          ..returnType = result.returnType
          ..returnLabel = result.returnLabel
          ..returnSpoken = result.returnSpoken;
      });
    } else {
      return;
    }
    _dirty = true;
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
    _circleToAnchor.clear();

    // The route line + directional arrows (GeoJSON layer, taps pass through).
    await _routeLayer?.setRoute(_trail.path, _trail.color);

    // Anchor markers: start is green, the last (drawing-from) anchor is a
    // larger highlighted ring, the rest are small blue dots. Tap to delete.
    final anchors = _trail.anchors;
    for (var i = 0; i < anchors.length; i++) {
      final isLast = i == anchors.length - 1;
      final isFirst = i == 0;
      final color = isFirst ? '#2E7D32' : '#1565C0';
      final circle = await c.addCircle(CircleOptions(
        geometry: anchors[i],
        circleRadius: isLast ? 12 : 7,
        circleColor: isLast ? '#ffffff' : color,
        circleStrokeColor: isLast ? '#1565C0' : '#ffffff',
        circleStrokeWidth: isLast ? 5 : 2,
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

    for (final cue in _trail.cues) {
      final isMoving = identical(cue, _moving);
      final cueCircle = await c.addCircle(CircleOptions(
        geometry: cue.position,
        circleRadius: isMoving ? 14 : 11,
        circleColor: cueColorHex(cue.type),
        // Ring colour encodes the cue's leg (teal=both, purple=return); a cue
        // pending a move is highlighted gold so it's obvious which one it is.
        circleStrokeColor: isMoving ? '#FFC107' : cueStrokeHex(cue),
        circleStrokeWidth: isMoving ? 5 : (cue.onReturn || cue.returnEnabled ? 4 : 3),
      ));
      _circleToCue[cueCircle.id] = cue;
      final symbol = await c.addSymbol(SymbolOptions(
        geometry: cue.position,
        textField: cueMapLabel(cue),
        textSize: 15,
        textColor: '#1a1a1a',
        textHaloColor: '#ffffff',
        textHaloWidth: 2,
        textAnchor: 'top',
        textOffset: const Offset(0, 1.1),
      ));
      _symbolToCue[symbol.id] = cue;
    }
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
      final cue = await _showCueEditor(position: here);
      if (!mounted || cue == null) return;
      setState(() => _trail.cues.add(cue));
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
    final choice = await showModalBottomSheet<_GenChoice>(
      context: context,
      builder: (_) => const _GeneratorSheet(),
    );
    if (choice == null || !mounted) return;
    if (_trail.anchors.isNotEmpty &&
        !await _confirm('Replace the current path with a generated one?')) {
      return;
    }
    await _generateRoute(choice);
  }

  Future<void> _generateRoute(_GenChoice choice) async {
    final c = _c;
    if (c == null || _busy) return;
    final size = MediaQuery.of(context).size;
    setState(() => _busy = true);
    try {
      final bounds = await c.getVisibleRegion();
      final center = LatLng(
        (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
        (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
      );
      final viewport = Rect.fromLTWH(0, 0, size.width, size.height);
      final route = await TrailRouter(c).generate(
        center: center,
        viewport: viewport,
        targetMeters: choice.meters,
        preferLoop: choice.loop,
      );
      if (!mounted) return;
      if (route == null) {
        _toast('No trails found here — zoom to a trail area and try again');
        return;
      }
      setState(() {
        _trail.path = route.path;
        _segments
          ..clear()
          ..addAll(_rebuildSegments(route.path, route.anchors));
        if (choice.cues) {
          _trail.cues
            ..clear()
            // Out-and-backs retrace themselves, so tag the return-leg cues.
            ..addAll(suggestCues(route.path, markReturnHalf: !route.loop));
        }
        _dirty = true;
      });
      await _redraw();
      final dist = Settings.instance.formatDistance(route.meters);
      final cueNote = choice.cues ? ' · ${_trail.cues.length} cues' : '';
      _toast(
          '${route.loop ? "Loop" : "Out-and-back"} generated — $dist$cueNote');
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
          padding: const EdgeInsets.all(20),
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

  static final Cue _deletedSentinel =
      Cue(type: CueType.note, position: const LatLng(0, 0));

  /// Shows the cue editor sheet. Returns the edited cue, [_deletedSentinel]
  /// if deleted, or null if cancelled.
  Future<Cue?> _showCueEditor({required LatLng position, Cue? existing}) {
    return showModalBottomSheet<Cue>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true, // never draw under the status bar
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _CueEditorSheet(
          position: position,
          existing: existing,
          onDelete: existing == null
              ? null
              : () => Navigator.pop(ctx, _deletedSentinel),
        ),
      ),
    );
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
                heroTag: 'generate',
                tooltip: 'Auto-generate a trail here',
                onPressed: _busy ? null : _openGenerator,
                child: const Icon(Icons.auto_awesome),
              ),
            ),
            Positioned(
              right: 12,
              top: 186,
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
              left: 12,
              right: 12,
              // Lift above the Android nav bar (0 on gesture-nav phones).
              bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
              child: _ModeBar(
                cueMode: _cueMode,
                follow: _follow,
                anchorCount: _trail.anchors.length,
                cueCount: _trail.cues.length,
                lengthLabel: Settings.instance.formatDistance(
                    pathLength(_trail.path)),
                freeMove: _freeMove,
                onModeChanged: (v) => setState(() => _cueMode = v),
                onFollowChanged: (v) => setState(() => _follow = v),
                onFreeMoveChanged: (v) => setState(() => _freeMove = v),
              ),
            ),
            if (_moving != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 190 + MediaQuery.viewPaddingOf(context).bottom,
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
          ],
        ),
      ),
    );
  }
}

/// The Path / Cue mode toggle, auto-follow switch, and a hint line.
class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.cueMode,
    required this.follow,
    required this.anchorCount,
    required this.cueCount,
    required this.lengthLabel,
    required this.freeMove,
    required this.onModeChanged,
    required this.onFollowChanged,
    required this.onFreeMoveChanged,
  });

  final bool cueMode;
  final bool follow;
  final int anchorCount;
  final int cueCount;
  final String lengthLabel;
  final bool freeMove;
  final ValueChanged<bool> onModeChanged;
  final ValueChanged<bool> onFollowChanged;
  final ValueChanged<bool> onFreeMoveChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<bool>(
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
            // Same slot either way (so the bar height — and thus the Draw/Cue
            // buttons — never jump between modes): Follow-trails in Draw mode,
            // Free-placement in Cue mode.
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
                  : 'Tap map to add • tap a point to route through it • long-press to delete • $anchorCount ${anchorCount == 1 ? "point" : "points"}',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// A chosen target length + shape for auto-generation.
class _GenChoice {
  const _GenChoice(this.meters, this.loop, this.cues);
  final double meters;
  final bool loop;

  /// Whether to auto-drop turn cues along the generated route.
  final bool cues;
}

/// Bottom sheet to pick a walk length and loop vs out-and-back, then generate.
class _GeneratorSheet extends StatefulWidget {
  const _GeneratorSheet();

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

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = Settings.instance;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Auto-generate a trail', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('Builds a route from the trails shown on screen now.',
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
                  Text('Short', style: TextStyle(color: Color(0xFF4A4A4A))),
                  Spacer(),
                  Text('Medium', style: TextStyle(color: Color(0xFF4A4A4A))),
                  Spacer(),
                  Text('Long', style: TextStyle(color: Color(0xFF4A4A4A))),
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
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _cues,
              onChanged: (v) => setState(() => _cues = v ?? true),
              secondary: const Icon(Icons.signpost_outlined),
              title: const Text('Add turn directions'),
              subtitle: const Text('Drops spoken "turn left / right" cues'),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    Navigator.pop(context, _GenChoice(_meters, _loop, _cues)),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Generate'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which leg(s) a cue applies to, chosen in the editor.
enum _CueWhen { outbound, returnLeg, both }

/// Bottom-sheet editor for a single cue: type, label, spoken text, radius.
class _CueEditorSheet extends StatefulWidget {
  const _CueEditorSheet({
    required this.position,
    this.existing,
    this.onDelete,
  });

  final LatLng position;
  final Cue? existing;
  final VoidCallback? onDelete;

  @override
  State<_CueEditorSheet> createState() => _CueEditorSheetState();
}

class _CueEditorSheetState extends State<_CueEditorSheet> {
  late CueType _type;
  late TextEditingController _label;
  late TextEditingController _spoken;
  late double _radius;
  late _CueWhen _when;

  // The second action for a "Both directions" node.
  late CueType _returnType;
  late TextEditingController _returnLabel;
  late TextEditingController _returnSpoken;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _type = e?.type ?? CueType.left;
    _label = TextEditingController(text: e?.label ?? _type.label);
    _spoken = TextEditingController(text: e?.spoken ?? _type.defaultSpoken);
    _radius = e?.radiusMeters ?? 25;
    _when = e == null
        ? _CueWhen.outbound
        : e.returnEnabled
            ? _CueWhen.both
            : e.onReturn
                ? _CueWhen.returnLeg
                : _CueWhen.outbound;
    _returnType = e?.returnType ?? CueType.right;
    _returnLabel = TextEditingController(text: e?.returnLabel ?? _returnType.label);
    _returnSpoken =
        TextEditingController(text: e?.returnSpoken ?? _returnType.defaultSpoken);
  }

  @override
  void dispose() {
    _label.dispose();
    _spoken.dispose();
    _returnLabel.dispose();
    _returnSpoken.dispose();
    super.dispose();
  }

  /// Refresh return label/spoken when the return type changes, unless the user
  /// customised them away from the old type's defaults.
  void _selectReturnType(CueType t) {
    setState(() {
      if (_returnLabel.text == _returnType.label) _returnLabel.text = t.label;
      if (_returnSpoken.text == _returnType.defaultSpoken) {
        _returnSpoken.text = t.defaultSpoken;
      }
      _returnType = t;
    });
  }

  /// When the type changes, refresh label/spoken if the user hasn't customised
  /// them away from the previous type's defaults.
  void _selectType(CueType t) {
    setState(() {
      if (_label.text == _type.label) _label.text = t.label;
      if (_spoken.text == _type.defaultSpoken) _spoken.text = t.defaultSpoken;
      _type = t;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The sheet fills at most 88% of the screen (useSafeArea keeps it clear of
    // the status bar); the fields scroll while the actions stay pinned above
    // the nav bar.
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            Text(widget.existing == null ? 'New cue' : 'Edit cue',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in CueType.values)
                  ChoiceChip(
                    selected: _type == t,
                    avatar: Icon(cueIcon(t),
                        size: 18,
                        color: _type == t ? Colors.white : cueColor(t)),
                    label: Text(t.label),
                    selectedColor: cueColor(t),
                    labelStyle: TextStyle(
                        color: _type == t ? Colors.white : null),
                    onSelected: (_) => _selectType(t),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Map label (short)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _spoken,
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Spoken direction (read aloud)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('Trigger distance: ${_radius.round()} m'),
            Slider(
              value: _radius,
              min: 10,
              max: 60,
              divisions: 10,
              label: '${_radius.round()} m',
              onChanged: (v) => setState(() => _radius = v),
            ),
            const SizedBox(height: 12),
            const Text('When does this fire?',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<_CueWhen>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _CueWhen.outbound, label: Text('Way out')),
                ButtonSegment(value: _CueWhen.returnLeg, label: Text('Way back')),
                ButtonSegment(value: _CueWhen.both, label: Text('Both')),
              ],
              selected: {_when},
              onSelectionChanged: (s) => setState(() => _when = s.first),
            ),
            if (_when == _CueWhen.both) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.u_turn_right, size: 20),
                  const SizedBox(width: 8),
                  Text('On the way back',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 4),
              const Text('The direction to give at this same spot on the return.',
                  style: TextStyle(color: Color(0xFF4A4A4A))),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in CueType.values)
                    ChoiceChip(
                      selected: _returnType == t,
                      avatar: Icon(cueIcon(t),
                          size: 18,
                          color: _returnType == t ? Colors.white : cueColor(t)),
                      label: Text(t.label),
                      selectedColor: cueColor(t),
                      labelStyle: TextStyle(
                          color: _returnType == t ? Colors.white : null),
                      onSelected: (_) => _selectReturnType(t),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _returnLabel,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Return map label (short)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _returnSpoken,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Return spoken direction (read aloud)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                if (widget.onDelete != null)
                  TextButton.icon(
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.red),
                  ),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    Cue(
                      type: _type,
                      position: widget.position,
                      label: _label.text.trim().isEmpty
                          ? _type.label
                          : _label.text.trim(),
                      spoken: _spoken.text.trim(),
                      radiusMeters: _radius,
                      onReturn: _when == _CueWhen.returnLeg,
                      returnEnabled: _when == _CueWhen.both,
                      returnType: _returnType,
                      returnLabel: _returnLabel.text.trim().isEmpty
                          ? _returnType.label
                          : _returnLabel.text.trim(),
                      returnSpoken: _returnSpoken.text.trim(),
                    ),
                  ),
                  child: const Text('Save cue'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
