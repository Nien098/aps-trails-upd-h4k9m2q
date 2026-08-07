import 'dart:io';
import 'dart:math' show cos, max, min, pi;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/activity.dart';
import '../models/region.dart';
import '../services/geo.dart';
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

  /// Optional stats a walker can add to the card beyond the always-shown
  /// Distance/Time/Pace headline row — key -> label. Selection is
  /// remembered across shares via Settings.shareStats rather than reset
  /// every time.
  static const _availableStats = {
    'elevation': 'Elevation gain',
    'speed': 'Avg speed',
    'calories': 'Calories',
    'movingTime': 'Moving time',
    'movingPace': 'Moving pace',
  };

  final _cardKey = GlobalKey();
  late final TextEditingController _caption;
  late Set<String> _selectedStats;
  bool _sharing = false;

  MapLibreMapController? _mapC;
  RouteLayer? _routeLayer;

  /// Android's platform-view/GL surface can re-fire onStyleLoaded (surface
  /// recreated, e.g. around a Navigator push transition) — without this
  /// guard a second call creates a fresh RouteLayer and re-adds the route
  /// source under the same fixed id while the first call's setRoute/
  /// animateCamera is still in flight, two overlapping updates racing on
  /// the same controller and producing visibly wrong intermediate states
  /// (the route flickering, or the camera appearing to "recalculate").
  bool _styleLoadHandled = false;

  /// True once the route is drawn and the camera has finished fitting to
  /// it (plus a short settle delay for tiles to actually paint) — see
  /// [_onMapStyleLoaded]. The Share button stays disabled until this (or
  /// [_mapFailed]) is true, so [_share] only ever captures a map that's
  /// already confirmed correct on screen.
  bool _mapReady = false;

  /// True if the track was too short to map, or route/camera setup threw —
  /// falls back to the self-drawn [_RouteThumbnailPainter] instead of an
  /// empty or broken map area.
  bool _mapFailed = false;

  List<LatLng> get _points => [for (final p in widget.activity.track) p.position];

  Region get _region =>
      _points.isEmpty ? kDefaultRegion : regionForPoint(_points.first);

  CameraPosition get _initialCamera => CameraPosition(
        target: _points.isEmpty ? _region.center : _points.first,
        zoom: 14,
      );

  bool get _canShare => _mapReady || _mapFailed;

  @override
  void initState() {
    super.initState();
    final a = widget.activity;
    final dist = Settings.instance.formatDistance(a.distanceMeters);
    _caption = TextEditingController(text: 'I walked $dist on ${a.trailName}!');
    _selectedStats = Set.of(Settings.instance.shareStats.value);
    if (_points.length < 2) _mapFailed = true;
  }

  void _toggleStat(String key, bool enabled) {
    setState(() {
      if (enabled) {
        _selectedStats.add(key);
      } else {
        _selectedStats.remove(key);
      }
    });
    Settings.instance.setShareStats(_selectedStats);
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  /// Draws the route on the real map and fits the camera to it. Deliberately
  /// does *not* use [MapLibreMapController.takeSnapshot] — tried first, but
  /// real-device testing showed it can capture a stale/unsettled render (a
  /// zoomed-out default view with no route) independently of what's already
  /// correctly showing on screen, with no reliable signal for when it's
  /// actually safe to call. Capturing the already-confirmed-correct on-
  /// screen map directly (via the whole-card RenderRepaintBoundary in
  /// [_share], once the user can actually see it's right) doesn't have that
  /// problem — same mechanism already used for the rest of the card.
  Future<void> _onMapStyleLoaded() async {
    if (_styleLoadHandled) return;
    _styleLoadHandled = true;
    final c = _mapC;
    if (c == null || _points.length < 2) {
      if (mounted) setState(() => _mapFailed = true);
      return;
    }
    try {
      _routeLayer = RouteLayer(c);
      await _routeLayer!.ensure();
      await _routeLayer!.setRoute(_points, '#1565C0');
      await _drawDistanceMarkers(c);
      await c.animateCamera(CameraUpdate.newLatLngBounds(
        _boundsOf(_points),
        left: 30,
        right: 30,
        top: 30,
        bottom: 30,
      ));
      // animateCamera's future completes once the animation finishes, not
      // once every tile at the new position/zoom has actually painted.
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) setState(() => _mapReady = true);
    } catch (_) {
      if (mounted) setState(() => _mapFailed = true);
    }
  }

  /// Runkeeper-style distance badges along the route (its own "1 mi"/"2 mi"
  /// rounded-square pins — same idea here, but drawn in this app's own
  /// marker style: a solid circle + white number, matching the numbered
  /// cue markers guide_screen.dart already draws, rather than copying
  /// Runkeeper's exact look). Batched into single addCircles/addSymbols
  /// calls — see the comment on _drawCues in guide_screen.dart for why:
  /// each add call on this plugin rebuilds its whole layer from scratch, so
  /// doing it one marker at a time both races the two layers against each
  /// other and is needlessly slow.
  Future<void> _drawDistanceMarkers(MapLibreMapController c) async {
    final markers = _distanceMarkerPositions(_points, Settings.instance.metric.value);
    if (markers.isEmpty) return;
    await c.addCircles([
      for (final m in markers)
        CircleOptions(
          geometry: m,
          circleRadius: 13,
          circleColor: '#1B5E20',
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2,
        ),
    ]);
    await c.addSymbols([
      for (var i = 0; i < markers.length; i++)
        SymbolOptions(
          geometry: markers[i],
          textField: '${i + 1}',
          textSize: 13,
          textColor: '#ffffff',
        ),
    ]);
    // Same fix as guide_screen.dart's cue labels: MapLibre's default
    // collision avoidance can hide a label judged too close to another,
    // which a run of closely-spaced markers can trigger easily.
    await c.setSymbolTextAllowOverlap(true);
  }

  /// LatLng positions at each whole distance-unit boundary along [pts] (1 km
  /// or 1 mi depending on [metric]) — interpolated between the two track
  /// points straddling each boundary, the same idea as
  /// ActivityDetailScreen's per-unit split computation but returning a
  /// position instead of a time.
  static List<LatLng> _distanceMarkerPositions(List<LatLng> pts, bool metric) {
    if (pts.length < 2) return const [];
    final unitMeters = metric ? 1000.0 : 1609.344;
    final markers = <LatLng>[];
    var cum = 0.0;
    var nextBoundary = unitMeters;
    for (var i = 1; i < pts.length; i++) {
      final segDist = metersBetween(pts[i - 1], pts[i]);
      while (cum + segDist >= nextBoundary) {
        final overshoot = cum + segDist - nextBoundary;
        final frac = segDist <= 0 ? 0.0 : 1 - (overshoot / segDist);
        markers.add(LatLng(
          pts[i - 1].latitude + (pts[i].latitude - pts[i - 1].latitude) * frac,
          pts[i - 1].longitude + (pts[i].longitude - pts[i - 1].longitude) * frac,
        ));
        nextBoundary += unitMeters;
      }
      cum += segDist;
    }
    return markers;
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
    if (_sharing || !_canShare) return;
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
                extraStats: _selectedStats,
                statLabels: _availableStats,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Also include on card', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final entry in _availableStats.entries)
                FilterChip(
                  label: Text(entry.value),
                  selected: _selectedStats.contains(entry.key),
                  onSelected: (v) => _toggleStat(entry.key, v),
                ),
            ],
          ),
          const SizedBox(height: 16),
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
            onPressed: (_sharing || !_canShare) ? null : _share,
            icon: (_sharing || !_canShare)
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.share),
            label: Text(_sharing
                ? 'Preparing…'
                : !_canShare
                    ? 'Loading map…'
                    : 'Share'),
          ),
        ],
      ),
    );
  }

  /// The map slot inside the card: the self-drawn fallback thumbnail if
  /// route/camera setup failed, otherwise the real live map — with a
  /// loading scrim over it until [_mapReady], both so the zoom-to-fit
  /// animation reads as an intentional "preparing" state rather than a
  /// glitch, and so it's obvious the Share button being disabled matches
  /// what's still happening on screen.
  Widget _buildMapArea() {
    if (_mapFailed) {
      return _points.length >= 2
          ? CustomPaint(painter: _RouteThumbnailPainter(_points))
          : const SizedBox.shrink();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          BaseMap(
            region: _region,
            initialCamera: _initialCamera,
            onMapCreated: (c) => _mapC = c,
            onStyleLoaded: _onMapStyleLoaded,
          ),
          if (!_mapReady)
            Container(
              color: Colors.white.withValues(alpha: 0.7),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
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
    required this.extraStats,
    required this.statLabels,
  });
  final Activity activity;
  final double mapAreaHeight;
  final Widget mapChild;

  /// Which optional stat keys (from [statLabels]) to render, in a fixed
  /// order (see [_ShareActivityScreenState._availableStats]) rather than
  /// whatever order the Set happens to iterate in.
  final Set<String> extraStats;
  final Map<String, String> statLabels;

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
          if (extraStats.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 20,
              runSpacing: 10,
              children: [
                // Iterate statLabels (a fixed, declared order) rather than
                // the Set directly, so the card's layout doesn't depend on
                // whatever order the user happened to tap the chips in.
                for (final key in statLabels.keys)
                  if (extraStats.contains(key))
                    SizedBox(
                      width: 140,
                      child: _stat(statLabels[key]!, _statValue(s, a, key)),
                    ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Formats the value for one optional stat key — see
  /// [_ShareActivityScreenState._availableStats] for what each key means.
  String _statValue(Settings s, Activity a, String key) {
    switch (key) {
      case 'elevation':
        return '↑ ${s.formatElevation(a.elevGainMeters)}';
      case 'speed':
        return s.formatSpeed(a.distanceMeters, a.durationSec);
      case 'calories':
        return '${s.estimateCalories(a.distanceMeters)} kcal';
      case 'movingTime':
        return Settings.formatDuration(a.movingSeconds());
      case 'movingPace':
        return s.formatPace(a.distanceMeters, a.movingSeconds());
      default:
        return '';
    }
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
