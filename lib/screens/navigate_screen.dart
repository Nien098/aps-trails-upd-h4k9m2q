import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/bookmark.dart';
import '../models/region.dart';
import '../models/trail.dart';
import '../services/cue_gen.dart';
import '../services/geo.dart';
import '../services/route_layer.dart';
import '../services/search_service.dart';
import '../services/settings.dart';
import '../services/trail_router.dart';
import '../widgets/base_map.dart';
import '../widgets/map_search_bar.dart';
import 'bookmarks_screen.dart';
import 'guide_screen.dart';

/// Which of the two endpoint fields a pending pick action ([_pickVia]) is
/// filling in.
enum _Endpoint { start, end }

/// Point-to-point walking directions: pick a start and end (GPS, search, a
/// bookmark, or a map tap), get an offline-routed path over
/// [RouteGraphStore]'s bundled/downloaded road-and-trail network (via
/// [TrailRouter.connect] — the same real pathfinding [AuthorScreen]'s
/// "Follow trails" draw mode already uses, just for two arbitrary points
/// instead of a hand-placed anchor chain), and hand it straight to
/// [GuideScreen] for turn-by-turn walking. Deliberately walking-only (see
/// [_stickToRoads]'s doc) — this app has no vehicle-routing data (no
/// one-way/turn-restriction/speed tags) and is scoped to hiking/walking.
class NavigateScreen extends StatefulWidget {
  const NavigateScreen({super.key, required this.region, this.initialCamera});

  final Region region;

  /// Camera to open on — pass the caller's current position (see
  /// [BrowseMapScreen]'s Directions button) so this screen opens wherever
  /// the map was already looking, not the region's generic bookmarked
  /// center. Falls back to that center when not given.
  final CameraPosition? initialCamera;

  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen> {
  MapLibreMapController? _c;
  TrailRouter? _router;
  RouteLayer? _routeLayer;

  LatLng? _start;
  String _startLabel = 'Choose a start point';
  LatLng? _end;
  String _endLabel = 'Choose a destination';

  /// True = only roads/sidewalks (no trails/paths/shortcuts) — see
  /// [Surface.roads]. Off by default: [Surface.mixed] (every walkable
  /// surface, shortest overall) is what every other routing feature in this
  /// app already defaults to.
  bool _stickToRoads = false;

  bool _searchOpen = false;
  _Endpoint? _pickVia;

  List<LatLng>? _routePath;
  double? _routeMeters;
  bool _routing = false;
  String? _routeError;

  Circle? _startMarker;
  Circle? _endMarker;

  void _onMapCreated(MapLibreMapController c) {
    _c = c;
    _router = TrailRouter(c);
    _routeLayer = RouteLayer(c, id: 'nav-route');
  }

  Future<void> _onStyleLoaded() async {
    await _routeLayer?.ensure();
    // Default the start point to GPS the moment the map's ready, mirroring
    // how a real nav app opens already anchored to "here" — silently left
    // unset if location is denied/unavailable, same as every other
    // best-effort GPS use in this app (see BrowseMapScreen._goToMyLocation).
    if (_start == null) await _useMyLocation(_Endpoint.start, silent: true);
  }

  Future<void> _useMyLocation(_Endpoint which, {bool silent = false}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(timeLimit: Duration(seconds: 10)));
      // The silent auto-default (see _onStyleLoaded) can take several
      // seconds on a real device (cold GPS fix) — long enough for the
      // author to have since picked their own start point another way
      // (tap-on-map, search, a bookmark). Re-checked here, right before
      // committing, so a slow GPS fix can't silently overwrite a manual
      // pick made while it was still in flight. A non-silent (explicit
      // "My location" menu tap) call always applies — the user asked for
      // GPS specifically, there's nothing to preserve.
      if (silent && (which == _Endpoint.start ? _start : _end) != null) return;
      _setEndpoint(which, LatLng(pos.latitude, pos.longitude), 'My location');
    } catch (_) {
      if (!silent) _toast("Couldn't get your location");
    }
  }

  void _setEndpoint(_Endpoint which, LatLng pos, String label) {
    setState(() {
      if (which == _Endpoint.start) {
        _start = pos;
        _startLabel = label;
      } else {
        _end = pos;
        _endLabel = label;
      }
    });
    _updateMarkers();
    _maybeRoute();
  }

  void _swapEndpoints() {
    setState(() {
      final s = _start, sl = _startLabel;
      _start = _end;
      _startLabel = _endLabel;
      _end = s;
      _endLabel = sl;
    });
    _updateMarkers();
    _maybeRoute();
  }

  /// Redraws the start (green) / end (red) pins — plain circle annotations,
  /// same idea as [AuthorScreen]'s anchor markers, torn down and re-added on
  /// every change since there are only ever at most two of them.
  Future<void> _updateMarkers() async {
    final c = _c;
    if (c == null) return;
    if (_startMarker != null) {
      await c.removeCircle(_startMarker!);
      _startMarker = null;
    }
    if (_endMarker != null) {
      await c.removeCircle(_endMarker!);
      _endMarker = null;
    }
    if (_start != null) {
      _startMarker = await c.addCircle(CircleOptions(
        geometry: _start,
        circleRadius: 10,
        circleColor: '#2E7D32',
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 3,
      ));
    }
    if (_end != null) {
      _endMarker = await c.addCircle(CircleOptions(
        geometry: _end,
        circleRadius: 10,
        circleColor: '#C62828',
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 3,
      ));
    }
  }

  Future<void> _choosePoint(_Endpoint which) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('My location'),
              onTap: () => Navigator.pop(context, 'me'),
            ),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('Search streets and trails'),
              onTap: () => Navigator.pop(context, 'search'),
            ),
            ListTile(
              leading: const Icon(Icons.bookmark),
              title: const Text('Choose a bookmark'),
              onTap: () => Navigator.pop(context, 'bookmark'),
            ),
            ListTile(
              leading: const Icon(Icons.touch_app),
              title: const Text('Tap on the map'),
              onTap: () => Navigator.pop(context, 'map'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'me':
        await _useMyLocation(which);
      case 'search':
        setState(() {
          _pickVia = which;
          _searchOpen = true;
        });
      case 'bookmark':
        final b = await Navigator.push<Bookmark>(
            context, MaterialPageRoute(builder: (_) => const BookmarksScreen()));
        if (b != null) _setEndpoint(which, b.position, b.name);
      case 'map':
        setState(() => _pickVia = which);
        _toast('Tap the map to set your ${which == _Endpoint.start ? 'start' : 'destination'}');
    }
  }

  void _onSearchResult(SearchResult result) {
    final which = _pickVia ?? _Endpoint.end;
    setState(() {
      _searchOpen = false;
      _pickVia = null;
    });
    _setEndpoint(which, result.position, result.name);
  }

  void _onMapClick(Point<double> point, LatLng coords) {
    final which = _pickVia;
    if (which == null) return;
    setState(() => _pickVia = null);
    _setEndpoint(which, coords, 'Dropped pin');
  }

  Future<void> _maybeRoute() async {
    final start = _start, end = _end;
    final router = _router;
    if (start == null || end == null || router == null) return;
    setState(() {
      _routing = true;
      _routeError = null;
    });
    final result = await router.connect(
      from: start,
      to: end,
      surface: _stickToRoads ? Surface.roads : Surface.mixed,
    );
    if (!mounted) return;
    if (!result.followed) {
      setState(() {
        _routing = false;
        _routePath = null;
        _routeMeters = null;
        _routeError = 'No route found between these points — try points '
            'closer together or somewhere with more mapped trails/roads';
      });
      await _routeLayer?.setRoute(const [], '#1565C0');
      return;
    }
    setState(() {
      _routing = false;
      _routePath = result.polyline;
      _routeMeters = pathLength(result.polyline);
    });
    await _routeLayer?.setRoute(result.polyline, '#1565C0');
    await _fitToRoute(result.polyline);
  }

  Future<void> _fitToRoute(List<LatLng> path) async {
    final c = _c;
    if (c == null || path.isEmpty) return;
    var minLat = path.first.latitude, maxLat = path.first.latitude;
    var minLon = path.first.longitude, maxLon = path.first.longitude;
    for (final p in path) {
      minLat = minLat < p.latitude ? minLat : p.latitude;
      maxLat = maxLat > p.latitude ? maxLat : p.latitude;
      minLon = minLon < p.longitude ? minLon : p.longitude;
      maxLon = maxLon > p.longitude ? maxLon : p.longitude;
    }
    await c.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLon),
        northeast: LatLng(maxLat, maxLon),
      ),
      left: 40, right: 40, top: 220, bottom: 260,
    ));
  }

  void _startWalking() {
    final path = _routePath;
    if (path == null || path.length < 2) return;
    final trail = Trail(
      name: 'Route to $_endLabel',
      regionId: widget.region.id,
      color: '#1565C0',
      path: path,
      cues: suggestCues(path),
    );
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => GuideScreen(trail: trail)));
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Directions')),
      body: Stack(
        children: [
          BaseMap(
            region: widget.region,
            initialCamera: widget.initialCamera ??
                CameraPosition(target: widget.region.center, zoom: 13),
            onMapCreated: _onMapCreated,
            onStyleLoaded: _onStyleLoaded,
            onMapClick: _onMapClick,
            myLocationEnabled: true,
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: SafeArea(
              bottom: false,
              child: _searchOpen
                  ? MapSearchBar(
                      confineTo: widget.region,
                      onSelected: _onSearchResult,
                      onClose: () => setState(() {
                        _searchOpen = false;
                        _pickVia = null;
                      }),
                    )
                  : Card(
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.trip_origin, size: 18, color: Colors.green),
                                Expanded(
                                  child: _EndpointField(
                                    label: _startLabel,
                                    onTap: () => _choosePoint(_Endpoint.start),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.swap_vert),
                                  tooltip: 'Swap',
                                  onPressed: _swapEndpoints,
                                ),
                              ],
                            ),
                            const Divider(height: 1),
                            Row(
                              children: [
                                const Icon(Icons.place, size: 18, color: Colors.redAccent),
                                Expanded(
                                  child: _EndpointField(
                                    label: _endLabel,
                                    onTap: () => _choosePoint(_Endpoint.end),
                                  ),
                                ),
                                const SizedBox(width: 48),
                              ],
                            ),
                            const Divider(height: 1),
                            SwitchListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Stick to roads'),
                              subtitle: const Text(
                                  'Prefer streets over trails/shortcuts', style: TextStyle(fontSize: 12)),
                              value: _stickToRoads,
                              onChanged: (v) {
                                setState(() => _stickToRoads = v);
                                _maybeRoute();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          if (_routing)
            const Positioned(
              top: 210,
              left: 0,
              right: 0,
              child: Center(
                  child: SizedBox(
                      width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))),
            ),
          if (_routeError != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: SafeArea(
                top: false,
                child: Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(_routeError!,
                        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                  ),
                ),
              ),
            ),
          if (_routePath != null && _routeError == null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: SafeArea(
                top: false,
                child: Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            Settings.instance.formatDistance(_routeMeters ?? 0),
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _startWalking,
                          icon: const Icon(Icons.directions_walk),
                          label: const Text('Start walking'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EndpointField extends StatelessWidget {
  const _EndpointField({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
