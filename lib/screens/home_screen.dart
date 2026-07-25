import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/activity.dart';
import '../models/region.dart';
import '../models/trail.dart';
import '../services/backup.dart';
import '../services/geo.dart';
import '../services/import_fit.dart';
import '../services/settings.dart';
import '../services/trail_share.dart';
import '../services/trail_store.dart';
import '../services/updater.dart';
import 'author_screen.dart';
import 'download_region_screen.dart';
import 'guide_screen.dart';
import 'history_screen.dart';
import 'record_trail_screen.dart';
import 'settings_screen.dart';
import 'trail_progress_screen.dart';
import 'update_screen.dart';

/// Landing screen: lists saved trails and lets the user create a new one.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _importChannel = MethodChannel('trailguide/import');

  late Future<List<Trail>> _trails;
  Region _activeRegion = kDefaultRegion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkImport());
    // Quiet on-launch check; downloads automatically if a newer build exists
    // AND we're on WiFi (see Updater.check). Never installs without a tap.
    Updater.instance.check(autoDownloadOnWifi: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkImport();
  }

  void _reload() {
    _trails = TrailStore.instance.all();
  }

  /// Handles a file opened via "open with" / share: a TrailGuide route, a
  /// Runkeeper history CSV, or a GPX track.
  Future<void> _checkImport() async {
    try {
      final data = await _importChannel.invokeMethod<String>('getPendingImport');
      if (data == null) return;

      final trail = TrailShare.tryParse(data);
      if (trail != null) {
        await TrailStore.instance.save(trail);
        if (!mounted) return;
        setState(_reload);
        _toast('Imported "${trail.name}"');
        return;
      }

      // A full backup file → restore (merge).
      if (BackupService.looksLikeBackup(data)) {
        await _restoreBackup(data);
        return;
      }

      // Fitness history: a Runkeeper cardioActivities.csv or a GPX track.
      List<Activity> acts;
      if (FitImport.looksLikeCsv(data)) {
        acts = FitImport.parseCsv(data);
      } else if (FitImport.looksLikeGpx(data)) {
        final a = FitImport.parseGpx(data);
        acts = a == null ? [] : [a];
      } else {
        _toast("That file isn't a TrailGuide route or a fitness export");
        return;
      }
      final added = await _mergeActivities(acts);
      if (!mounted) return;
      setState(_reload);
      _toast(added == 0
          ? 'Nothing new to import'
          : 'Imported $added ${added == 1 ? "walk" : "walks"} from your history');
    } catch (_) {}
  }

  /// Inserts imported activities not already present (matched by start time to
  /// the minute) and rolls their distance/elevation into the lifetime totals so
  /// they merge with walks recorded in the app.
  Future<int> _mergeActivities(List<Activity> acts) async {
    if (acts.isEmpty) return 0;
    final existing = await TrailStore.instance.activities();
    final seen = {
      for (final a in existing) a.startedAt.millisecondsSinceEpoch ~/ 60000
    };
    var added = 0;
    for (final a in acts) {
      final key = a.startedAt.millisecondsSinceEpoch ~/ 60000;
      if (seen.contains(key)) continue;
      seen.add(key);
      await TrailStore.instance.addActivity(a);
      await Settings.instance.addWalk(a.distanceMeters, a.elevGainMeters);
      added++;
    }
    return added;
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _newTrail() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_location_alt),
              title: const Text('Draw on map'),
              subtitle: const Text('Tap out the path and cues by hand'),
              onTap: () => Navigator.pop(ctx, 'draw'),
            ),
            ListTile(
              leading: const Icon(Icons.fiber_manual_record, color: Colors.red),
              title: const Text('Record by walking'),
              subtitle: const Text(
                  'Walk the trail now — GPS traces the path and drops cues'),
              onTap: () => Navigator.pop(ctx, 'record'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'record') {
      await _recordTrail();
    } else if (choice == 'draw') {
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => AuthorScreen(region: _activeRegion)),
      );
      if (saved == true) setState(_reload);
    }
  }

  Future<void> _recordTrail() async {
    final draft = await Navigator.push<Trail>(
      context,
      MaterialPageRoute(
          builder: (_) => RecordTrailScreen(region: _activeRegion)),
    );
    if (draft == null || !mounted) return;
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AuthorScreen(trail: draft)),
    );
    if (saved == true) setState(_reload);
  }

  Future<void> _edit(Trail trail) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AuthorScreen(trail: trail)),
    );
    if (saved == true) setState(_reload);
  }

  Future<void> _walk(Trail trail) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GuideScreen(trail: trail)),
    );
    // Refresh so the walk we just finished shows in the trail's totals.
    if (mounted) setState(_reload);
  }

  Future<void> _restoreBackup(String data) async {
    final date = BackupService.backupDate(data);
    final when = date == null
        ? ''
        : ' from ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
            'This will merge the backup$when into this phone — trails and walk '
            'history are added, nothing is deleted. Duplicates are skipped.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    final res = await BackupService.restore(data);
    if (!mounted) return;
    setState(_reload);
    final areas = res.regions > 0 ? ', ${res.regions} areas' : '';
    _toast('Restored ${res.trails} trails, ${res.activities} walks$areas'
        '${res.regions > 0 ? " — re-download those map areas" : ""}');
  }

  Future<void> _backupData() async {
    try {
      await BackupService.share();
    } catch (_) {
      _toast('Could not create the backup file');
    }
  }

  void _showRestoreHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from a backup'),
        content: const Text(
            'Open your backup file (the .tgbackup file you saved) from your '
            'Files app, Google Drive, or an email, and choose APS Trails. '
            'It will merge everything back in.'),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Bottom sheet to download a new offline area or remove a downloaded one.
  void _openMapAreas() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Map areas',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 6),
                const Text(
                    'Add a new area for anywhere in the world. It uses internet '
                    'once to download, then works fully offline like the rest.',
                    style: TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _downloadNewArea();
                    },
                    icon: const Icon(Icons.add_location_alt),
                    label: const Text('Download new area'),
                  ),
                ),
                if (userRegions.isNotEmpty) ...[
                  const Divider(height: 28),
                  const Text('Downloaded areas',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  for (final r in List<Region>.from(userRegions))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.map_outlined),
                      title: Text(r.name),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (!await _confirmDeleteRegion(r)) return;
                          await removeUserRegion(r.id);
                          if (_activeRegion.id == r.id) {
                            _activeRegion = kDefaultRegion;
                          }
                          setSheet(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _downloadNewArea() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const DownloadRegionScreen()),
    );
    if (id != null && mounted) {
      setState(() => _activeRegion = regionById(id));
      _toast('Added "${regionById(id).name}"');
    }
  }

  Future<bool> _confirmDeleteRegion(Region r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${r.name}"?'),
        content: const Text(
            'Removes this downloaded map area from the phone. Trails you made '
            'in it stay saved.'),
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
    return ok ?? false;
  }

  void _progress(Trail t) {
    if (t.id == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TrailProgressScreen(trailId: t.id!, trailName: t.name),
      ),
    );
  }

  Future<void> _delete(Trail t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${t.name}"?'),
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
    if (ok == true && t.id != null) {
      await TrailStore.instance.delete(t.id!);
      setState(_reload);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        leadingWidth: 40,
        leading: const Icon(Icons.hiking, size: 26),
        // The area picker is the primary control, so it gets the title slot.
        title: DropdownButtonHideUnderline(
          child: DropdownButton<Region>(
            isExpanded: true,
            value: _activeRegion,
            icon: const Icon(Icons.arrow_drop_down),
            borderRadius: BorderRadius.circular(12),
            onChanged: (r) {
              if (r != null) setState(() => _activeRegion = r);
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
        actions: [
          IconButton(
            tooltip: 'Map areas',
            icon: const Icon(Icons.download_for_offline),
            onPressed: _openMapAreas,
          ),
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.bar_chart),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
              if (mounted) setState(_reload);
            },
          ),
          // Distance units toggle (km ⇄ mi), remembered across launches.
          ValueListenableBuilder<bool>(
            valueListenable: Settings.instance.metric,
            builder: (context, metric, _) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: OutlinedButton(
                onPressed: () => Settings.instance.setMetric(!metric),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: Text(
                  metric ? 'km' : 'mi',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'backup') _backupData();
              if (v == 'restore') _showRestoreHelp();
              if (v == 'safety') {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()));
              }
              if (v == 'update') {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const UpdateScreen()));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'safety', child: Text('Safety & battery settings')),
              PopupMenuItem(value: 'backup', child: Text('Back up my data')),
              PopupMenuItem(
                  value: 'restore', child: Text('Restore from a backup')),
              PopupMenuItem(value: 'update', child: Text('Check for updates')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _UpdateBanner(),
          _AllTimeBanner(),
          Expanded(child: _trailList()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newTrail,
        icon: const Icon(Icons.add),
        label: const Text('New trail'),
      ),
    );
  }

  Widget _trailList() {
    return FutureBuilder<List<Trail>>(
        future: _trails,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final trails = snap.data!;
          if (trails.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No trails yet.\n\nPick an area (${_activeRegion.name}) up top,\n'
                  'then tap "New trail" to map one.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: trails.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final t = trails[i];
              return ListTile(
                isThreeLine: t.walkCount > 0,
                leading: const Icon(Icons.route, size: 34),
                title: Text(t.name),
                subtitle: Text(
                    '${regionById(t.regionId).name}  •  '
                    '${Settings.instance.formatDistance(pathLength(t.path))}'
                    ' • ${t.cues.length} ${t.cues.length == 1 ? "cue" : "cues"}'
                    '${t.walkCount > 0 ? '\n${Settings.instance.formatDistance(t.walkedMeters)} • ↑ ${Settings.instance.formatElevation(t.elevGainMeters)} • ${t.walkCount}×' : ''}'),
                trailing: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 28),
                  onSelected: (v) {
                    if (v == 'edit') _edit(t);
                    if (v == 'progress') _progress(t);
                    if (v == 'share') TrailShare.shareTrail(t);
                    if (v == 'delete') _delete(t);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (t.walkCount > 0)
                      const PopupMenuItem(
                          value: 'progress', child: Text('Progress')),
                    const PopupMenuItem(
                        value: 'share', child: Text('Share / send')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () => _walk(t),
              );
            },
          );
        },
      );
  }
}

/// A slim banner showing the lifetime distance walked across all trails.
/// Rebuilds when the total changes or the unit system is toggled.
/// Tappable strip that appears once Updater finds (and maybe already started
/// downloading) a newer build — silent otherwise (idle/checking/upToDate).
class _UpdateBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: Updater.instance.status,
      builder: (context, status, _) {
        final v = status.info == null
            ? ''
            : '${status.info!.versionName}+${status.info!.buildNumber}';
        final String? text;
        switch (status.phase) {
          case UpdatePhase.available:
            text = 'Update available: $v — tap to download';
          case UpdatePhase.downloading:
            final pct = status.total > 0
                ? ' (${(100 * status.received / status.total).round()}%)'
                : '';
            text = 'Downloading update$pct…';
          case UpdatePhase.downloaded:
            text = 'Update $v ready — tap to install';
          default:
            text = null;
        }
        if (text == null) return const SizedBox.shrink();
        return InkWell(
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const UpdateScreen())),
          child: Container(
            width: double.infinity,
            color: const Color(0xFFFFF3E0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.system_update_alt, color: Color(0xFFE65100), size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFE65100))),
                ),
                const Icon(Icons.chevron_right, color: Color(0xFFE65100)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AllTimeBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: Settings.instance.allTimeMeters,
      builder: (context, meters, _) {
        if (meters < 20) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: Settings.instance.metric,
          builder: (context, _, _) => Container(
            width: double.infinity,
            color: const Color(0xFFE8F5E9),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.directions_walk,
                    color: Color(0xFF1B5E20), size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Total walked: ${Settings.instance.formatDistance(meters)}'
                    '   •   ↑ ${Settings.instance.formatElevation(Settings.instance.allTimeElevMeters.value)} climbed',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B5E20)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
