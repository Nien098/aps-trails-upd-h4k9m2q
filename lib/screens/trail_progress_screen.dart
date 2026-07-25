import 'package:flutter/material.dart';

import '../models/activity.dart';
import '../services/settings.dart';
import '../services/trail_store.dart';
import '../widgets/mini_charts.dart';
import 'activity_detail_screen.dart';

/// "Historical route matching": every walk on one trail, side by side, so you
/// can see whether you're getting faster on that specific route.
class TrailProgressScreen extends StatefulWidget {
  const TrailProgressScreen({
    super.key,
    required this.trailId,
    required this.trailName,
  });

  final int trailId;
  final String trailName;

  @override
  State<TrailProgressScreen> createState() => _TrailProgressScreenState();
}

class _TrailProgressScreenState extends State<TrailProgressScreen> {
  late Future<List<Activity>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Activity>> _load() async {
    final all = await TrailStore.instance.activities();
    final mine = all.where((a) => a.trailId == widget.trailId).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt)); // oldest first
    return mine;
  }

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    return Scaffold(
      appBar: AppBar(title: Text('Progress · ${widget.trailName}')),
      body: FutureBuilder<List<Activity>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final acts = snap.data!;
          if (acts.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No walks on this trail yet.',
                    style: TextStyle(fontSize: 18)),
              ),
            );
          }

          // Best (lowest) pace and its walk.
          Activity best = acts.first;
          for (final a in acts) {
            if (a.distanceMeters > 100 &&
                a.durationSec > 0 &&
                a.durationSec / a.distanceMeters <
                    best.durationSec / best.distanceMeters) {
              best = a;
            }
          }
          final latest = acts.last;
          final first = acts.first;

          return ListView(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
            children: [
              Text('${acts.length} ${acts.length == 1 ? 'walk' : 'walks'}',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Best pace: ${s.formatPace(best.distanceMeters, best.durationSec)}'
                  '  ·  best time: ${Settings.formatDuration(best.durationSec)}',
                  style: const TextStyle(fontSize: 16, color: Color(0xFF1B5E20))),
              if (acts.length >= 2) ...[
                const SizedBox(height: 12),
                _trendNote(latest, first),
              ],
              const SizedBox(height: 20),
              const Text('Time per walk',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              BarChartMini(
                values: [for (final a in acts) a.durationSec / 60.0], // minutes
                labels: [for (final a in acts) _dm(a.startedAt)],
              ),
              const SizedBox(height: 8),
              const Text('Shorter bars = faster on this trail',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6A6A6A))),
              const SizedBox(height: 20),
              const Text('Every walk',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              for (final a in acts.reversed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: a == best
                      ? const Icon(Icons.emoji_events, color: Color(0xFFB8860B))
                      : const Icon(Icons.directions_walk),
                  title: Text(_dmy(a.startedAt)),
                  subtitle: Text(
                      '${s.formatDistance(a.distanceMeters)} · '
                      '${Settings.formatDuration(a.durationSec)} · '
                      '${s.formatPace(a.distanceMeters, a.durationSec)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ActivityDetailScreen(activity: a)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _trendNote(Activity latest, Activity first) {
    if (latest.distanceMeters < 100 || first.distanceMeters < 100) {
      return const SizedBox.shrink();
    }
    final latestPace = latest.durationSec / latest.distanceMeters;
    final firstPace = first.durationSec / first.distanceMeters;
    final diffPct = ((firstPace - latestPace) / firstPace) * 100;
    final faster = diffPct > 0;
    final txt = diffPct.abs() < 2
        ? 'About the same pace as your first walk here.'
        : faster
            ? '${diffPct.abs().round()}% faster than your first walk here 🎉'
            : '${diffPct.abs().round()}% slower than your first walk here';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: faster ? const Color(0xFFE8F5E9) : const Color(0xFFFDECEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(faster ? Icons.trending_up : Icons.trending_down,
              color: faster ? const Color(0xFF1B5E20) : const Color(0xFFB71C1C)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(txt,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static String _dm(DateTime d) => '${d.month}/${d.day}';
  static String _dmy(DateTime d) =>
      '${_months[d.month - 1]} ${d.day}, ${d.year}';
}
