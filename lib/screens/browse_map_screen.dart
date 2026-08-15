import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/bookmark.dart';
import '../models/region.dart';
import '../services/bookmark_layer.dart';
import '../services/boundary_layer.dart';
import '../services/search_service.dart';
import '../services/trail_store.dart';
import '../widgets/base_map.dart';
import '../widgets/bookmark_edit_sheet.dart';
import '../widgets/map_search_bar.dart';
import 'author_screen.dart';
import 'bookmarks_screen.dart';
import 'navigate_screen.dart';
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
  BookmarkLayer? _bookmarkLayer;
  BoundaryLayer? _regionOutline;

  /// Set just before a basemap-swapping jump (see [_goTo]) so the freshly
  /// remounted [BaseMap] opens on the searched spot instead of the new
  /// region's bookmarked center — cleared once consumed by [_initialCamera].
  CameraPosition? _pendingCamera;

  CameraPosition get _initialCamera =>
      _pendingCamera ?? CameraPosition(target: _region.center, zoom: 13);

  void _onMapCreated(MapLibreMapController c) {
    _c = c;
    _bookmarkLayer = BookmarkLayer(c);
    _bookmarkLayer!.listen(_onBookmarkTapped);
    // Faint, no-fill outline — deliberately styled differently from
    // AuthorScreen's generation-boundary tool (which uses this same class
    // with its default teal fill) since this one is purely informational,
    // not an active editing target.
    _regionOutline = BoundaryLayer(
      c,
      id: 'region-outline',
      lineColor: '#757575',
      fillOpacity: 0,
      lineWidth: 1.5,
      lineDasharray: const [4, 3],
    );
  }

  /// Bookmark markers use the circle/symbol annotation API (see
  /// [BookmarkLayer]), which — like [AuthorScreen]'s cue markers — needs the
  /// style loaded before it'll draw, not just the controller created.
  Future<void> _onStyleLoaded() async {
    await _loadBookmarks();
    await _drawRegionOutline();
  }

  /// Outlines the active region's real download bbox — only meaningful for
  /// a *downloaded* region (its own separate, genuinely bounded pmtiles
  /// file); the bundled basemap covers ~100km as one file, so an outline for
  /// it wouldn't mark a boundary anyone would actually reach by panning.
  /// This is the fix for "the map looks like it covers more area than it
  /// actually has data for" — panning past a downloaded region's real edge
  /// doesn't auto-swap back to the bundled map the way a search/bookmark
  /// jump does, so without this there's no visual cue you've left real data
  /// behind (see BrowseMapScreen's `_goTo`).
  Future<void> _drawRegionOutline() async {
    if (!_region.isDownloaded) {
      await _regionOutline?.setPolygon(null);
      return;
    }
    final r = _region;
    await _regionOutline?.ensure();
    await _regionOutline?.setPolygon([
      LatLng(r.north, r.west),
      LatLng(r.north, r.east),
      LatLng(r.south, r.east),
      LatLng(r.south, r.west),
    ]);
  }

  /// (Re)loads bookmarks onto the map, filtered to whatever's reachable on
  /// the currently-loaded basemap — same reasoning as
  /// [SearchService.search]'s `confineTo`: a bookmark elsewhere would jump
  /// to nothing rendered if tapped, since it lives on a different pmtiles
  /// file. Called after `onStyleLoaded` (a basemap swap remounts [BaseMap],
  /// which re-fires it) and after any add/edit/delete so the pins stay
  /// current.
  Future<void> _loadBookmarks() async {
    final all = await TrailStore.instance.allBookmarks();
    final reachable = all
        .where((b) => regionForPoint(b.position).mapAsset == _region.mapAsset)
        .toList();
    await _bookmarkLayer?.setBookmarks(reachable);
  }

  Future<void> _onMapLongClick(Point<double> point, LatLng coords) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.bookmark_add),
              title: const Text('Add bookmark here'),
              onTap: () => Navigator.pop(context, 'bookmark'),
            ),
            ListTile(
              leading: const Icon(Icons.route),
              title: const Text('Start a new trail here'),
              onTap: () => Navigator.pop(context, 'trail'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'bookmark') {
      await _addBookmark(coords);
    } else if (choice == 'trail') {
      await _startTrailHere(coords);
    }
  }

  Future<void> _addBookmark(LatLng position) async {
    final b = await showBookmarkEditSheet(context, position: position);
    if (b == null) return;
    await TrailStore.instance.saveBookmark(b);
    await _loadBookmarks();
  }

  Future<void> _startTrailHere(LatLng position) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AuthorScreen(
          region: regionForPoint(position),
          initialCenter: position,
        ),
      ),
    );
  }

  Future<void> _onBookmarkTapped(Bookmark b) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(b.icon, color: b.category.color),
              title: Text(b.name),
              subtitle: Text(
                  b.note.isEmpty ? b.category.label : '${b.category.label} · ${b.note}'),
            ),
            ListTile(
              leading: const Icon(Icons.route),
              title: const Text('Start a new trail here'),
              onTap: () => Navigator.pop(context, 'trail'),
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'trail':
        await _startTrailHere(b.position);
      case 'edit':
        final updated =
            await showBookmarkEditSheet(context, position: b.position, existing: b);
        if (updated != null) {
          await TrailStore.instance.saveBookmark(updated);
          await _loadBookmarks();
        }
      case 'delete':
        if (b.id != null) {
          await TrailStore.instance.deleteBookmark(b.id!);
          await _loadBookmarks();
        }
    }
  }

  /// Opens Directions on wherever this screen's camera is currently looking
  /// (e.g. right after "my location") rather than the region's generic
  /// bookmarked center — [NavigateScreen] owns a separate map/camera, so it
  /// has no way to know that on its own without being told.
  Future<void> _openDirections() async {
    final camera = await _c?.queryCameraPosition();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => NavigateScreen(region: _region, initialCamera: camera)),
    );
  }

  Future<void> _openBookmarksList() async {
    final picked = await Navigator.push<Bookmark>(
        context, MaterialPageRoute(builder: (_) => const BookmarksScreen()));
    // Refresh regardless of pick — the list screen edits/deletes in place.
    await _loadBookmarks();
    if (picked != null) _goTo(picked.position);
  }

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
            onStyleLoaded: _onStyleLoaded,
            onMapLongClick: _onMapLongClick,
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
                  const SizedBox(height: 10),
                  FloatingActionButton(
                    heroTag: 'browseBookmarks',
                    mini: true,
                    tooltip: 'Bookmarks',
                    onPressed: _openBookmarksList,
                    child: const Icon(Icons.bookmark),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton(
                    heroTag: 'browseDirections',
                    mini: true,
                    tooltip: 'Directions',
                    onPressed: _openDirections,
                    child: const Icon(Icons.directions),
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
