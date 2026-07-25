import 'package:flutter/material.dart';

import '../models/activity.dart';
import '../services/settings.dart';
import '../services/trail_store.dart';
import 'activity_detail_screen.dart';
import 'stats_screen.dart';

/// Log of every recorded walk, with lifetime and recent totals and a body-weight
/// setting for the calorie estimate. Tap a walk for its full detail + route.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<Activity>> _activities;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _activities = TrailStore.instance.activities();

  Future<void> _open(Activity a) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ActivityDetailScreen(activity: a)),
    );
    if (changed == true && mounted) setState(_reload);
  }

  Future<void> _editWeight() async {
    final metric = Settings.instance.metric.value;
    final current = metric
        ? Settings.instance.weightKg.value
        : Settings.instance.weightKg.value * 2.20462;
    final controller =
        TextEditingController(text: current.round().toString());
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Body weight (${metric ? 'kg' : 'lb'})'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            suffixText: metric ? 'kg' : 'lb',
            border: const OutlineInputBorder(),
            helperText: 'Used only to estimate calories',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(controller.text.trim());
              if (v != null && v > 0) {
                Navigator.pop(ctx, metric ? v : v / 2.20462);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      await Settings.instance.setWeightKg(result);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Trends & records',
            icon: const Icon(Icons.insights),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StatsScreen()),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<Activity>>(
        future: _activities,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final acts = snap.data!;
          return ListView(
            padding: EdgeInsets.only(
                bottom: MediaQuery.viewPaddingOf(context).bottom),
            children: [
              _TotalsHeader(activities: acts, onEditWeight: _editWeight),
              if (acts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No walks yet.\n\nPick a trail and tap it to start walking — '
                    'your walks will show up here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18),
                  ),
                )
              else
                for (final a in acts) ...[
                  _ActivityTile(activity: a, onTap: () => _open(a)),
                  const Divider(height: 1),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _TotalsHeader extends StatelessWidget {
  const _TotalsHeader({required this.activities, required this.onEditWeight});
  final List<Activity> activities;
  final VoidCallback onEditWeight;

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    var allDist = 0.0, allElev = 0.0;
    var weekDist = 0.0;
    var weekCount = 0;
    for (final a in activities) {
      allDist += a.distanceMeters;
      allElev += a.elevGainMeters;
      if (a.startedAt.isAfter(weekAgo)) {
        weekDist += a.distanceMeters;
        weekCount++;
      }
    }
    return Container(
      color: const Color(0xFFE8F5E9),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('All time',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1B5E20))),
          const SizedBox(height: 2),
          Text(
            '${activities.length} ${activities.length == 1 ? 'walk' : 'walks'}  ·  '
            '${s.formatDistance(allDist)}  ·  ↑ ${s.formatElevation(allElev)}',
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B5E20)),
          ),
          const SizedBox(height: 10),
          Text(
            'Last 7 days:  $weekCount ${weekCount == 1 ? 'walk' : 'walks'}  ·  '
            '${s.formatDistance(weekDist)}',
            style:
                const TextStyle(fontSize: 16, color: Color(0xFF1B5E20)),
          ),
          const SizedBox(height: 10),
          InkWell(
            onTap: onEditWeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.monitor_weight_outlined,
                    size: 18, color: Color(0xFF4A4A4A)),
                const SizedBox(width: 6),
                Text(
                  'Calories use weight: '
                  '${s.metric.value ? '${s.weightKg.value.round()} kg' : '${(s.weightKg.value * 2.20462).round()} lb'}',
                  style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF4A4A4A),
                      decoration: TextDecoration.underline),
                ),
                const Icon(Icons.edit, size: 14, color: Color(0xFF4A4A4A)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.activity, required this.onTap});
  final Activity activity;
  final VoidCallback onTap;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    final d = activity.startedAt;
    final date = '${_months[d.month - 1]} ${d.day}';
    return ListTile(
      isThreeLine: true,
      leading: const Icon(Icons.directions_walk, size: 32),
      title: Text(activity.trailName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$date  ·  ${s.formatDistance(activity.distanceMeters)}'
        '  ·  ${Settings.formatDuration(activity.durationSec)}\n'
        '${s.formatPace(activity.distanceMeters, activity.durationSec)}'
        '  ·  ↑ ${s.formatElevation(activity.elevGainMeters)}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
