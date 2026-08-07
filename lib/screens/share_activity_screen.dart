import 'dart:io';
import 'dart:math' show cos, max, min, pi;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/activity.dart';
import '../models/region.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../widgets/base_map.dart';

/// Runkeeper-style "share this walk" flow: previews a stats+route card, then
/// hands it to the OS share sheet (SMS/WhatsApp/email/etc.) as an image plus
/// a caption. Distinct from [TrailShare] (lib/services/trail_share.dart),
/// which shares the *route definition* for another TrailGuide install to
/// import — this shares a completed walk's *results* with anyone, app or not.
class ShareActivityScreen extends StatefulWidget {
  const ShareActivityScreen({super.key, required this.activity});
  final Activity activity;

  @override
  State<ShareActivityScreen> createState() => _ShareActivityScreenState();
}

class _ShareActivityScreenState extends State<ShareActivityScreen> {
  static const _mapAreaHeight = 160.0;

  final _cardKey = GlobalKey();
  late final TextEditingController _caption;
  bool _sharing = false;

  MapLibreMapController? _mapC;
  RouteLayer? _routeLayer;

  /// Native PNG bytes of the real map + route, captured via
  /// [MapLibreMapController.takeSnapshot] once it settles — see
  /// [_onMapStyleLoaded]. Null until ready (or capture failed).
  Uint8List? _mapSnapshot;

  /// True once the snapshot attempt has finished one way or the other —
  /// either [_mapSnapshot] is set, or it failed and the self-drawn
  /// [_RouteThumbnailPainter] fallback is used instead.
  bool _mapCaptureFailed = false;

  List<LatLng> get _points => [for (final p in widget.activity.track) p.position];

  Region get _region =>
      _points.isEmpty ? kDefaultRegion : regionForPoint(_points.first);

  CameraPosition get _initialCamera => CameraPosition(
        target: _points.isEmpty ? _region.center : _points.first,
        zoom: 14,
      );

  bool get _mapReady => _mapSnapshot != null || _mapCaptureFailed;

  @override
  void initState() {
    super.initState();
    final a = widget.activity;
    final dist = Settings.instance.formatDistance(a.distanceMeters);
    _caption = TextEditingController(text: 'I walked $dist on ${a.trailName}!');
    if (_points.length < 2) _mapCaptureFailed = true;
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  /// Draws the route on a real map, fits the camera to it, waits for tiles
  /// to actually settle, then captures a native PNG via
  /// [MapLibreMapController.takeSnapshot] — a dedicated native rendering
  /// call, distinct from (and far more reliable than) capturing the map
  /// through Flutter's own widget compositor, since the map is a native
  /// Android platform view. Once captured, [build] swaps the live map for
  /// the plain PNG, so the later whole-card [RenderRepaintBoundary] capture
  /// (in [_share]) never has to touch the platform view at all — it only
  /// ever captures a plain `Image.memory`, the same as any other picture.
  Future<void> _onMapStyleLoaded() async {
    final c = _mapC;
    if (c == null || _points.length < 2) {
      if (mounted) setState(() => _mapCaptureFailed = true);
      return;
    }
    try {
      _routeLayer = RouteLayer(c);
      await _routeLayer!.ensure();
      await _routeLayer!.setRoute(_points, '#1565C0');
      await c.animateCamera(CameraUpdate.newLatLngBounds(
        _boundsOf(_points),
        left: 30,
        right: 30,
        top: 30,
        bottom: 30,
      ));
      // animateCamera's future completes once the animation finishes, not
      // once every tile at the new position/zoom has actually painted —
      // give it a moment before snapshotting, or the capture can catch the
      // map mid-render.
      await Future.delayed(const Duration(milliseconds: 600));
      final bytes = await c.takeSnapshot();
      if (mounted) setState(() => _mapSnapshot = bytes);
    } catch (_) {
      if (mounted) setState(() => _mapCaptureFailed = true);
    }
  }

  static LatLngBounds _boundsOf(List<LatLng> pts) {
    var minLat = pts.first.latitude, maxLat = pts.first.latitude;
    var minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      minLat = p.latitude < minLat ? p.latitude : minLat;
      maxLat = p.latitude > maxLat ? p.latitude : maxLat;
      minLng = p.longitude < minLng ? p.longitude : minLng;
      maxLng = p.longitude > maxLng ? p.longitude : maxLng;
    }
    return LatLngBounds(
        southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }

  /// Captures the card (map slot already swapped to a plain image by now —
  /// see [_mapReady]/[build]) to a PNG, writes it to a temp file the same
  /// way TrailShare.shareTrail already does, and opens the OS share sheet
  /// with it plus the caption text.
  Future<void> _share() async {
    if (_sharing || !_mapReady) return;
    setState(() => _sharing = true);
    try {
      final boundary =
          _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final dir = await getTemporaryDirectory();
      final safe = widget.activity.trailName
          .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
          .trim();
      final file = File('${dir.path}/${safe.isEmpty ? "walk" : safe}_share.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: _caption.text,
      ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not share — try again')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Share walk')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          Center(
            child: RepaintBoundary(
              key: _cardKey,
              child: _ShareCard(
                activity: widget.activity,
                mapAreaHeight: _mapAreaHeight,
                mapChild: _buildMapArea(),
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _caption,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Message',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: (_sharing || !_mapReady) ? null : _share,
            icon: (_sharing || !_mapReady)
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.share),
            label: Text(_sharing
                ? 'Preparing…'
                : !_mapReady
                    ? 'Loading map…'
                    : 'Share'),
          ),
        ],
      ),
    );
  }

  /// The map slot inside the card: the live map while it's loading/being
  /// captured, then swapped for the captured PNG (or the self-drawn
  /// fallback thumbnail if the native snapshot failed) — same size either
  /// way so nothing jumps when it swaps, and the Share button stays
  /// disabled the whole time the live map is still showing here.
  Widget _buildMapArea() {
    if (_mapSnapshot != null) {
      return Image.memory(_mapSnapshot!, fit: BoxFit.cover);
    }
    if (_mapCaptureFailed) {
      return _points.length >= 2
          ? CustomPaint(painter: _RouteThumbnailPainter(_points))
          : const SizedBox.shrink();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BaseMap(
        region: _region,
        initialCamera: _initialCamera,
        onMapCreated: (c) => _mapC = c,
        onStyleLoaded: _onMapStyleLoaded,
      ),
    );
  }
}

/// The shareable card itself. [mapChild] is whatever [_buildMapArea]
/// currently returns (live map while loading, then a plain captured image).
class _ShareCard extends StatelessWidget {
  const _ShareCard({
    required this.activity,
    required this.mapAreaHeight,
    required this.mapChild,
  });
  final Activity activity;
  final double mapAreaHeight;
  final Widget mapChild;

  static const _brand = Color(0xFF1B5E20);

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    final a = activity;
    return Container(
      width: 340,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.terrain, color: _brand, size: 22),
              SizedBox(width: 6),
              Text('APS Trails',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: _brand, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 12),
          Text(a.trailName,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(_dateLine(a.startedAt),
              style: const TextStyle(fontSize: 13, color: Color(0xFF6A6A6A))),
          const SizedBox(height: 16),
          if (a.track.length >= 2)
            SizedBox(height: mapAreaHeight, width: double.infinity, child: mapChild),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _stat('Distance', s.formatDistance(a.distanceMeters))),
              Expanded(child: _stat('Time', Settings.formatDuration(a.durationSec))),
              Expanded(
                  child:
                      _stat('Pace', s.formatPace(a.distanceMeters, a.durationSec))),
            ],
          ),
          if (a.elevGainMeters > 0) ...[
            const SizedBox(height: 10),
            _stat('Elevation gain', '↑ ${s.formatElevation(a.elevGainMeters)}'),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF6A6A6A))),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static String _dateLine(DateTime d) =>
      '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Self-drawn route outline from the activity's own track — used only as a
/// fallback if the native map snapshot fails (see
/// [_ShareActivityScreenState._onMapStyleLoaded]). Projects lat/lng into a
/// locally equirectangular space (scaling longitude by cos(latitude), same
/// idea as the routing math in lib/services/trail_router.dart) so the shape
/// isn't stretched, then fits it to the canvas preserving aspect ratio.
class _RouteThumbnailPainter extends CustomPainter {
  _RouteThumbnailPainter(this.points);
  final List<LatLng> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final lats = points.map((p) => p.latitude);
    final lngs = points.map((p) => p.longitude);
    final minLat = lats.reduce(min), maxLat = lats.reduce(max);
    final minLng = lngs.reduce(min), maxLng = lngs.reduce(max);
    final midLat = (minLat + maxLat) / 2;
    final lngScale = cos(midLat * pi / 180);

    final spanX = (maxLng - minLng) * lngScale;
    final spanY = maxLat - minLat;

    const pad = 12.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    final scale = spanX <= 1e-9 && spanY <= 1e-9
        ? 1.0
        : min(
            spanX <= 1e-9 ? double.infinity : availW / spanX,
            spanY <= 1e-9 ? double.infinity : availH / spanY,
          );

    final offsetX = pad + (availW - spanX * scale) / 2;
    final offsetY = pad + (availH - spanY * scale) / 2;

    Offset project(LatLng p) => Offset(
          (p.longitude - minLng) * lngScale * scale + offsetX,
          // Latitude increases northward but canvas y increases downward.
          (maxLat - p.latitude) * scale + offsetY,
        );

    final path = Path()..moveTo(project(points.first).dx, project(points.first).dy);
    for (final p in points.skip(1)) {
      final o = project(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF1565C0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    canvas.drawCircle(project(points.first), 5, Paint()..color = const Color(0xFF2E7D32));
    canvas.drawCircle(project(points.last), 5, Paint()..color = const Color(0xFFC62828));
  }

  @override
  bool shouldRepaint(_RouteThumbnailPainter oldDelegate) =>
      oldDelegate.points != points;
}
