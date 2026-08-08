import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/region.dart';
import '../services/offline_map.dart';
import '../services/region_downloader.dart';

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

      // Size estimate (samples a spread of tiles).
      _showBlocking('Estimating size…');
      final estBytes = await RegionDownloader().estimateBytes(w, s, e, n);
      final tiles = RegionDownloader.tilesFor(w, s, e, n).length;
      if (mounted) Navigator.pop(context); // close "estimating"
      if (!mounted) return;

      final name = await _askConfirm(estBytes, tiles);
      if (name == null) return;

      final id = 'dl_${DateTime.now().millisecondsSinceEpoch}';
      final progress =
          ValueNotifier<DownloadProgress>(DownloadProgress(0, tiles, 0));
      final downloader = RegionDownloader();
      final future = downloader.download(
        id: id,
        name: name,
        west: w, south: s, east: e, north: n,
        onProgress: (p) => progress.value = p,
      );
      _showProgress(progress, downloader);
      final region = await future;
      if (mounted) Navigator.pop(context); // close progress
      if (region == null) {
        _toast('Download cancelled');
        return;
      }
      await addUserRegion(region);
      // A handful of tiles that never downloaded (even after retries) leave
      // gaps that render as oversized, blocky water/roads/buildings in that
      // spot — same fix as re-running the download, so say so plainly
      // rather than leaving an inaccurate-looking map unexplained. Must
      // toast before popping — mounted goes false right after.
      final missing = downloader.failedTileCount;
      if (missing > 0) {
        _toast(missing == 1
            ? '1 map tile failed to download — that spot may look a bit '
                'off. Re-download this area if it matters.'
            : '$missing map tiles failed to download — some spots may look '
                'a bit off. Re-download this area if it matters.');
      }
      if (mounted) Navigator.pop(context, region.id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askConfirm(int estBytes, int tiles) {
    final controller = TextEditingController(text: 'My area');
    final mb = (estBytes / 1e6).toStringAsFixed(estBytes < 1e7 ? 1 : 0);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download this area?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                    ? 'My area'
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

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
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
