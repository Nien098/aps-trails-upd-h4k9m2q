import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/region.dart';
import '../services/search_service.dart';
import '../widgets/base_map.dart';
import '../widgets/map_search_bar.dart';
import 'region_picker_screen.dart';

/// View-only offline map — pan/zoom/search freely, no trail or edit context,
/// the way an offline Google Maps might work. Unlike [GuideScreen] and
/// [AuthorScreen] (each tied to one trail's region), this screen owns its
/// own region state and can swap basemaps on demand, so search here is
/// unconfined (see [SearchService.search]'s `confineTo` doc).
class BrowseMapScreen extends StatefulWidget {
  const BrowseMapScreen({super.key, required this.region});

  /// Region to open on — typically the Home screen's active region.
  final Region region;

  @override
  State<BrowseMapScreen> createState() => _BrowseMapScreenState();
}

class _BrowseMapScreenState extends State<BrowseMapScreen> {
  late Region _region = widget.region;
  MapLibreMapController? _c;
  bool _searchOpen = false;

  /// Set just before a basemap-swapping jump (see [_goTo]) so the freshly
  /// remounted [BaseMap] opens on the searched spot instead of the new
  /// region's bookmarked center — cleared once consumed by [_initialCamera].
  CameraPosition? _pendingCamera;

  CameraPosition get _initialCamera =>
      _pendingCamera ?? CameraPosition(target: _region.center, zoom: 13);

  void _onMapCreated(MapLibreMapController c) => _c = c;

  /// Jumps to [pos]. If it's on the basemap already loaded (same
  /// `mapAsset` — true for any two bundled regions, since they all share one
  /// pmtiles file), just pans the camera. Otherwise swaps to the region that
  /// actually covers [pos] — forcing [BaseMap] to remount via its
  /// `ValueKey(mapAsset)` — and opens straight on [pos] rather than that
  /// region's bookmarked center.
  void _goTo(LatLng pos) {
    final target = regionForPoint(pos);
    if (target.mapAsset == _region.mapAsset) {
      jumpCamera(_c, pos);
    } else {
      setState(() {
        _pendingCamera = CameraPosition(target: pos, zoom: 16);
        _region = target;
      });
    }
  }

  /// Manual region-dropdown pick — same basemap-swap logic as [_goTo], but
  /// opens on the region's own bookmarked center rather than a searched point.
  void _selectRegion(Region r) {
    if (r.mapAsset == _region.mapAsset) {
      setState(() => _region = r);
      jumpCamera(_c, r.center, zoom: 13);
    } else {
      setState(() {
        _pendingCamera = null;
        _region = r;
      });
    }
  }

  Future<void> _pickRegion() async {
    final r = await Navigator.push<Region>(
      context,
      MaterialPageRoute(builder: (_) => RegionPickerScreen(current: _region)),
    );
    if (r != null) _selectRegion(r);
  }

  void _onSearchResult(SearchResult result) {
    setState(() => _searchOpen = false);
    _goTo(result.position);
  }

  Future<void> _goToMyLocation() async {
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
          locationSettings:
              const LocationSettings(timeLimit: Duration(seconds: 10)));
      _goTo(LatLng(pos.latitude, pos.longitude));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Without this, the default `true` shrinks/resizes the body (and the
      // native MapLibreMap view filling it) every time the keyboard opens to
      // type a search query — resizing a live GL surface mid-frame is what
      // was causing the flicker/black-frame/distortion the user saw, not
      // (only) the camera-animation fix below. See the same reasoning
      // already applied to AuthorScreen's Scaffold.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _pickRegion,
          child: Row(
            children: [
              const Icon(Icons.place, size: 20),
              const SizedBox(width: 6),
              Flexible(
                child: Text(_region.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w600)),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          BaseMap(
            key: ValueKey(_region.mapAsset),
            region: _region,
            initialCamera: _initialCamera,
            onMapCreated: _onMapCreated,
            myLocationEnabled: true,
          ),
          if (_searchOpen)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: SafeArea(
                bottom: false,
                child: MapSearchBar(
                  onSelected: _onSearchResult,
                  onClose: () => setState(() => _searchOpen = false),
                ),
              ),
            ),
          Positioned(
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton(
                    heroTag: 'browseMyLocation',
                    onPressed: _goToMyLocation,
                    child: const Icon(Icons.my_location),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton(
                    heroTag: 'browseSearch',
                    mini: true,
                    tooltip: 'Search streets and trails',
                    onPressed: () => setState(() => _searchOpen = !_searchOpen),
                    child: const Icon(Icons.search),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
