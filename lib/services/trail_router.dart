import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'geo.dart';
import 'js_interop_norm.dart';
import 'route_graph_store.dart';
import 'settings.dart';

/// Which walkable surfaces auto-generation should prefer — see
/// [TrailRouter.generate]'s `surface` param and [TrailRouter._includeFor].
/// [trails] means singletrack/park paths only (plus sidewalks); [roads]
/// means streets (plus sidewalks); [mixed] is today's default — every
/// walkable surface together, picking whatever's shortest regardless of
/// surface.
enum Surface { trails, mixed, roads }

/// A trail route generated automatically from the visible trail network.
class GeneratedRoute {
  GeneratedRoute({
    required this.path,
    required this.anchors,
    required this.meters,
    required this.loop,
    this.surfaceFallback = false,
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

  /// True when a non-[Surface.mixed] preference was requested but that
  /// surface alone didn't reach anywhere meaningful in the area searched, so
  /// this route falls back to every walkable layer instead of failing
  /// outright — see [TrailRouter.generate].
  final bool surfaceFallback;
}

/// Result of connecting a new anchor to the trail network.
class TrailConnection {
  TrailConnection(this.end, this.polyline, this.followed, {this.debugReason});

  /// The (possibly snapped-to-trail) position of the new anchor.
  final LatLng end;

  /// The polyline from the previous anchor to [end]; follows real trail
  /// geometry when [followed] is true, otherwise a straight segment.
  final List<LatLng> polyline;

  /// Whether the segment traced actual trail geometry (vs a straight fallback).
  final bool followed;

  /// Set when [followed] is false, explaining which of the two rejection
  /// paths fired and with what numbers — surfaced in the UI so a real-device
  /// test reports a concrete cause instead of just "didn't work".
  final String? debugReason;
}

/// Builds a routable graph from the trail/road line features currently drawn
/// on the map, then snaps taps to trails and traces routes between anchors.
class TrailRouter {
  TrailRouter(this.controller);

  final MapLibreMapController controller;

  /// Every non-casing style layer that renders `roads` source-layer line
  /// geometry — casing layers (e.g. `roads_major_casing_early`) deliberately
  /// excluded since they render the *same* underlying features as their
  /// paired fill layer purely for a wider-outline visual effect, which would
  /// double-count every edge if both were queried. This list is generated
  /// from the current style.json (see the node one-liner in the PR/commit
  /// that added this), not hand-maintained — style layer *names* are a
  /// presentation detail that can change with the basemap theme (as they
  /// did when this app switched to Protomaps' official style), so which
  /// *kind* of geometry counts as walkable is decided separately, from the
  /// data itself (see [_isRoad]/[_isTrail]/[_isSidewalk]) — this list only
  /// needs to cover every layer that could contain that data, not classify
  /// it.
  static const _roadSourceLayers = [
    'roads_tunnels_other', 'roads_tunnels_minor', 'roads_tunnels_link',
    'roads_tunnels_major', 'roads_tunnels_highway', 'roads_pier',
    'roads_other', 'roads_link', 'roads_minor_service', 'roads_minor',
    'roads_major', 'roads_highway', 'roads_rail',
    'roads_bridges_other', 'roads_bridges_minor', 'roads_bridges_link',
    'roads_bridges_major', 'roads_bridges_highway',
  ];

  static const _roadKinds = {'highway', 'major_road', 'medium_road', 'minor_road'};
  static const _sidewalkDetails = {'sidewalk', 'crossing'};

  static bool _isRoad(Map<String, dynamic> props) => _roadKinds.contains(props['kind']);
  static bool _isSidewalk(Map<String, dynamic> props) =>
      props['kind'] == 'path' && _sidewalkDetails.contains(props['kind_detail']);
  static bool _isTrail(Map<String, dynamic> props) =>
      props['kind'] == 'path' && !_sidewalkDetails.contains(props['kind_detail']);

  /// Which of [_isRoad]/[_isTrail]/[_isSidewalk] count as walkable for a
  /// given [Surface] preference — sidewalks are always included regardless,
  /// same as before this was data-driven (a sidewalk is a reasonable way to
  /// walk whether you asked for "trails" or "roads").
  static bool Function(Map<String, dynamic>) _includeFor(Surface s) => switch (s) {
        Surface.trails => (p) => _isTrail(p) || _isSidewalk(p),
        Surface.roads => (p) => _isRoad(p) || _isSidewalk(p),
        Surface.mixed => (p) => _isRoad(p) || _isTrail(p) || _isSidewalk(p),
      };

  /// Same idea as [_includeFor], for an offline [RouteGraphStore] way's
  /// `kind` ('road'/'trail'/'sidewalk', see `tools/build_route_graph.py`)
  /// instead of a live feature's `props` map.
  static bool _includeOfflineKind(String kind, Surface s) => switch (s) {
        Surface.trails => kind == 'trail' || kind == 'sidewalk',
        Surface.roads => kind == 'road' || kind == 'sidewalk',
        Surface.mixed => true,
      };

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
  /// [rect] overrides the auto-computed query area (a tight box around just
  /// [from]/[to] — right for the author screen's "connect this nearby tap"
  /// use, but too narrow when [to] is far away, e.g. routing back to a
  /// distant trailhead: only geometry actually rendered inside the query
  /// rect is visible to the graph, so a caller chasing a far-off point
  /// should pass the full current map viewport instead).
  ///
  /// [seedPath], if given, is added to the graph as a guaranteed-connected
  /// chain of edges before routing — e.g. the trail's own already-known
  /// path back to [to]. `queryRenderedFeaturesInRect` can only see geometry
  /// that's actually rendered on screen right now, and [to] is very often
  /// well outside that (the camera follows the walker, not the trailhead
  /// they're routing back to), so without a seed there may be no rendered
  /// path from [from] to [to] at all even though a perfectly good one is
  /// already known. With it, Dijkstra still prefers a genuine shortcut
  /// found in whatever IS currently rendered, but always has the known
  /// path as a fallback instead of failing outright.
  Future<TrailConnection> connect({
    LatLng? from,
    required LatLng to,
    Rect? rect,
    List<LatLng>? seedPath,
    Surface surface = Surface.mixed,
  }) async {
    final r = rect ?? await _rectAround(from, to);
    final graph = await _buildGraph(r,
        surface: surface, geoBounds: _geoBoundsAround(from, to));
    if (seedPath != null && seedPath.length >= 2) {
      graph.addLatLngChain(seedPath);
      graph._mergeNearbyNodes(_mergeToleranceMeters);
    }

    // Snap the new anchor onto the nearest trail (Level A).
    final snap = graph.nearestOnEdge(to);
    final end = (snap != null && snap.meters <= _snapMeters) ? snap.point : to;

    if (from == null) {
      return TrailConnection(end, [end], false);
    }

    // Trace the trail between the two anchors (Level B).
    final line = graph.route(from, end);
    if (line == null) {
      return TrailConnection(end, [from, end], false,
          debugReason: 'no connected path in the queried area');
    }

    // Guard against absurd detours (disconnected-but-nearby trails).
    final straight = metersBetween(from, end);
    final routed = _polylineLength(line);
    if (straight > 5 && routed > straight * _maxDetourFactor) {
      return TrailConnection(end, [from, end], false,
          debugReason: 'route ${routed.round()}m vs straight-line '
              '${straight.round()}m exceeds ${_maxDetourFactor}x cap');
    }
    return TrailConnection(end, line, true);
  }

  /// Max times any single edge may be re-walked while padding a route out
  /// toward [targetMeters] — see [generate]. Bounds how long a pathologically
  /// small network (a schoolyard loop) can be forced to spin before giving up,
  /// rather than reusing edges forever trying to hit an unreachable target.
  static const _maxEdgeVisitsForPadding = 4;

  /// Auto-generates a walkable route from the trails currently visible in
  /// [viewport] (a screen-pixel rect covering the map), or — when
  /// [boundaryPolygon] is given — only from trails inside that (possibly
  /// irregular, user-drawn) geographic outline, regardless of what else the
  /// query happens to pick up nearby (see [_Graph.restrictToPolygon]).
  /// Starts near [center], aims for [targetMeters] total length, and
  /// returns a loop when [preferLoop] is set and a reasonable
  /// different-return path exists — otherwise an out-and-back.
  ///
  /// [surface] restricts which style layers count as walkable — see
  /// [Surface]. When the preferred surface alone doesn't reach anywhere
  /// meaningful (a boundary with essentially no trail, when [Surface.trails]
  /// was requested, say), this automatically retries with every walkable
  /// layer rather than failing outright — [GeneratedRoute.surfaceFallback]
  /// says whether that happened, so the caller can mention it.
  ///
  /// When the reachable network is shorter than [targetMeters] (common for a
  /// small boxed-in area), the route pads itself out by deliberately
  /// re-walking sections — see [_Graph.coverageWalk] — rather than just
  /// returning whatever the single longest pass happens to be. Returns null
  /// when no usable trail network is in view/inside the boundary at all,
  /// on any surface.
  Future<GeneratedRoute?> generate({
    required LatLng center,
    required Rect viewport,
    required double targetMeters,
    bool preferLoop = true,
    List<LatLng>? boundaryPolygon,
    Surface surface = Surface.mixed,
  }) async {
    final rect = boundaryPolygon != null
        ? await _screenRectForPolygon(boundaryPolygon)
        : viewport;
    final geoBounds = boundaryPolygon != null
        ? _geoBoundsAroundAll(boundaryPolygon, padMeters: 0)
        : await controller.getVisibleRegion();

    Future<GeneratedRoute?> attempt(Surface s) async {
      final graph = await _buildGraph(rect, surface: s, geoBounds: geoBounds);
      if (boundaryPolygon != null) graph.restrictToPolygon(boundaryPolygon);

      final start = graph.spliceTempNode(center, 'GEN');
      if (start.isEmpty) return null;

      // Half the target each way for a loop (out + back), or half for the
      // out-leg of an out-and-back (mirrored on the way home) — either way
      // the walk that actually explores the network only needs to cover
      // half of what the finished route will total.
      final outKeys = graph.coverageWalk(start, targetMeters / 2,
          maxVisitsPerEdge: _maxEdgeVisitsForPadding);
      // Need meaningful reach; if the nearest trails are a tiny stub, bail.
      if (outKeys.length < 2) return null;
      final current = outKeys.last;

      List<String>? backKeys;
      if (preferLoop) {
        // Penalise re-using the outbound edges so the return prefers a
        // genuinely different way home where the (possibly already-padded)
        // network offers one, without forbidding reuse outright — a small
        // box may have no alternative at all for the closing leg.
        final used = <String>{};
        for (var i = 0; i < outKeys.length - 1; i++) {
          used.add(_Graph.edgeId(outKeys[i], outKeys[i + 1]));
        }
        backKeys = graph.routeAvoiding(current, start, used, penalty: 5.0);
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

      return GeneratedRoute(
        path: path,
        anchors: _sampleAnchors(path),
        meters: _polylineLength(path),
        loop: loop,
      );
    }

    final primary = await attempt(surface);
    if (primary != null || surface == Surface.mixed) return primary;

    // The preferred surface alone couldn't even get started here — fall
    // back to every walkable layer rather than reporting "no trails found"
    // when a real (mixed-surface) route is actually available.
    final fallback = await attempt(Surface.mixed);
    if (fallback == null) return null;
    return GeneratedRoute(
      path: fallback.path,
      anchors: fallback.anchors,
      meters: fallback.meters,
      loop: fallback.loop,
      surfaceFallback: true,
    );
  }

  /// Waypoints along a (possibly long, self-crossing, padded) generated
  /// [path] spaced roughly every [intervalMeters] — keeps the anchor list a
  /// manageable size for [author_screen.dart]'s segment-editing UI instead of
  /// one anchor per graph node, which a heavily-padded route could have
  /// hundreds of.
  static List<LatLng> _sampleAnchors(List<LatLng> path, {double intervalMeters = 400}) {
    if (path.length < 2) return path;
    final anchors = [path.first];
    var sinceLast = 0.0;
    for (var i = 1; i < path.length; i++) {
      sinceLast += metersBetween(path[i - 1], path[i]);
      if (sinceLast >= intervalMeters) {
        anchors.add(path[i]);
        sinceLast = 0;
      }
    }
    if (anchors.last != path.last) anchors.add(path.last);
    return anchors;
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

  /// Screen-space rect covering the whole visible map, in the same pixel
  /// space [queryRenderedFeaturesInRect] expects. Deliberately goes via
  /// [toScreenLocation] on the camera's visible bounds rather than e.g.
  /// `MediaQuery.size` — that reports Flutter's logical/dp pixels, but the
  /// native query rect is in the MapView's own (device) pixels, same as
  /// [toScreenLocation]'s output. On a phone with devicePixelRatio ~2.6x, a
  /// MediaQuery-sized rect only covers roughly the top-left third of the
  /// real viewport, silently hiding anything further down or right on
  /// screen — exactly the failure mode seen routing to a real destination.
  Future<Rect> visibleViewportRect() async =>
      _screenRectForBounds(await controller.getVisibleRegion());

  /// Real trail/road junctions (graph degree >= 3 — a genuine fork, not just
  /// a mid-line vertex or dead end) within [toleranceMeters] of [path], built
  /// from whatever's rendered inside [rect] — same viewport-dependent
  /// limitation as every other query on this class (only sees currently
  /// rendered geometry). Used by [suggestCues]-style cue generation to place
  /// a "stay straight" cue at a fork the route passes through without
  /// turning, so a walker isn't left guessing which branch is the route.
  ///
  /// Distance-based matching, not exact-coordinate/key equality: [path] may
  /// be graph nodes verbatim ([generate]'s output) or points snapped onto an
  /// edge interpolation (hand-drawn/drag-traced/recorded paths via
  /// [snapStroke]/[snapPoint]), so exact matching would miss real junctions
  /// on non-generated paths. [toleranceMeters] defaults to 8m, matching the
  /// vertex spacing `author_screen.dart`'s `_densify` already treats as
  /// "close enough to be the same point."
  Future<List<LatLng>> junctionsNear(
    List<LatLng> path,
    Rect rect, {
    double toleranceMeters = 8,
    Surface surface = Surface.mixed,
  }) async {
    final graph = await _buildGraph(rect,
        surface: surface,
        geoBounds: path.isEmpty ? null : _geoBoundsAroundAll(path));
    return [
      for (final j in graph.junctionNodes())
        if (distanceToPath(j, path) <= toleranceMeters) j,
    ];
  }

  /// Projects [bounds]'s 4 corners into the same native-pixel space as
  /// [visibleViewportRect] and returns their bounding [Rect] — shared so any
  /// caller with an arbitrary geographic box (not just "whatever's on screen
  /// right now") can build a correctly-scaled query rect for it, e.g.
  /// [generate]'s `boundary` param.
  Future<Rect> _screenRectForBounds(LatLngBounds bounds) async {
    final corners = await Future.wait([
      controller.toScreenLocation(bounds.northeast),
      controller.toScreenLocation(bounds.southwest),
      controller.toScreenLocation(
          LatLng(bounds.northeast.latitude, bounds.southwest.longitude)),
      controller.toScreenLocation(
          LatLng(bounds.southwest.latitude, bounds.northeast.longitude)),
    ]);
    final xs = corners.map((p) => p.x.toDouble());
    final ys = corners.map((p) => p.y.toDouble());
    return Rect.fromLTRB(
        xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
  }

  /// Same idea as [_screenRectForBounds], but for an arbitrary (possibly
  /// concave) polygon outline instead of a fixed 4-corner box — the query
  /// rect is only ever axis-aligned regardless (queryRenderedFeaturesInRect
  /// doesn't support an arbitrary shape), so this is just the bounding box
  /// of every vertex; [_Graph.restrictToPolygon] is what actually enforces
  /// the real outline afterward.
  Future<Rect> _screenRectForPolygon(List<LatLng> polygon) async {
    final corners = await Future.wait(polygon.map(controller.toScreenLocation));
    final xs = corners.map((p) => p.x.toDouble());
    final ys = corners.map((p) => p.y.toDouble());
    return Rect.fromLTRB(
        xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
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

  /// Geographic (not screen-space) bounds enclosing [a]/[b] with [padMeters]
  /// of margin — used to query [RouteGraphStore], which is indexed by real
  /// lat/lng, not screen pixels. Unlike [_rectAround]'s modest pixel pad
  /// (meaningless in real-world distance — it shrinks as you zoom in), this
  /// is a fixed real-world margin regardless of zoom, since the offline
  /// graph's whole purpose is reaching a destination that may be nowhere
  /// near the current camera position at all.
  LatLngBounds _geoBoundsAround(LatLng? a, LatLng b, {double padMeters = 300}) =>
      _geoBoundsAroundAll([b, ?a], padMeters: padMeters);

  LatLngBounds _geoBoundsAroundAll(List<LatLng> points, {double padMeters = 300}) {
    var minLat = points.first.latitude, maxLat = minLat;
    var minLon = points.first.longitude, maxLon = minLon;
    for (final p in points.skip(1)) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    final latPad = padMeters / 111320;
    final lonPad = padMeters /
        (111320 * math.cos((minLat + maxLat) / 2 * math.pi / 180));
    return LatLngBounds(
      southwest: LatLng(minLat - latPad, minLon - lonPad),
      northeast: LatLng(maxLat + latPad, maxLon + lonPad),
    );
  }

  /// Nudges [p] onto the nearest trail/road within [maxMeters] (defaults to
  /// [_snapMeters]), if any — a pure local nearest-edge lookup, no
  /// pathfinding/routing between points, so it can safely draw on the same
  /// merged live+offline candidate pool [_buildGraph] gives [connect]
  /// without inheriting Dijkstra's "wrong-leg detour" risk (nearest-edge
  /// search has no path-cost accumulation to go wrong). Used by record-mode
  /// cleanup so a single unmapped or gappy spot can't drag an entire segment
  /// into a router-guessed detour the way [connect]'s shortest-path search
  /// could (see [record_trail_screen._cleanPath]).
  Future<LatLng> snapPoint(LatLng p, {Rect? rect, double? maxMeters}) async {
    final r = rect ?? await _rectAround(null, p);
    final graph = await _buildGraph(r, geoBounds: _geoBoundsAround(null, p));
    final snap = graph.nearestOnEdge(p);
    final limit = maxMeters ?? _snapMeters;
    return (snap != null && snap.meters <= limit) ? snap.point : p;
  }

  /// Snaps every point of a hand-drawn [points] trace onto the mapped
  /// trail/road network, biased to stay on whichever edge the previous point
  /// snapped to rather than re-searching from scratch each time. A plain
  /// independent-per-point "nearest edge" search can flip onto a different,
  /// merely-a-touch-closer trail right where two paths cross or run close
  /// together, producing a visible zig-zag/detour even when the drag stayed
  /// on the real trail the whole way — since the author was tracing an
  /// actual trail, the edge they were already snapped to is almost always
  /// still the right one nearby, so it's only abandoned when a different
  /// edge is meaningfully closer (see [_Graph._nearestSegSticky]), not just
  /// marginally so.
  ///
  /// Also builds a single graph over the whole stroke's bounding box up
  /// front, rather than a fresh small one per point — so every point sees
  /// the same, consistent set of nearby features instead of each point's
  /// tiny query box independently including or excluding nearby fragments.
  Future<List<LatLng>> snapStroke(List<LatLng> points, {double maxMeters = 50}) async {
    if (points.isEmpty) return points;
    final graph = await _buildGraph(await _rectAroundAll(points),
        geoBounds: _geoBoundsAroundAll(points));
    final out = <LatLng>[];
    _Seg? currentSeg;
    for (final p in points) {
      final result = graph._nearestSegSticky(p, currentSeg);
      if (result != null && result.meters <= maxMeters) {
        out.add(result.point);
        currentSeg = result.seg;
      } else {
        out.add(p);
        // Lost the trail (nothing close enough) — free to pick up any
        // nearby edge fresh next point, rather than staying stuck trying to
        // match an edge that's no longer actually close.
        currentSeg = null;
      }
    }
    return out;
  }

  /// Screen-space rect enclosing every one of [points] (with padding), same
  /// idea as [_rectAround] but for an arbitrary trace instead of just two
  /// endpoints — used by [snapStroke] so the whole stroke is queried at once.
  Future<Rect> _rectAroundAll(List<LatLng> points) async {
    final screens = await Future.wait(points.map(controller.toScreenLocation));
    var minX = screens.first.x.toDouble(), maxX = minX;
    var minY = screens.first.y.toDouble(), maxY = minY;
    for (final s in screens.skip(1)) {
      minX = math.min(minX, s.x.toDouble());
      maxX = math.max(maxX, s.x.toDouble());
      minY = math.min(minY, s.y.toDouble());
      maxY = math.max(maxY, s.y.toDouble());
    }
    const pad = 350.0;
    return Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
  }

  /// Routes between two existing anchors WITHOUT re-snapping them (used when
  /// re-joining the trail after a middle anchor is deleted). Falls back to a
  /// straight segment when there's no connected trail.
  Future<List<LatLng>> between(LatLng from, LatLng to) async {
    final graph = await _buildGraph(await _rectAround(from, to),
        geoBounds: _geoBoundsAround(from, to));
    final line = graph.route(from, to);
    if (line == null) return [from, to];
    final straight = metersBetween(from, to);
    final routed = _polylineLength(line);
    if (straight > 5 && routed > straight * _maxDetourFactor) return [from, to];
    return line;
  }

  Future<_Graph> _buildGraph(
    Rect rect, {
    Surface surface = Surface.mixed,
    LatLngBounds? geoBounds,
  }) async {
    final graph = _Graph();
    await _addFeaturesToGraph(graph, rect,
        include: _includeFor(surface), geoBounds: geoBounds, surface: surface);
    // A single real-world trail can arrive as several separate LineString
    // features (e.g. split around a line-label's placement point, or by tile
    // clipping) whose "shared" endpoint differs by a few metres between
    // fragments — just outside addLine's ~1m key-rounding tolerance. Left
    // alone, that gap forces routing to detour via whatever junction node IS
    // connected, producing an odd kink right at the split (often exactly
    // under the trail's name label). Merge close-enough fragment endpoints
    // so the trail reads as one continuous edge again.
    graph._mergeNearbyNodes(_mergeToleranceMeters);
    return graph;
  }

  /// Same idea as [_buildGraph], but every edge is tagged isRoad/not per its
  /// own data (see [_isRoad]) rather than being treated as one
  /// undifferentiated walkable network — used by [nearestRoad], which needs
  /// to tell the two apart.
  Future<_Graph> _buildTaggedGraph(Rect rect, {LatLngBounds? geoBounds}) async {
    final graph = _Graph();
    await _addFeaturesToGraph(graph, rect,
        include: _includeFor(Surface.mixed), geoBounds: geoBounds);
    graph._mergeNearbyNodes(_mergeToleranceMeters);
    return graph;
  }

  /// Real-world trail/sidewalk fragments and trail-to-road junctions rarely
  /// share an exact node in OSM data — a trail can end several metres short
  /// of the road centreline it visually meets. 4m (the original value, sized
  /// for same-way tile-split gaps only) was too tight for that; widened to
  /// cover typical junction slop without merging genuinely distinct nearby
  /// trails (e.g. adjacent switchback legs) into one.
  ///
  /// Measured directly against this app's real downloaded map data (not
  /// guessed): most gaps between disconnected trail fragments in a sparsely-
  /// mapped area (Riverview Forest, Coquitlam) are 150-700m — genuinely
  /// separate, unconnected trails in OpenStreetMap's data, not a seam this
  /// number should ever bridge (doing so would silently invent a fake
  /// straight-line "trail" between two unrelated real ones — the same class
  /// of bug already found and fixed in the record-mode path-snapping code).
  /// A small number of close-but-separate fragments (~20-28m apart) *were*
  /// found and are plausibly the same real trail clipped oddly at a tile
  /// boundary — 24m safely closes those without approaching the 150m+ range
  /// where a "gap" is actually just two different trails.
  static const _mergeToleranceMeters = 24.0;

  /// Queries every walkable-candidate layer (see [_roadSourceLayers]) and
  /// adds each returned feature's geometry to [graph], skipping any feature
  /// [include] rejects (null means "everything roads/trails/sidewalks" —
  /// see [_includeFor]) and tagging isRoad from the feature's own `kind`
  /// (see [_isRoad]), not from which style layer it came from.
  Future<void> _addFeaturesToGraph(
    _Graph graph,
    Rect rect, {
    bool Function(Map<String, dynamic> props)? include,
    LatLngBounds? geoBounds,
    Surface surface = Surface.mixed,
  }) async {
    final raw =
        await controller.queryRenderedFeaturesInRect(rect, _roadSourceLayers, null);
    for (final f in raw) {
      final feature = f is String ? jsonDecode(f) : f;
      if (feature is! Map) continue;
      final props = (normalizeJs(feature['properties']) as Map?)
              ?.cast<String, dynamic>() ??
          const {};
      if (include != null && !include(props)) continue;
      final geom = feature['geometry'];
      if (geom is! Map) continue;
      final type = geom['type'];
      final coords = normalizeJs(geom['coordinates']);
      final isRoad = _isRoad(props);
      if (type == 'LineString') {
        graph.addLine(coords, isRoad: isRoad);
      } else if (type == 'MultiLineString') {
        for (final line in coords) {
          graph.addLine(line, isRoad: isRoad);
        }
      }
    }

    // Offline region-wide network, additive to whatever's actually rendered
    // above — this is what lets routing reach beyond the current viewport
    // (see connect()'s "route back to a distant trailhead" doc). Purely
    // additive: the live-render path above is untouched, so existing
    // correctness (multiple rounds of real-device fixes) isn't at risk —
    // offline ways just add more candidate edges before Dijkstra runs.
    if (geoBounds != null) {
      final ways = await RouteGraphStore.instance.waysInBounds(geoBounds);
      for (final w in ways) {
        if (!_includeOfflineKind(w.kind, surface)) continue;
        graph.addLatLngChain(w.coords, isRoad: w.kind == 'road');
      }
    }
  }

  /// Finds the shortest path from [from] to the *nearest* point classified
  /// as a road (not a specific destination) within [viewport] — "get me out
  /// to a road, whichever is closest" rather than "get me to this road".
  /// A single Dijkstra run naturally finds this: nodes are popped in
  /// increasing-distance order, so the first road-tagged node popped is
  /// guaranteed nearest. Returns null if no road is reachable from what's
  /// currently mapped/visible — callers should treat that the same as any
  /// other "no route found" case, not retry with a wider search on their own.
  Future<TrailConnection?> nearestRoad({
    required LatLng from,
    required Rect viewport,
  }) async {
    final graph = await _buildTaggedGraph(viewport,
        geoBounds: await controller.getVisibleRegion());
    final line = graph.routeToNearestRoad(from);
    if (line == null) return null;
    return TrailConnection(line.last, line, true);
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
  _Seg(this.aKey, this.bKey, this.a, this.b, this.isRoad);
  final String aKey, bKey;
  final LatLng a, b;
  final bool isRoad;
}

/// A lightweight routing graph keyed by rounded coordinates (~1 m tolerance),
/// so line segments that share endpoints across tiles connect up.
class _Graph {
  final Map<String, LatLng> nodes = {};
  final Map<String, List<_Edge>> adj = {};
  final List<_Seg> _segments = [];

  /// Nodes that are an endpoint of at least one road-tagged edge — see
  /// [TrailRouter._buildTaggedGraph]/[routeToNearestRoad]. Empty for a graph
  /// built the untagged way ([TrailRouter._buildGraph]).
  final Set<String> roadNodeKeys = {};

  static String _key(double lat, double lng) =>
      '${lat.toStringAsFixed(5)}_${lng.toStringAsFixed(5)}';

  void addLine(dynamic coords, {bool isRoad = false}) {
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
        _segments.add(_Seg(prevKey, k, prev, p, isRoad));
        if (isRoad) {
          roadNodeKeys.add(prevKey);
          roadNodeKeys.add(k);
        }
      }
      prev = p;
      prevKey = k;
    }
  }

  /// Same idea as [addLine], but for an already-decoded [LatLng] chain
  /// (e.g. a known trail's `path`, or an offline [RouteGraphStore] way)
  /// rather than raw GeoJSON coordinates — see [TrailRouter.connect]'s
  /// `seedPath` parameter and [TrailRouter._addFeaturesToGraph]'s offline
  /// merge. [isRoad] defaults to false to preserve seedPath's existing
  /// behaviour (a seed is "the trail's own known path," not a road).
  void addLatLngChain(List<LatLng> pts, {bool isRoad = false}) {
    LatLng? prev;
    String? prevKey;
    for (final p in pts) {
      final k = _key(p.latitude, p.longitude);
      nodes.putIfAbsent(k, () => p);
      if (prev != null && prevKey != null && prevKey != k) {
        final w = metersBetween(prev, p);
        (adj[prevKey] ??= []).add(_Edge(k, w));
        (adj[k] ??= []).add(_Edge(prevKey, w));
        _segments.add(_Seg(prevKey, k, prev, p, isRoad));
      }
      prev = p;
      prevKey = k;
    }
  }

  /// Union-finds together any two *loose-end* nodes (degree <= 1 — i.e. not
  /// already connected to more than one other point) within
  /// [toleranceMeters] of each other, then rewrites nodes/edges/segments
  /// onto the canonical (root) key of each group. Fixes near-miss
  /// disconnects between fragments of what is really one continuous trail
  /// (see [_buildGraph]).
  ///
  /// The degree<=1 restriction matters more than it looks: an earlier
  /// version merged *any* two nearby nodes regardless of how connected they
  /// already were. That's fine at a tight tolerance (a few metres only ever
  /// catches a genuine same-way tile-split gap), but widening the tolerance
  /// to close real multi-tile trail gaps (see the tolerance constant's own
  /// doc) made it start welding together nodes that were never the same
  /// path at all — two different, already-connected streets running close
  /// together in a dense residential grid, for instance — corrupting the
  /// graph into something Dijkstra could only find absurd, rejected-as-too-
  /// long routes through, which is indistinguishable from routing having
  /// stopped working (on-device testing showed exactly that: dense-area
  /// "Follow trails" regressed hard right when this tolerance widened).
  /// Only ever bridging genuine loose ends removes that risk: a real
  /// mid-street node already has 2+ connections and is never a merge
  /// candidate, no matter how wide the tolerance gets.
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

    bool isLooseEnd(String k) => (adj[k]?.length ?? 0) <= 1;

    for (var i = 0; i < keys.length; i++) {
      if (!isLooseEnd(keys[i])) continue;
      for (var j = i + 1; j < keys.length; j++) {
        if (!isLooseEnd(keys[j])) continue;
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
      _segments[i] = _Seg(find(s.aKey), find(s.bKey), s.a, s.b, s.isRoad);
    }
    final newRoadNodeKeys = {for (final k in roadNodeKeys) find(k)};
    nodes
      ..clear()
      ..addAll(newNodes);
    adj
      ..clear()
      ..addAll(newAdj);
    roadNodeKeys
      ..clear()
      ..addAll(newRoadNodeKeys);
  }

  /// Drops every node (and any edge/segment touching it) that falls outside
  /// [polygon] (via [_pointInPolygon]) — a hard geographic guarantee that
  /// generation never leaves a user-drawn boundary outline, regardless of
  /// how imprecise the screen-rect query that built the graph was (see
  /// [TrailRouter.generate]'s `boundaryPolygon` param).
  void restrictToPolygon(List<LatLng> polygon) {
    final keep = {
      for (final e in nodes.entries)
        if (_pointInPolygon(e.value, polygon)) e.key,
    };
    nodes.removeWhere((k, _) => !keep.contains(k));
    adj.removeWhere((k, _) => !keep.contains(k));
    for (final list in adj.values) {
      list.removeWhere((e) => !keep.contains(e.to));
    }
    _segments.removeWhere((s) => !keep.contains(s.aKey) || !keep.contains(s.bKey));
    roadNodeKeys.removeWhere((k) => !keep.contains(k));
  }

  /// Greedily walks the graph from [startKey], always preferring the
  /// least-visited adjacent edge (unwalked ones first), until either
  /// [targetMeters] is reached or every edge reachable from wherever the
  /// walk currently is has hit [maxVisitsPerEdge] — see [TrailRouter.generate].
  /// This is what lets a short, boxed-in trail network still produce a long
  /// suggested walk: once the fresh ground runs out, it deliberately doubles
  /// back and re-walks sections (bounded by [maxVisitsPerEdge], so a
  /// pathologically tiny network can't spin forever) instead of just
  /// stopping at whatever the network's single-pass reach happens to be.
  /// Returns the sequence of node keys walked, including [startKey] first
  /// (length 1 if nothing was reachable at all).
  List<String> coverageWalk(String startKey, double targetMeters,
      {required int maxVisitsPerEdge}) {
    final visits = <String, int>{};
    final keys = [startKey];
    var current = startKey;
    var walked = 0.0;
    String? cameFrom;

    while (walked < targetMeters) {
      final options = adj[current] ?? const <_Edge>[];
      if (options.isEmpty) break;

      // Prefer the least-visited edge, skipping an immediate retrace of the
      // edge just taken (unless that's the only option — a dead end).
      _Edge? pick;
      var pickVisits = 1 << 30;
      for (final e in options) {
        if (e.to == cameFrom && options.length > 1) continue;
        final v = visits[edgeId(current, e.to)] ?? 0;
        if (v >= maxVisitsPerEdge) continue;
        if (v < pickVisits) {
          pickVisits = v;
          pick = e;
        }
      }
      // Every non-backtrack option is at the visit cap (or this is a dead
      // end) — allow retracing rather than stopping dead, still bounded.
      if (pick == null) {
        for (final e in options) {
          final v = visits[edgeId(current, e.to)] ?? 0;
          if (v < maxVisitsPerEdge && v < pickVisits) {
            pickVisits = v;
            pick = e;
          }
        }
      }
      if (pick == null) break;

      visits[edgeId(current, pick.to)] = pickVisits + 1;
      cameFrom = current;
      current = pick.to;
      walked += pick.weight;
      keys.add(current);
    }
    return keys;
  }

  ({LatLng point, double meters, _Seg seg})? _nearestSeg(LatLng p, {bool roadOnly = false}) {
    ({LatLng point, double meters, _Seg seg})? best;
    for (final seg in _segments) {
      if (roadOnly && !seg.isRoad) continue;
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

  /// Margin (m) [preferred] is allowed to lose by and still be kept — see
  /// [_nearestSegSticky].
  static const _stickyHysteresisMeters = 8.0;

  /// Like [_nearestSeg], but keeps [preferred] (the edge the previous point
  /// snapped to) unless a different edge beats it by more than
  /// [hysteresisMeters] (defaults to [_stickyHysteresisMeters]) — small
  /// enough that switching to a genuinely different, closer trail still
  /// happens (the author really did move onto another path), but large
  /// enough that two trails crossing or running close together don't cause
  /// every other point to flip between them. Used by [snapStroke].
  ///
  /// One asymmetric exception: a walker is presumed to be on a sidewalk/
  /// trail, not literally in the road, so staying locked onto a *road* edge
  /// needs a stricter bar — any sidewalk/trail within the normal hysteresis
  /// margin wins, even though it wouldn't count as "meaningfully closer" by
  /// the plain rule below. Without this, one brief moment nearer the road
  /// than the sidewalk (e.g. cutting through a parking lot, or a gap in
  /// sidewalk data right at a corner) locks the *entire rest* of the walk
  /// onto the road: sidewalks routinely run only 2-5m from their road the
  /// whole way, well under the 8m margin that would otherwise trigger a
  /// switch back — confirmed as a real, reported failure, not a
  /// hypothetical (a recorded sidewalk walk snapping onto the road for a
  /// long straight stretch after passing a parking lot entrance). Staying
  /// on a non-road edge keeps the plain symmetric rule — this doesn't make
  /// it easier to flip between two similarly-classified nearby trails.
  ({LatLng point, double meters, _Seg seg})? _nearestSegSticky(
    LatLng p,
    _Seg? preferred, {
    double hysteresisMeters = _stickyHysteresisMeters,
  }) {
    ({LatLng point, double meters, _Seg seg})? best;
    ({LatLng point, double meters, _Seg seg})? bestNonRoad;
    ({LatLng point, double meters})? onPreferred;
    for (final seg in _segments) {
      final r = _nearestOnSegment(p, seg.a, seg.b);
      if (best == null || r.meters < best.meters) {
        best = (point: r.point, meters: r.meters, seg: seg);
      }
      if (!seg.isRoad && (bestNonRoad == null || r.meters < bestNonRoad.meters)) {
        bestNonRoad = (point: r.point, meters: r.meters, seg: seg);
      }
      if (identical(seg, preferred)) {
        onPreferred = (point: r.point, meters: r.meters);
      }
    }
    if (preferred == null || onPreferred == null || best == null) return best;

    if (preferred.isRoad &&
        bestNonRoad != null &&
        bestNonRoad.meters <= onPreferred.meters + hysteresisMeters) {
      return (point: bestNonRoad.point, meters: bestNonRoad.meters, seg: bestNonRoad.seg);
    }
    if (onPreferred.meters <= best.meters + hysteresisMeters) {
      return (point: onPreferred.point, meters: onPreferred.meters, seg: preferred);
    }
    return best;
  }

  static String edgeId(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  LatLng nodeAt(String key) => nodes[key]!;

  /// Coordinates of every node with degree >= [minDegree] (a real
  /// fork/junction, not a mid-line vertex or dead end) — surfaced via
  /// [TrailRouter.junctionsNear] without exposing this graph itself.
  List<LatLng> junctionNodes({int minDegree = 3}) => [
        for (final k in nodes.keys)
          if ((adj[k]?.length ?? 0) >= minDegree) nodes[k]!,
      ];

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
  /// Returns the followed polyline (including endpoints), or null only if
  /// neither endpoint could be spliced onto any trail geometry at all.
  ///
  /// [from] and [to] landing in different, disconnected pieces of the graph
  /// (a real gap in the map data — a tile-boundary split too wide to bridge,
  /// or a genuine break in the trail) no longer means giving up on the
  /// whole segment and drawing one straight line from end to end, even
  /// where 95% of that segment is sitting right on a perfectly good, fully-
  /// mapped road. Instead this finds the closest pair of points across the
  /// two disconnected pieces — one reachable from [from], one reachable
  /// from [to] — follows real trail geometry up to each, and only bridges
  /// the actual gap between them with a straight line. See [_closestBridge].
  List<LatLng>? route(LatLng from, LatLng to) {
    final startKey = spliceTempNode(from, 'FROM');
    final goalKey = spliceTempNode(to, 'TO');
    if (startKey.isEmpty || goalKey.isEmpty) return null;

    final (dist, prev) = dijkstraTree(startKey);
    if (dist.containsKey(goalKey)) {
      final keys = tracePath(prev, startKey, goalKey);
      return [from, for (final k in keys) nodes[k]!, to];
    }
    final bridged = _closestBridge(startKey, goalKey, dist, prev);
    return bridged == null ? null : [from, ...bridged, to];
  }

  /// Safety cap on the search in [_closestBridge] — a query rect can
  /// legitimately return a few thousand graph nodes in a dense area; this
  /// keeps the pairwise closest-point search from becoming a real cost on a
  /// phone if both disconnected sides happen to be that large. Genuinely
  /// exceeding it just falls back to the old "no path" behaviour for this
  /// call, same as it always did — this is an enhancement over that
  /// fallback, not a replacement safety net for it.
  static const _maxBridgeSearchNodes = 1500;

  /// [startKey] and [goalKey] are in different connected components (a real
  /// gap). Finds the closest pair of nodes across the two reachable sets —
  /// [distFromStart]/[prevFromStart] already computed by the caller — and
  /// splices a straight line across just that gap, using real trail
  /// geometry from [startKey] up to it and from it to [goalKey]. Returns
  /// null if either reachable set is empty or over [_maxBridgeSearchNodes].
  List<LatLng>? _closestBridge(String startKey, String goalKey,
      Map<String, double> distFromStart, Map<String, String> prevFromStart) {
    final (distFromGoal, prevFromGoal) = dijkstraTree(goalKey);
    final fromKeys = distFromStart.keys.toList();
    final goalKeys = distFromGoal.keys.toList();
    if (fromKeys.isEmpty ||
        goalKeys.isEmpty ||
        fromKeys.length > _maxBridgeSearchNodes ||
        goalKeys.length > _maxBridgeSearchNodes) {
      return null;
    }

    String? bestA, bestB;
    var bestGap = double.infinity;
    for (final a in fromKeys) {
      final pa = nodes[a]!;
      for (final b in goalKeys) {
        final d = metersBetween(pa, nodes[b]!);
        if (d < bestGap) {
          bestGap = d;
          bestA = a;
          bestB = b;
        }
      }
    }
    if (bestA == null || bestB == null) return null;

    final toA = tracePath(prevFromStart, startKey, bestA);
    final fromB = tracePath(prevFromGoal, goalKey, bestB);
    if (toA.isEmpty || fromB.isEmpty) return null;
    return [
      for (final k in toA) nodes[k]!,
      for (final k in fromB.reversed) nodes[k]!,
    ];
  }

  /// Dijkstra from [from] (spliced onto the graph) that stops at the first
  /// road-tagged node it pops, rather than routing to one fixed destination
  /// — see [TrailRouter.nearestRoad]. Nodes come off the heap in
  /// non-decreasing distance order, so the first road node popped is
  /// guaranteed the nearest reachable one; no need to check every candidate
  /// and compare. Returns the followed polyline (including [from]), or null
  /// if this graph has no road-tagged nodes at all, or none are reachable.
  List<LatLng>? routeToNearestRoad(LatLng from, {double maxBridgeMeters = 60}) {
    if (!_segments.any((s) => s.isRoad)) return null;
    final startKey = spliceTempNode(from, 'ROADFROM');
    if (startKey.isEmpty) return null;

    final dist = <String, double>{startKey: 0};
    final prev = <String, String>{};
    final heap = _MinHeap()..push(startKey, 0);
    String? goalKey;

    while (heap.isNotEmpty) {
      final (node, d) = heap.pop();
      if (d > (dist[node] ?? double.infinity)) continue;
      if (node != startKey && roadNodeKeys.contains(node)) {
        goalKey = node;
        break;
      }
      for (final e in adj[node] ?? const <_Edge>[]) {
        final nd = d + e.weight;
        if (nd < (dist[e.to] ?? double.infinity)) {
          dist[e.to] = nd;
          prev[e.to] = node;
          heap.push(e.to, nd);
        }
      }
    }

    if (goalKey != null) {
      final keys = tracePath(prev, startKey, goalKey);
      if (keys.isEmpty) return null;
      return [from, for (final key in keys) nodes[key]!];
    }

    // No trail node is topologically joined to a road node in the source
    // data — a common real-world gap, since a mapped path rarely shares an
    // exact node with the road it leads out to. The heap ran to exhaustion
    // above (never broke early), so `dist`/`prev` already cover every node
    // reachable from `from`; bridge from whichever one has the shortest
    // combined (trail distance + straight last-mile gap to the nearest road
    // edge), capped at [maxBridgeMeters] so this can't wander off through
    // open ground toward some distant road.
    String? bestNode;
    LatLng? bestPoint;
    var bestTotal = double.infinity;
    dist.forEach((key, d) {
      final near = _nearestSeg(nodes[key]!, roadOnly: true);
      if (near == null || near.meters > maxBridgeMeters) return;
      final total = d + near.meters;
      if (total < bestTotal) {
        bestTotal = total;
        bestNode = key;
        bestPoint = near.point;
      }
    });
    if (bestNode == null) return null;
    final keys = tracePath(prev, startKey, bestNode!);
    if (keys.isEmpty) return null;
    return [from, for (final key in keys) nodes[key]!, bestPoint!];
  }
}

/// Standard ray-casting point-in-polygon test — correct for both convex and
/// concave outlines, which matters here since a freehand-drawn boundary is
/// rarely convex. [polygon] doesn't need to be explicitly closed (first
/// point repeated at the end); the wraparound edge (last → first) is
/// included regardless.
bool _pointInPolygon(LatLng p, List<LatLng> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final yi = polygon[i].latitude, xi = polygon[i].longitude;
    final yj = polygon[j].latitude, xj = polygon[j].longitude;
    final crosses = (yi > p.latitude) != (yj > p.latitude);
    if (crosses &&
        p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
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
