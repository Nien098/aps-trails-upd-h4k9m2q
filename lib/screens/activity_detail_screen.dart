import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/activity.dart';
import '../models/region.dart';
import '../services/geo.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/trail_store.dart';
import '../widgets/base_map.dart';
import '../widgets/mini_charts.dart';
import 'trail_progress_screen.dart';

/// Shows a single walk: summary stats, a map of the route walked, and per-unit
/// splits. Also used as the post-walk summary (justFinished == true).
class ActivityDetailScreen extends StatefulWidget {
  const ActivityDetailScreen({
    super.key,
    required this.activity,
    this.justFinished = false,
  });

  final Activity activity;
  final bool justFinished;

  @override
  State<ActivityDetailScreen> createState() => _ActivityDetailScreenState();
}

class _ActivityDetailScreenState extends State<ActivityDetailScreen> {
  MapLibreMapController? _c;
  RouteLayer? _route;

  Activity get a => widget.activity;

  List<LatLng> get _points => [for (final p in a.track) p.position];

  Region get _region =>
      _points.isEmpty ? kDefaultRegion : regionForPoint(_points.first);

  CameraPosition get _initialCamera => CameraPosition(
        target: _points.isEmpty ? _region.center : _points.first,
        zoom: 14,
      );

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null || _points.length < 2) return;
    _route = RouteLayer(c);
    await _route!.ensure();
    await _route!.setRoute(_points, '#1565C0');
    await c.animateCamera(CameraUpdate.newLatLngBounds(
      _boundsOf(_points),
      left: 40,
      right: 40,
      top: 40,
      bottom: 40,
    ));
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
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this walk?'),
        content: const Text('Removes it from your history. Trail totals stay.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && a.id != null) {
      await TrailStore.instance.deleteActivity(a.id!);
      if (mounted) Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.justFinished ? 'Walk complete' : a.trailName),
        leading: widget.justFinished
            ? IconButton(
                icon: const Icon(Icons.check),
                tooltip: 'Done',
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
              )
            : null,
        actions: [
          if (!widget.justFinished)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: ListView(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom),
        children: [
          if (widget.justFinished)
            Container(
              width: double.infinity,
              color: const Color(0xFFE8F5E9),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Text('Nice walk, ${a.trailName}!',
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1B5E20))),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(_dateLine(a.startedAt),
                style: const TextStyle(fontSize: 16, color: Color(0xFF4A4A4A))),
          ),
          // Stat grid.
          Padding(
            padding: const EdgeInsets.all(12),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.4,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              children: [
                _StatTile('Distance', s.formatDistance(a.distanceMeters),
                    Icons.straighten),
                _StatTile('Time', Settings.formatDuration(a.durationSec),
                    Icons.timer_outlined),
                _StatTile(
                    'Avg pace',
                    s.formatPace(a.distanceMeters, a.durationSec),
                    Icons.speed),
                _StatTile(
                    'Avg speed',
                    s.formatSpeed(a.distanceMeters, a.durationSec),
                    Icons.directions_walk),
                _StatTile('Elevation', '↑ ${s.formatElevation(a.elevGainMeters)}',
                    Icons.trending_up),
                _StatTile('Calories',
                    '${s.estimateCalories(a.distanceMeters)} kcal',
                    Icons.local_fire_department),
                _StatTile('Moving time', Settings.formatDuration(_movingSec()),
                    Icons.timelapse),
                _StatTile('Moving pace',
                    s.formatPace(a.distanceMeters, _movingSec()),
                    Icons.bolt),
              ],
            ),
          ),
          // Route map.
          if (_points.length >= 2)
            SizedBox(
              height: 280,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: BaseMap(
                    region: _region,
                    initialCamera: _initialCamera,
                    onMapCreated: (c) => _c = c,
                    onStyleLoaded: _onStyleLoaded,
                  ),
                ),
              ),
            ),
          if (a.trailId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TrailProgressScreen(
                        trailId: a.trailId!, trailName: a.trailName),
                  ),
                ),
                icon: const Icon(Icons.insights),
                label: const Text('Your progress on this trail'),
              ),
            ),
          // Elevation profile + pace graphs.
          _ProfileCharts(activity: a),
          // Splits.
          _SplitsSection(activity: a),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Seconds actually moving (excludes long pauses / standing still).
  int _movingSec() {
    var moving = 0;
    for (var i = 1; i < a.track.length; i++) {
      final dt = a.track[i].tSec - a.track[i - 1].tSec;
      final d = metersBetween(a.track[i - 1].position, a.track[i].position);
      if (dt > 0 && dt < 120 && d >= 2) moving += dt;
    }
    return moving == 0 ? a.durationSec : moving;
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static String _dateLine(DateTime d) {
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    final min = d.minute.toString().padLeft(2, '0');
    return '${_months[d.month - 1]} ${d.day}, ${d.year}  ·  $h12:$min $ampm';
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF1B5E20), size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF4A4A4A))),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Elevation profile and pace-over-distance graphs, drawn from the track.
class _ProfileCharts extends StatelessWidget {
  const _ProfileCharts({required this.activity});
  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final track = activity.track;
    if (track.length < 3) return const SizedBox.shrink();
    final metric = Settings.instance.metric.value;
    final unitM = metric ? 1000.0 : 1609.344;

    // Cumulative distance (m) at each point.
    final cum = List<double>.filled(track.length, 0);
    for (var i = 1; i < track.length; i++) {
      cum[i] =
          cum[i - 1] + metersBetween(track[i - 1].position, track[i].position);
    }

    // Elevation profile (lightly smoothed), x in the chosen unit.
    final eleData = <Offset>[];
    double? sm;
    for (var i = 0; i < track.length; i++) {
      final e = track[i].ele;
      if (e == null) continue;
      sm = sm == null ? e : sm * 0.7 + e * 0.3;
      final y = metric ? sm : sm * 3.28084;
      eleData.add(Offset(cum[i] / unitM, y));
    }

    // Pace: resample every ~120 m into seconds-per-unit.
    final paceData = <Offset>[];
    const seg = 120.0;
    var accD = 0.0;
    var startT = track.first.tSec;
    var startCum = 0.0;
    for (var i = 1; i < track.length; i++) {
      accD += metersBetween(track[i - 1].position, track[i].position);
      if (accD >= seg) {
        final dt = track[i].tSec - startT;
        if (dt > 0) {
          final pace = dt / (accD / unitM); // sec per unit
          if (pace > 0 && pace < 3600) {
            paceData.add(Offset((startCum + accD / 2) / unitM, pace));
          }
        }
        startCum += accD;
        accD = 0;
        startT = track[i].tSec;
      }
    }

    String distX(double x) => '${x.toStringAsFixed(1)} ${metric ? 'km' : 'mi'}';
    String paceY(double sec) {
      final m = sec ~/ 60;
      final s = (sec % 60).round();
      return '$m:${s.toString().padLeft(2, '0')}';
    }

    final children = <Widget>[];
    if (eleData.length >= 2) {
      children.addAll([
        const _ChartTitle('Elevation'),
        AreaLineChart(
          data: eleData,
          fmtY: (y) => '${y.round()} ${metric ? 'm' : 'ft'}',
          fmtX: distX,
        ),
        const SizedBox(height: 16),
      ]);
    }
    if (paceData.length >= 2) {
      children.addAll([
        const _ChartTitle('Pace'),
        AreaLineChart(
          data: paceData,
          color: const Color(0xFF1565C0),
          fmtY: (y) => '${paceY(y)}/${metric ? 'km' : 'mi'}',
          fmtX: distX,
        ),
      ]);
    }
    if (children.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

class _ChartTitle extends StatelessWidget {
  const _ChartTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: Text(text,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      );
}

/// Per-km (or per-mile) splits computed from the timestamped track.
class _SplitsSection extends StatelessWidget {
  const _SplitsSection({required this.activity});
  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final metric = Settings.instance.metric.value;
    final unitMeters = metric ? 1000.0 : 1609.344;
    final splits = _computeSplits(unitMeters);
    if (splits.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Splits (per ${metric ? 'km' : 'mile'})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (var i = 0; i < splits.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                      width: 40,
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600))),
                  Expanded(
                    child: Text(
                      splits[i].partial
                          ? '${(splits[i].meters / unitMeters).toStringAsFixed(2)} ${metric ? 'km' : 'mi'} · ${Settings.formatDuration(splits[i].seconds)}'
                          : Settings.formatDuration(splits[i].seconds),
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<_Split> _computeSplits(double unitMeters) {
    final track = activity.track;
    if (track.length < 2) return [];
    final splits = <_Split>[];
    var cum = 0.0;
    var lastBoundaryDist = 0.0;
    var lastBoundaryTime = 0;
    for (var i = 1; i < track.length; i++) {
      cum += metersBetween(track[i - 1].position, track[i].position);
      while (cum - lastBoundaryDist >= unitMeters) {
        // Interpolate the time at the exact boundary crossing.
        final segDist =
            metersBetween(track[i - 1].position, track[i].position);
        final overshoot = cum - (lastBoundaryDist + unitMeters);
        final frac = segDist <= 0 ? 0.0 : 1 - (overshoot / segDist);
        final tAtBoundary = (track[i - 1].tSec +
                (track[i].tSec - track[i - 1].tSec) * frac)
            .round();
        splits.add(_Split(unitMeters, tAtBoundary - lastBoundaryTime, false));
        lastBoundaryDist += unitMeters;
        lastBoundaryTime = tAtBoundary;
      }
    }
    // Trailing partial unit.
    final rem = cum - lastBoundaryDist;
    if (rem > unitMeters * 0.15) {
      splits.add(_Split(rem, activity.durationSec - lastBoundaryTime, true));
    }
    return splits;
  }
}

class _Split {
  _Split(this.meters, this.seconds, this.partial);
  final double meters;
  final int seconds;
  final bool partial;
}
