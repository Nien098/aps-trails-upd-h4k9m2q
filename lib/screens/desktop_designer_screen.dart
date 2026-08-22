import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/trail.dart';
import '../services/cue_gen.dart';
import '../services/cue_layer.dart';
import '../services/geo.dart';
import '../services/route_layer.dart';
import '../services/trail_router.dart';
import '../services/web_file_io.dart';
import '../services/web_map_style.dart';

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
class DesktopDesignerScreen extends StatefulWidget {
  const DesktopDesignerScreen({super.key});

  @override
  State<DesktopDesignerScreen> createState() => _DesktopDesignerScreenState();
}

class _DesktopDesignerScreenState extends State<DesktopDesignerScreen> {
  static const _initialCamera =
      CameraPosition(target: LatLng(49.2606, -123.1140), zoom: 12);

  MapLibreMapController? _c;
  RouteLayer? _route;
  CueLayer? _points;
  Trail _trail = Trail(name: 'New trail', regionId: 'web-design');

  /// Per-anchor-hop coordinate arrays, one entry per anchor, aligned by
  /// index — same split `AuthorScreen._segments` uses, so a routed hop's
  /// real trail geometry survives undo/redo instead of collapsing back to
  /// a straight line. [_composePath] flattens this into `_trail.path`.
  final List<List<LatLng>> _segments = [];

  bool _drawing = true;

  /// Mirrors `AuthorScreen._follow`: when on, each new click snaps onto
  /// the nearest trail/road currently rendered and routes along real
  /// geometry from the previous anchor; when off, clicks place raw
  /// straight-line points (v1's original behaviour), useful off the
  /// mapped network or when a hand-drawn straight line is wanted on
  /// purpose.
  bool _followTrails = true;

  bool _busy = false;
  String? _status;

  void _onMapCreated(MapLibreMapController c) => _c = c;

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null) return;
    _route = RouteLayer(c);
    await _route!.ensure();
    _points = CueLayer(c, id: 'designerPoints');
    await _points!.ensure();
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

  Future<void> _onMapClick(Point<double> _, LatLng coords) async {
    final c = _c;
    if (!_drawing || c == null || _busy) return;
    _busy = true;
    try {
      final from = _trail.anchors.isEmpty ? null : _trail.anchors.last;
      List<LatLng> segment;
      LatLng end;
      if (_followTrails) {
        final conn = await TrailRouter(c).connect(from: from, to: coords);
        end = conn.end;
        segment = conn.polyline;
      } else {
        end = coords;
        segment = from == null ? [coords] : [from, coords];
      }
      setState(() {
        _trail.anchors.add(end);
        _segments.add(segment);
        _trail.path = _composePath();
      });
      await _redraw();
    } finally {
      _busy = false;
    }
  }

  Future<void> _redraw() async {
    await _route?.setRoute(_trail.path, _trail.color);
    await _points?.setMarkers([
      for (var i = 0; i < _trail.anchors.length; i++)
        CueMarker(
          position: _trail.anchors[i],
          radius: 7,
          color: '#1565C0',
          strokeWidth: 2,
          text: '${i + 1}',
          textColor: '#1A1A1A',
        ),
      for (final cue in _trail.cues)
        CueMarker(
          position: cue.position,
          radius: 9,
          color: '#EF6C00',
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

  Future<void> _undoLastPoint() async {
    if (_trail.anchors.isEmpty) return;
    setState(() {
      _trail.anchors.removeLast();
      if (_segments.isNotEmpty) _segments.removeLast();
      _trail.path = _composePath();
    });
    await _redraw();
  }

  Future<void> _newTrail() async {
    setState(() {
      _trail = Trail(name: 'New trail', regionId: 'web-design');
      _segments.clear();
    });
    await _redraw();
  }

  /// Splits an opened trail's saved [path] back into per-anchor segments
  /// (so routed geometry survives undo after opening a file) — same idea
  /// as `AuthorScreen._rebuildSegments`, without that method's extra
  /// `_densify` step, which desktop v1 has no deforming/grab-and-bend tool
  /// to need. Legacy trails with no separate `anchors` treat every path
  /// point as its own anchor.
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
    });
    await _redraw();
  }

  void _save() => WebTrailIo.save(_trail);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_trail.name),
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
            tooltip: 'Undo last point',
            icon: const Icon(Icons.undo),
            onPressed: _trail.anchors.isEmpty ? null : _undoLastPoint,
          ),
          IconButton(
            tooltip: 'Suggest turn cues',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _autoCues,
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Click to draw'),
            selected: _drawing,
            onSelected: (v) => setState(() => _drawing = v),
          ),
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
              if (_status != null)
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Text(_status!, style: const TextStyle(fontSize: 15)),
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
