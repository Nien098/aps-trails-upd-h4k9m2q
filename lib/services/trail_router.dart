import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'geo.dart';
import 'settings.dart';

/// A trail route generated automatically from the visible trail network.
class GeneratedRoute {
  GeneratedRoute({
    required this.path,
    required this.anchors,
    required this.meters,
    required this.loop,
  });

  /// The full followed polyline.
  final List<LatLng> path;

  /// Key waypoints along [path] (start, turnaround/apex, end) so the trail
  /// stays editable with the normal anchor/undo/delete machinery.
  final List<LatLng> anchors;

  /// Total length of [path] in metres.
  final double meters;

  /// True when the route returns by a different way (a loop) rather than
  /// retracing itself (an out-and-back).
  final bool loop;
}

/// Result of connecting a new anchor to the trail network.
class TrailConnection {
  TrailConnection(this.end, this.polyline, this.followed);

  /// The (possibly snapped-to-trail) position of the new anchor.
  final LatLng end;

  /// The polyline from the previous anchor to [end]; follows real trail
  /// geometry when [followed] is true, otherwise a straight segment.
  final List<LatLng> polyline;

  /// Whether the segment traced actual trail geometry (vs a straight fallback).
  final bool followed;
}

/// Builds a routable graph from the trail/road line features currently drawn
/// on the map, then snaps taps to trails and traces routes between anchors.
class TrailRouter {
  TrailRouter(this.controller);

  final MapLibreMapController controller;

  /// Style layers whose line geometry can be walked along.
  static const _walkableLayers = ['trails', 'sidewalks', 'roads-fill'];

  /// Max distance (m) a tap may be from a trail to snap onto it.
  static const _snapMeters = 30.0;

  /// Reject routed detours longer than this multiple of the straight distance.
  /// User-adjustable (Settings → Safety & battery) since a tight factor is
  /// safe for [record_trail_screen]'s cleanup pass (closely-spaced simplified
  /// points, where a loose factor lets the shortest-path search wander through
  /// a nearby loop/cul-de-sac) but too strict for hand-drawn taps around a
  /// real switchback or bend, which can legitimately be 3-4x+ the straight
  /// line distance.
  static double get _maxDetourFactor => Settings.instance.detourFactor.value;

  /// Connects a new [to] tap to the network, routing from [from] if given.
  Future<TrailConnection> connect({LatLng? from, required LatLng to}) async {
    final rect = await _rectAround(from, to);
    final graph = await _buildGraph(rect);

    // Snap the new anchor onto the nearest trail (Level A).
    final snap = graph.nearestOnEdge(to);
    final end = (snap != null && snap.meters <= _snapMeters) ? snap.point : to;

    if (from == null) {
      return TrailConnection(end, [end], false);
    }

    // Trace the trail between the two anchors (Level B).
    final line = graph.route(from, end);
    if (line == null) {
      return TrailConnection(end, [from, end], false);
    }

    // Guard against absurd detours (disconnected-but-nearby trails).
    final straight = metersBetween(from, end);
    final routed = _polylineLength(line);
    if (straight > 5 && routed > straight * _maxDetourFactor) {
      return TrailConnection(end, [from, end], false);
    }
    return TrailConnection(end, line, true);
  }

  /// Auto-generates a walkable route from the trails currently visible in
  /// [viewport] (a screen-pixel rect covering the map). Starts near [center],
  /// aims for [targetMeters] total length, and returns a loop when [preferLoop]
  /// is set and a reasonable different-return path exists — otherwise an
  /// out-and-back. Returns null when no usable trail network is in view.
  Future<GeneratedRoute?> generate({
    required LatLng center,
    required Rect viewport,
    required double targetMeters,
    bool preferLoop = true,
  }) async {
    final graph = await _buildGraph(viewport);
    final start = graph.spliceTempNode(center, 'GEN');
    if (start.isEmpty) return null;

    // Shortest-path tree from the start, to find a good turnaround point.
    final (dist, prev) = graph.dijkstraTree(start);
    final half = targetMeters / 2;

    String? apex;
    double bestScore = double.infinity;
    dist.forEach((key, d) {
      if (key == start || d <= 0) return;
      final score = (d - half).abs();
      if (score < bestScore) {
        bestScore = score;
        apex = key;
      }
    });
    // Need meaningful reach; if the nearest trails are a tiny stub, bail.
    if (apex == null || (dist[apex] ?? 0) < 150) return null;

    final outKeys = graph.tracePath(prev, start, apex!);
    if (outKeys.length < 2) return null;

    List<String>? backKeys;
    if (preferLoop) {
      // Penalise re-using the outbound edges so the return finds a new way.
      final used = <String>{};
      for (var i = 0; i < outKeys.length - 1; i++) {
        used.add(_Graph.edgeId(outKeys[i], outKeys[i + 1]));
      }
      backKeys = graph.routeAvoiding(apex!, start, used, penalty: 5.0);
      // Only accept a genuine loop: it must actually differ from retracing.
      if (backKeys != null) {
        final overlap = _overlapFraction(outKeys, backKeys);
        if (overlap > 0.6) backKeys = null;
      }
    }

    final loop = backKeys != null;
    final routeKeys = loop
        ? [...outKeys, ...backKeys.skip(1)]
        : [...outKeys, ...outKeys.reversed.skip(1)];

    final path = [for (final k in routeKeys) graph.nodeAt(k)];
    if (path.length < 2) return null;

    final apexPoint = graph.nodeAt(apex!);
    final anchors = loop
        ? [path.first, apexPoint, path.last]
        : [path.first, apexPoint, path.first];

    return GeneratedRoute(
      path: path,
      anchors: anchors,
      meters: _polylineLength(path),
      loop: loop,
    );
  }

  /// Fraction of [a]'s edges that also appear in [b] (both undirected).
  static double _overlapFraction(List<String> a, List<String> b) {
    if (a.length < 2) return 0;
    final bEdges = <String>{};
    for (var i = 0; i < b.length - 1; i++) {
      bEdges.add(_Graph.edgeId(b[i], b[i + 1]));
    }
    var shared = 0;
    for (var i = 0; i < a.length - 1; i++) {
      if (bEdges.contains(_Graph.edgeId(a[i], a[i + 1]))) shared++;
    }
    return shared / (a.length - 1);
  }

  /// Screen-space rect enclosing the endpoints (with padding), used to bound
  /// the feature query. Uses toScreenLocation so the coordinate space matches
  /// what queryRenderedFeaturesInRect expects.
  Future<Rect> _rectAround(LatLng? a, LatLng b) async {
    final pb = await controller.toScreenLocation(b);
    var minX = pb.x.toDouble(), maxX = pb.x.toDouble();
    var minY = pb.y.toDouble(), maxY = pb.y.toDouble();
    if (a != null) {
      final pa = await controller.toScreenLocation(a);
      minX = math.min(minX, pa.x.toDouble());
      maxX = math.max(maxX, pa.x.toDouble());
      minY = math.min(minY, pa.y.toDouble());
      maxY = math.max(maxY, pa.y.toDouble());
    }
    const pad = 350.0;
    return Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
  }

  /// Routes between two existing anchors WITHOUT re-snapping them (used when
  /// re-joining the trail after a middle anchor is deleted). Falls back to a
  /// straight segment when there's no connected trail.
  Future<List<LatLng>> between(LatLng from, LatLng to) async {
    final graph = await _buildGraph(await _rectAround(from, to));
    final line = graph.route(from, to);
    if (line == null) return [from, to];
    final straight = metersBetween(from, to);
    final routed = _polylineLength(line);
    if (straight > 5 && routed > straight * _maxDetourFactor) return [from, to];
    return line;
  }

  Future<_Graph> _buildGraph(Rect rect) async {
    final raw = await controller.queryRenderedFeaturesInRect(
      rect,
      _walkableLayers,
      null,
    );
    final graph = _Graph();
    for (final f in raw) {
      final feature = f is String ? jsonDecode(f) : f;
      if (feature is! Map) continue;
      final geom = feature['geometry'];
      if (geom is! Map) continue;
      final type = geom['type'];
      final coords = geom['coordinates'];
      if (type == 'LineString') {
        graph.addLine(coords);
      } else if (type == 'MultiLineString') {
        for (final line in coords) {
          graph.addLine(line);
        }
      }
    }
    // A single real-world trail can arrive as several separate LineString
    // features (e.g. split around a line-label's placement point, or by tile
    // clipping) whose "shared" endpoint differs by a few metres between
    // fragments — just outside addLine's ~1m key-rounding tolerance. Left
    // alone, that gap forces routing to detour via whatever junction node IS
    // connected, producing an odd kink right at the split (often exactly
    // under the trail's name label). Merge close-enough fragment endpoints
    // so the trail reads as one continuous edge again.
    graph._mergeNearbyNodes(4.0);
    return graph;
  }

  static double _polylineLength(List<LatLng> pts) {
    var total = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      total += metersBetween(pts[i], pts[i + 1]);
    }
    return total;
  }
}

class _Edge {
  _Edge(this.to, this.weight);
  final String to;
  final double weight;
}

class _Seg {
  _Seg(this.aKey, this.bKey, this.a, this.b);
  final String aKey, bKey;
  final LatLng a, b;
}

/// A lightweight routing graph keyed by rounded coordinates (~1 m tolerance),
/// so line segments that share endpoints across tiles connect up.
class _Graph {
  final Map<String, LatLng> nodes = {};
  final Map<String, List<_Edge>> adj = {};
  final List<_Seg> _segments = [];

  static String _key(double lat, double lng) =>
      '${lat.toStringAsFixed(5)}_${lng.toStringAsFixed(5)}';

  void addLine(dynamic coords) {
    if (coords is! List) return;
    LatLng? prev;
    String? prevKey;
    for (final c in coords) {
      if (c is! List || c.length < 2) continue;
      final lng = (c[0] as num).toDouble();
      final lat = (c[1] as num).toDouble();
      final p = LatLng(lat, lng);
      final k = _key(lat, lng);
      nodes.putIfAbsent(k, () => p);
      if (prev != null && prevKey != null && prevKey != k) {
        final w = metersBetween(prev, p);
        (adj[prevKey] ??= []).add(_Edge(k, w));
        (adj[k] ??= []).add(_Edge(prevKey, w));
        _segments.add(_Seg(prevKey, k, prev, p));
      }
      prev = p;
      prevKey = k;
    }
  }

  /// Union-finds together any two nodes within [toleranceMeters] of each
  /// other, then rewrites nodes/edges/segments onto the canonical (root) key
  /// of each group. Fixes near-miss disconnects between fragments of what is
  /// really one continuous trail (see [_buildGraph]).
  void _mergeNearbyNodes(double toleranceMeters) {
    final keys = nodes.keys.toList();
    final parent = <String, String>{for (final k in keys) k: k};
    String find(String k) {
      var r = k;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      parent[k] = r;
      return r;
    }

    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        if (metersBetween(nodes[keys[i]]!, nodes[keys[j]]!) <=
            toleranceMeters) {
          final ri = find(keys[i]), rj = find(keys[j]);
          if (ri != rj) parent[ri] = rj;
        }
      }
    }

    final newNodes = <String, LatLng>{};
    for (final k in keys) {
      newNodes.putIfAbsent(find(k), () => nodes[k]!);
    }
    final newAdj = <String, List<_Edge>>{};
    for (final entry in adj.entries) {
      final fromRoot = find(entry.key);
      for (final e in entry.value) {
        final toRoot = find(e.to);
        if (fromRoot == toRoot) continue;
        (newAdj[fromRoot] ??= []).add(_Edge(toRoot, e.weight));
      }
    }
    for (var i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      _segments[i] = _Seg(find(s.aKey), find(s.bKey), s.a, s.b);
    }
    nodes
      ..clear()
      ..addAll(newNodes);
    adj
      ..clear()
      ..addAll(newAdj);
  }

  ({LatLng point, double meters, _Seg seg})? _nearestSeg(LatLng p) {
    ({LatLng point, double meters, _Seg seg})? best;
    for (final seg in _segments) {
      final r = _nearestOnSegment(p, seg.a, seg.b);
      if (best == null || r.meters < best.meters) {
        best = (point: r.point, meters: r.meters, seg: seg);
      }
    }
    return best;
  }

  /// Nearest point lying on any graph edge, with its distance in metres.
  ({LatLng point, double meters})? nearestOnEdge(LatLng p) {
    final r = _nearestSeg(p);
    return r == null ? null : (point: r.point, meters: r.meters);
  }

  static String edgeId(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  LatLng nodeAt(String key) => nodes[key]!;

  /// Shortest-path tree (distances + predecessors) from [startKey] over the
  /// whole graph, used to pick a turnaround point at a target distance.
  (Map<String, double>, Map<String, String>) dijkstraTree(String startKey) {
    final dist = <String, double>{startKey: 0};
    final prev = <String, String>{};
    final heap = _MinHeap()..push(startKey, 0);
    while (heap.isNotEmpty) {
      final (node, d) = heap.pop();
      if (d > (dist[node] ?? double.infinity)) continue;
      for (final e in adj[node] ?? const <_Edge>[]) {
        final nd = d + e.weight;
        if (nd < (dist[e.to] ?? double.infinity)) {
          dist[e.to] = nd;
          prev[e.to] = node;
          heap.push(e.to, nd);
        }
      }
    }
    return (dist, prev);
  }

  /// Rebuilds the key sequence [startKey]..[goalKey] from a [prev] map.
  List<String> tracePath(Map<String, String> prev, String startKey, String goalKey) {
    final keys = <String>[];
    String? k = goalKey;
    while (k != null) {
      keys.insert(0, k);
      if (k == startKey) break;
      k = prev[k];
    }
    if (keys.isEmpty || keys.first != startKey) return const [];
    return keys;
  }

  /// Dijkstra from [startKey] to [goalKey] that multiplies the cost of any edge
  /// in [avoid] by [penalty], steering the return leg onto fresh trails.
  List<String>? routeAvoiding(
    String startKey,
    String goalKey,
    Set<String> avoid, {
    double penalty = 5.0,
  }) {
    final dist = <String, double>{startKey: 0};
    final prev = <String, String>{};
    final heap = _MinHeap()..push(startKey, 0);
    while (heap.isNotEmpty) {
      final (node, d) = heap.pop();
      if (node == goalKey) break;
      if (d > (dist[node] ?? double.infinity)) continue;
      for (final e in adj[node] ?? const <_Edge>[]) {
        final w = avoid.contains(edgeId(node, e.to)) ? e.weight * penalty : e.weight;
        final nd = d + w;
        if (nd < (dist[e.to] ?? double.infinity)) {
          dist[e.to] = nd;
          prev[e.to] = node;
          heap.push(e.to, nd);
        }
      }
    }
    if (!dist.containsKey(goalKey)) return null;
    return tracePath(prev, startKey, goalKey);
  }

  /// Splices [p] into the graph as a temp node on its nearest segment,
  /// connected to that segment's endpoints. Returns the temp key (or '').
  String spliceTempNode(LatLng p, String tag) {
    final near = _nearestSeg(p);
    if (near == null) return '';
    final key = 'TMP_$tag';
    nodes[key] = near.point;
    final wa = metersBetween(near.point, near.seg.a);
    final wb = metersBetween(near.point, near.seg.b);
    (adj[key] ??= [])
      ..add(_Edge(near.seg.aKey, wa))
      ..add(_Edge(near.seg.bKey, wb));
    (adj[near.seg.aKey] ??= []).add(_Edge(key, wa));
    (adj[near.seg.bKey] ??= []).add(_Edge(key, wb));
    return key;
  }

  /// Dijkstra between [from] and [to], each spliced onto its nearest trail.
  /// Returns the followed polyline (including endpoints) or null if no path.
  List<LatLng>? route(LatLng from, LatLng to) {
    final startKey = spliceTempNode(from, 'FROM');
    final goalKey = spliceTempNode(to, 'TO');
    if (startKey.isEmpty || goalKey.isEmpty) return null;

    final dist = <String, double>{startKey: 0};
    final prev = <String, String>{};
    final heap = _MinHeap()..push(startKey, 0);

    while (heap.isNotEmpty) {
      final (node, d) = heap.pop();
      if (node == goalKey) break;
      if (d > (dist[node] ?? double.infinity)) continue;
      for (final e in adj[node] ?? const <_Edge>[]) {
        final nd = d + e.weight;
        if (nd < (dist[e.to] ?? double.infinity)) {
          dist[e.to] = nd;
          prev[e.to] = node;
          heap.push(e.to, nd);
        }
      }
    }

    if (!dist.containsKey(goalKey)) return null;

    final keys = <String>[];
    String? k = goalKey;
    while (k != null) {
      keys.insert(0, k);
      if (k == startKey) break;
      k = prev[k];
    }
    if (keys.isEmpty || keys.first != startKey) return null;
    return [from, for (final key in keys) nodes[key]!, to];
  }
}

/// Nearest point on segment [a]–[b] to [p] via local equirectangular projection.
({LatLng point, double meters}) _nearestOnSegment(LatLng p, LatLng a, LatLng b) {
  const mPerDegLat = 111320.0;
  final cosLat = math.cos(p.latitude * math.pi / 180);
  double x(LatLng q) => (q.longitude - p.longitude) * mPerDegLat * cosLat;
  double y(LatLng q) => (q.latitude - p.latitude) * mPerDegLat;

  final ax = x(a), ay = y(a), bx = x(b), by = y(b);
  final dx = bx - ax, dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  var t = lenSq == 0 ? 0.0 : -(ax * dx + ay * dy) / lenSq;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx, cy = ay + t * dy;
  final meters = math.sqrt(cx * cx + cy * cy);
  // Convert the projected point back to lat/lng.
  final lat = p.latitude + cy / mPerDegLat;
  final lng = p.longitude + cx / (mPerDegLat * cosLat);
  return (point: LatLng(lat, lng), meters: meters);
}

/// Minimal binary min-heap of (key, priority) for Dijkstra.
class _MinHeap {
  final List<(String, double)> _h = [];

  bool get isNotEmpty => _h.isNotEmpty;

  void push(String key, double pri) {
    _h.add((key, pri));
    var i = _h.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_h[parent].$2 <= _h[i].$2) break;
      final tmp = _h[parent];
      _h[parent] = _h[i];
      _h[i] = tmp;
      i = parent;
    }
  }

  (String, double) pop() {
    final top = _h.first;
    final last = _h.removeLast();
    if (_h.isNotEmpty) {
      _h[0] = last;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = 2 * i + 2;
        var smallest = i;
        if (l < _h.length && _h[l].$2 < _h[smallest].$2) smallest = l;
        if (r < _h.length && _h[r].$2 < _h[smallest].$2) smallest = r;
        if (smallest == i) break;
        final tmp = _h[smallest];
        _h[smallest] = _h[i];
        _h[i] = tmp;
        i = smallest;
      }
    }
    return top;
  }
}
