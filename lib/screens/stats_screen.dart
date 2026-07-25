import 'package:flutter/material.dart';

import '../models/activity.dart';
import '../services/settings.dart';
import '../services/trail_store.dart';
import '../widgets/mini_charts.dart';

/// Trends and personal records across all logged walks: totals by period, a
/// weekly distance graph, and personal bests. The "power user" analytics view.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

enum _Period { week, month, year, all }

class _StatsScreenState extends State<StatsScreen> {
  late Future<List<Activity>> _future;
  _Period _period = _Period.month;

  @override
  void initState() {
    super.initState();
    _future = TrailStore.instance.activities();
  }

  DateTime get _cutoff {
    final now = DateTime.now();
    switch (_period) {
      case _Period.week:
        return now.subtract(const Duration(days: 7));
      case _Period.month:
        return now.subtract(const Duration(days: 30));
      case _Period.year:
        return now.subtract(const Duration(days: 365));
      case _Period.all:
        return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Trends & records')),
      body: FutureBuilder<List<Activity>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data!;
          if (all.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No walks yet — your trends will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18)),
              ),
            );
          }
          final cutoff = _cutoff;
          final inPeriod =
              all.where((a) => a.startedAt.isAfter(cutoff)).toList();
          var dist = 0.0, elev = 0.0, secs = 0;
          for (final a in inPeriod) {
            dist += a.distanceMeters;
            elev += a.elevGainMeters;
            secs += a.durationSec;
          }

          return ListView(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
            children: [
              SegmentedButton<_Period>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Period.week, label: Text('Week')),
                  ButtonSegment(value: _Period.month, label: Text('Month')),
                  ButtonSegment(value: _Period.year, label: Text('Year')),
                  ButtonSegment(value: _Period.all, label: Text('All')),
                ],
                selected: {_period},
                onSelectionChanged: (v) => setState(() => _period = v.first),
              ),
              const SizedBox(height: 16),
              _bigStat('${inPeriod.length}',
                  inPeriod.length == 1 ? 'walk' : 'walks'),
              Row(
                children: [
                  Expanded(child: _bigStat(s.formatDistance(dist), 'distance')),
                  Expanded(
                      child: _bigStat(Settings.formatDuration(secs), 'time')),
                ],
              ),
              Row(
                children: [
                  Expanded(
                      child: _bigStat('↑ ${s.formatElevation(elev)}', 'climb')),
                  Expanded(
                      child: _bigStat(
                          inPeriod.isEmpty
                              ? '—'
                              : s.formatPace(dist, secs),
                          'avg pace')),
                ],
              ),
              const SizedBox(height: 24),
              _TrendsSection(activities: all),
              const SizedBox(height: 24),
              _LifetimeSection(activities: all),
              const SizedBox(height: 24),
              const Text('Personal records',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._records(all),
            ],
          );
        },
      ),
    );
  }

  Widget _bigStat(String value, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1B5E20))),
          Text(label,
              style: const TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
        ],
      ),
    );
  }

  List<Widget> _records(List<Activity> all) {
    final s = Settings.instance;
    Activity longest = all.first, longestTime = all.first, mostClimb = all.first;
    Activity? fastest;
    for (final a in all) {
      if (a.distanceMeters > longest.distanceMeters) longest = a;
      if (a.durationSec > longestTime.durationSec) longestTime = a;
      if (a.elevGainMeters > mostClimb.elevGainMeters) mostClimb = a;
      if (a.distanceMeters > 400 && a.durationSec > 0) {
        final pace = a.durationSec / a.distanceMeters;
        if (fastest == null ||
            pace < fastest.durationSec / fastest.distanceMeters) {
          fastest = a;
        }
      }
    }
    return [
      _record(Icons.straighten, 'Longest walk',
          s.formatDistance(longest.distanceMeters), longest),
      _record(Icons.timer_outlined, 'Longest time',
          Settings.formatDuration(longestTime.durationSec), longestTime),
      _record(Icons.trending_up, 'Most climb',
          '↑ ${s.formatElevation(mostClimb.elevGainMeters)}', mostClimb),
      if (fastest != null)
        _record(Icons.bolt, 'Fastest pace',
            s.formatPace(fastest.distanceMeters, fastest.durationSec), fastest),
    ];
  }

  Widget _record(IconData icon, String label, String value, Activity a) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: const Color(0xFF1B5E20), size: 28),
      title: Text(label, style: const TextStyle(fontSize: 16)),
      subtitle: Text('${a.trailName} · ${_shortDate(a.startedAt)}'),
      trailing: Text(value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static String _shortDate(DateTime d) =>
      '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Per-week distance bars, a pace trend line, and climb bars over 8 weeks.
class _TrendsSection extends StatelessWidget {
  const _TrendsSection({required this.activities});
  final List<Activity> activities;

  @override
  Widget build(BuildContext context) {
    final metric = Settings.instance.metric.value;
    final unit = metric ? 1000.0 : 1609.344;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thisMonday = today.subtract(Duration(days: today.weekday - 1));

    final dist = List<double>.filled(8, 0);
    final secs = List<int>.filled(8, 0);
    final elev = List<double>.filled(8, 0);
    final labels = <String>[];
    final weekStarts = <DateTime>[];
    for (var i = 0; i < 8; i++) {
      final ws = thisMonday.subtract(Duration(days: 7 * (7 - i)));
      weekStarts.add(ws);
      labels.add('${ws.month}/${ws.day}');
    }
    for (final a in activities) {
      for (var i = 0; i < 8; i++) {
        final start = weekStarts[i];
        if (!a.startedAt.isBefore(start) &&
            a.startedAt.isBefore(start.add(const Duration(days: 7)))) {
          dist[i] += a.distanceMeters;
          secs[i] += a.durationSec;
          elev[i] += a.elevGainMeters;
          break;
        }
      }
    }

    // Pace line: only weeks that have distance.
    final paceData = <Offset>[];
    for (var i = 0; i < 8; i++) {
      if (dist[i] > 0 && secs[i] > 0) {
        paceData.add(Offset(i.toDouble(), secs[i] / (dist[i] / unit)));
      }
    }
    String paceY(double sec) =>
        '${sec ~/ 60}:${(sec % 60).round().toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _H('Distance — last 8 weeks'),
        BarChartMini(
            values: [for (final d in dist) d / unit], labels: labels),
        if (paceData.length >= 2) ...[
          const SizedBox(height: 20),
          const _H('Pace trend'),
          AreaLineChart(
            data: paceData,
            color: const Color(0xFF1565C0),
            fmtY: (y) => '${paceY(y)}/${metric ? 'km' : 'mi'}',
            fmtX: (x) => labels[x.round().clamp(0, 7)],
          ),
        ],
        const SizedBox(height: 20),
        const _H('Climb — last 8 weeks'),
        BarChartMini(
          values: [for (final e in elev) metric ? e : e * 3.28084],
          labels: labels,
          color: const Color(0xFF6A1B9A),
        ),
      ],
    );
  }
}

/// Lifetime totals and averages across every walk.
class _LifetimeSection extends StatelessWidget {
  const _LifetimeSection({required this.activities});
  final List<Activity> activities;

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    final n = activities.length;
    var dist = 0.0, elev = 0.0, secs = 0;
    for (final a in activities) {
      dist += a.distanceMeters;
      elev += a.elevGainMeters;
      secs += a.durationSec;
    }
    final avgDist = n == 0 ? 0.0 : dist / n;
    final avgElev = n == 0 ? 0.0 : elev / n;
    final avgSecs = n == 0 ? 0 : secs ~/ n;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 15))),
              Text(value,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _H('Lifetime'),
        const SizedBox(height: 4),
        row('Total time', Settings.formatDuration(secs)),
        row('Total climb', '↑ ${s.formatElevation(elev)}'),
        const Divider(),
        row('Avg distance / walk', s.formatDistance(avgDist)),
        row('Avg pace', s.formatPace(dist, secs)),
        row('Avg time / walk', Settings.formatDuration(avgSecs)),
        row('Avg climb / walk', '↑ ${s.formatElevation(avgElev)}'),
      ],
    );
  }
}

class _H extends StatelessWidget {
  const _H(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold));
}
