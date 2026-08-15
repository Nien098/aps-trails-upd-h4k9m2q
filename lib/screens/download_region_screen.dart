import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/region.dart';
import '../services/offline_map.dart';
import '../services/pmtiles_reader.dart';
import '../services/region_downloader.dart';
import '../services/trail_store.dart';

/// Frame an area on the live online map, then download it as an offline region
/// that works with the normal editor/guide just like the bundled maps.
class DownloadRegionScreen extends StatefulWidget {
  const DownloadRegionScreen({super.key});

  @override
  State<DownloadRegionScreen> createState() => _DownloadRegionScreenState();
}

class _DownloadRegionScreenState extends State<DownloadRegionScreen> {
  MapLibreMapController? _c;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Download a map area')),
      body: FutureBuilder<String>(
        future: OfflineMap.onlineStyleFile(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Stack(
            children: [
              MapLibreMap(
                styleString: snap.data!,
                initialCameraPosition:
                    const CameraPosition(target: LatLng(0, 110), zoom: 4),
                minMaxZoomPreference: const MinMaxZoomPreference(2, 16),
                onMapCreated: (c) => _c = c,
                onStyleLoadedCallback: _goToMe,
              ),
              const Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: _Hint(),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _startDownload,
                  icon: const Icon(Icons.download),
                  label: const Text('Download this area'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _goToMe() async {
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
      await _c?.animateCamera(CameraUpdate.newLatLngZoom(
          LatLng(pos.latitude, pos.longitude), 13));
    } catch (_) {}
  }

  /// Degrees of slack when deciding whether an existing downloaded region
  /// is "worth merging" with a new selection — a small gap (two
  /// independently-drawn rectangles will essentially never share an exact
  /// edge) still counts, but two regions with real daylight between them
  /// correctly don't. Roughly 5km — the same order of magnitude as the
  /// Overpass adaptive-cell floor already established elsewhere in this
  /// project (region_downloader.dart's _minCellDeg).
  static const _mergeTolerance = 0.05;

  Future<void> _startDownload() async {
    final c = _c;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final b = await c.getVisibleRegion();
      final w = b.southwest.longitude,
          s = b.southwest.latitude,
          e = b.northeast.longitude,
          n = b.northeast.latitude;

      final mergeCandidates = userRegions
          .where((r) => RegionDownloader.bboxesOverlap(
              w, s, e, n, r.west, r.south, r.east, r.north,
              tolerance: _mergeTolerance))
          .toList();

      // west/south/east/north stay the plain selection unless the author
      // chooses to merge, in which case they widen to the union of the
      // selection and every region being merged away — everything below
      // (estimate, naming, the download itself) then transparently operates
      // on that wider area.
      var west = w, south = s, east = e, north = n;
      var merging = const <Region>[];
      if (mergeCandidates.isNotEmpty) {
        final choice = await _askMergeChoice(mergeCandidates);
        if (choice == null) return; // backed out entirely
        if (choice) {
          merging = mergeCandidates;
          for (final r in merging) {
            west = math.min(west, r.west);
            south = math.min(south, r.south);
            east = math.max(east, r.east);
            north = math.max(north, r.north);
          }
        }
      }

      // Size estimate (samples a spread of tiles). For a merge this is the
      // union area's full size, not just the genuinely-missing delta —
      // simpler and safe (never understates the wait), if less precise
      // than it could be; the download itself still only actually fetches
      // what isn't already reusable (see RegionDownloader's tile reuse).
      _showBlocking('Estimating size…');
      final estBytes = await RegionDownloader().estimateBytes(west, south, east, north);
      final tiles = RegionDownloader.tilesFor(west, south, east, north).length;
      final suggestedName = await _suggestName(
          c,
          LatLngBounds(
              southwest: LatLng(south, west), northeast: LatLng(north, east)));
      if (mounted) Navigator.pop(context); // close "estimating"
      if (!mounted) return;

      final name = await _askConfirm(estBytes, tiles, suggestedName, merging: merging);
      if (name == null) return;

      final id = 'dl_${DateTime.now().millisecondsSinceEpoch}';
      final progress =
          ValueNotifier<DownloadProgress>(DownloadProgress(0, tiles, 0));
      final downloader = RegionDownloader();
      final future = downloader.download(
        id: id,
        name: name,
        west: west, south: south, east: east, north: north,
        onProgress: (p) => progress.value = p,
      );
      _showProgress(progress, downloader);
      final region = await future;
      if (mounted) Navigator.pop(context); // close progress
      if (region == null) {
        _toast('Download cancelled');
        return;
      }

      if (merging.isNotEmpty) {
        // Verify before touching anything about the regions being merged
        // away — a failed/incomplete new archive must never cost the
        // author their existing, already-working separate maps.
        if (!await _verifyMerge(region, merging)) {
          _toast("Merge didn't complete cleanly — kept your existing "
              'separate maps untouched. Try again later.');
          return;
        }
      }

      await addUserRegion(region);
      if (merging.isNotEmpty) {
        for (final r in merging) {
          await removeUserRegion(r.id);
        }
        await _reassignTrails(merging.map((r) => r.id).toSet(), region.id);
        _toast('Merged into "${region.name}"');
      }
      // A handful of tiles that never downloaded (even after retries) leave
      // gaps that render as oversized, blocky water/roads/buildings in that
      // spot — same fix as re-running the download, so say so plainly
      // rather than leaving an inaccurate-looking map unexplained. Must
      // toast before popping — mounted goes false right after.
      // Up to three of these can queue back-to-back (Flutter shows each
      // SnackBar in a queued sequence, not overlapping) — the default 4s
      // duration was too short to actually read one, let alone notice a
      // later one arrived at all (reported directly: a coverage warning
      // "didn't stay on screen long enough").
      const warningDuration = Duration(seconds: 7);
      final missing = downloader.failedTileCount;
      if (missing > 0) {
        _toast(
            missing == 1
                ? '1 map tile failed to download — that spot may look a bit '
                    'off. Re-download this area if it matters.'
                : '$missing map tiles failed to download — some spots may '
                    'look a bit off. Re-download this area if it matters.',
            duration: warningDuration);
      }
      final streetsWarning = RegionDownloader.coverageWarning(
          'Street search', downloader.streetsCoverage);
      if (streetsWarning != null) {
        _toast(streetsWarning, duration: warningDuration);
      }
      final routeWarning = RegionDownloader.coverageWarning(
          'Offline route planning', downloader.routeGraphCoverage);
      if (routeWarning != null) {
        _toast(routeWarning, duration: warningDuration);
      }
      if (mounted) Navigator.pop(context, region.id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks whether to merge with the region(s) the new selection overlaps —
  /// null if the author backs out entirely, true to merge (widening the
  /// download to their union and replacing the old separate map(s) with
  /// one), false to just download the new selection separately as before.
  Future<bool?> _askMergeChoice(List<Region> candidates) {
    final names = candidates.map((r) => '"${r.name}"').join(', ');
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Merge with existing map?'),
        content: Text(
            'This area overlaps $names, which you already downloaded. '
            'Merge them into one map instead of keeping a separate '
            'download? Trails from the existing map keep working either way.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep separate')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Merge')),
        ],
      ),
    );
  }

  /// Sanity check before a merge is allowed to delete any old region: the
  /// freshly-downloaded merged archive must actually open and must have at
  /// least as many tiles as the largest region it's replacing — a cheap,
  /// strong invariant (a real merge over a union area should never have
  /// *fewer* tiles than any single contributor). Only once this passes does
  /// the caller proceed to delete the old regions.
  Future<bool> _verifyMerge(Region newRegion, List<Region> oldRegions) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final newReader =
          await PmTilesReader.open('${docs.path}/map/${newRegion.id}.pmtiles');
      final newCount = (await newReader.listTileIds()).length;
      await newReader.close();
      var maxOldCount = 0;
      for (final r in oldRegions) {
        try {
          final oldReader =
              await PmTilesReader.open('${docs.path}/map/${r.id}.pmtiles');
          final count = (await oldReader.listTileIds()).length;
          await oldReader.close();
          if (count > maxOldCount) maxOldCount = count;
        } catch (_) {
          // An old region's file failing to open doesn't block the merge —
          // there's nothing to compare against from it, not a reason to
          // distrust the new archive.
        }
      }
      return newCount >= maxOldCount;
    } catch (_) {
      return false;
    }
  }

  /// Repoints every trail belonging to one of [oldIds] at [newId] — the
  /// merge already knows exactly which trails are affected, so this is a
  /// direct id rewrite rather than waiting on regionForTrail's geography
  /// fallback (region.dart) to eventually self-heal them one at a time as
  /// each is opened. That fallback still exists as a safety net regardless
  /// (e.g. if a trail somehow isn't returned by this pass).
  Future<void> _reassignTrails(Set<String> oldIds, String newId) async {
    final trails = await TrailStore.instance.all();
    for (final t in trails) {
      if (oldIds.contains(t.regionId)) {
        t.regionId = newId;
        await TrailStore.instance.save(t);
      }
    }
  }

  /// Best-effort placeholder name for the naming field — the dominant place
  /// label (city/town, falling back to region/country) already rendered on
  /// the live preview map within [bounds], so the author can just accept it,
  /// tweak it ("Tangerang Trip"), or clear it and type their own instead of
  /// always starting from a generic "My area". Returns null (leaving the
  /// generic default) if nothing usable is found — a rural/unlabeled area,
  /// or a query failure, are both fine to just fall through silently for.
  ///
  /// Tries `places_locality` first (the actual city/town labels — see
  /// assets/style/style.json), then `places_region`, then `places_country`,
  /// stopping at the first tier with any results; picks the candidate with
  /// the highest `population_rank` (Protomaps' place-importance field —
  /// higher is bigger/more prominent) as "the" dominant place, breaking ties
  /// by whichever is closest to the bbox's center.
  Future<String?> _suggestName(
      MapLibreMapController c, LatLngBounds bounds) async {
    try {
      final rect = await _screenRectForBounds(c, bounds);
      final center = LatLng(
        (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
        (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
      );
      for (final layer in const ['places_locality', 'places_region', 'places_country']) {
        final raw = await c.queryRenderedFeaturesInRect(rect, [layer], null);
        String? best;
        double? bestRank;
        double? bestDist;
        for (final f in raw) {
          final feature = f is String ? jsonDecode(f) : f;
          if (feature is! Map) continue;
          final props =
              (feature['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
          final name = (props['name:en'] ?? props['pgf:name'] ?? props['name'])
              as String?;
          if (name == null || name.trim().isEmpty) continue;
          final rank = (props['population_rank'] as num?)?.toDouble() ?? 0;
          double dist = 0;
          final geom = feature['geometry'];
          if (geom is Map && geom['type'] == 'Point') {
            final coords = geom['coordinates'];
            if (coords is List && coords.length >= 2) {
              final lon = (coords[0] as num).toDouble();
              final lat = (coords[1] as num).toDouble();
              dist = math.sqrt(
                  math.pow(lat - center.latitude, 2) + math.pow(lon - center.longitude, 2));
            }
          }
          final better = best == null ||
              rank > bestRank! ||
              (rank == bestRank && dist < bestDist!);
          if (better) {
            best = name.trim();
            bestRank = rank;
            bestDist = dist;
          }
        }
        if (best != null) return best;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Same bbox-to-screen-pixel-Rect conversion as
  /// TrailRouter._screenRectForBounds — see that method's doc for why
  /// `toScreenLocation` is used instead of `MediaQuery` (device pixels vs
  /// logical pixels; `queryRenderedFeaturesInRect` needs the former).
  Future<Rect> _screenRectForBounds(
      MapLibreMapController c, LatLngBounds bounds) async {
    final corners = await Future.wait([
      c.toScreenLocation(bounds.northeast),
      c.toScreenLocation(bounds.southwest),
      c.toScreenLocation(
          LatLng(bounds.northeast.latitude, bounds.southwest.longitude)),
      c.toScreenLocation(
          LatLng(bounds.southwest.latitude, bounds.northeast.longitude)),
    ]);
    final xs = corners.map((p) => p.x.toDouble());
    final ys = corners.map((p) => p.y.toDouble());
    return Rect.fromLTRB(
        xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
  }

  Future<String?> _askConfirm(int estBytes, int tiles, String? suggestedName,
      {List<Region> merging = const []}) {
    final controller = TextEditingController(text: suggestedName ?? 'My area');
    final mb = (estBytes / 1e6).toStringAsFixed(estBytes < 1e7 ? 1 : 0);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(merging.isEmpty ? 'Download this area?' : 'Merge and download?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (merging.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                    'Replaces the separate map${merging.length > 1 ? 's' : ''} for '
                    '${merging.map((r) => r.name).join(', ')} with this one.',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF4A4A4A))),
              ),
            Text('Estimated size: ~$mb MB  ($tiles map tiles)',
                style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 6),
            const Text('This uses data now, then works fully offline.',
                style: TextStyle(fontSize: 13, color: Color(0xFF4A4A4A))),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name this area',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
                ctx,
                controller.text.trim().isEmpty
                    ? (suggestedName ?? 'My area')
                    : controller.text.trim()),
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  void _showProgress(
      ValueNotifier<DownloadProgress> progress, RegionDownloader downloader) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Downloading area'),
        content: ValueListenableBuilder<DownloadProgress>(
          valueListenable: progress,
          builder: (context, p, _) {
            final pct = p.total == 0 ? 0.0 : p.done / p.total;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // "Step X of Y" makes a new phase starting from a fresh 0%
                // unmistakable from actual progress going backward — each
                // phase (tiles, street names, route data, ...) has its own
                // done/total scale, so the percentage alone restarting is
                // otherwise easy to misread as a real regression.
                Text('Step ${p.step} of ${p.totalSteps} · ${p.phase}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: pct),
                const SizedBox(height: 12),
                Text('${(pct * 100).round()}%  ·  '
                    '${(p.bytes / 1e6).toStringAsFixed(1)} MB'),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => downloader.cancel(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showBlocking(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Text(msg),
          ],
        ),
      ),
    );
  }

  void _toast(String msg, {Duration duration = const Duration(seconds: 4)}) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg), duration: duration));
    }
  }
}

class _Hint extends StatelessWidget {
  const _Hint();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'Pan and zoom so the map shows the area you want, then tap Download. '
        'The whole visible map downloads — zoom in for a smaller, faster area.',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
