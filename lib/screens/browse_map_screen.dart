import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/region.dart';
import '../services/search_service.dart';
import '../widgets/base_map.dart';
import '../widgets/location_search.dart';

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
      _c?.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
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
      _c?.animateCamera(CameraUpdate.newLatLngZoom(r.center, 13));
    } else {
      setState(() {
        _pendingCamera = null;
        _region = r;
      });
    }
  }

  Future<void> _openSearch() async {
    final result = await showSearch<SearchResult?>(
      context: context,
      delegate: LocationSearchDelegate(),
    );
    if (result != null) _goTo(result.position);
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
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<Region>(
            isExpanded: true,
            value: _region,
            icon: const Icon(Icons.arrow_drop_down),
            borderRadius: BorderRadius.circular(12),
            onChanged: (r) {
              if (r != null) _selectRegion(r);
            },
            selectedItemBuilder: (context) => [
              for (final r in allRegions())
                Row(
                  children: [
                    const Icon(Icons.place, size: 20),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(r.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
            ],
            items: [
              for (final r in allRegions())
                DropdownMenuItem(value: r, child: Text(r.name)),
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
                    onPressed: _openSearch,
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
