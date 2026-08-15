import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../cue_style.dart';
import '../models/activity.dart';
import '../models/region.dart';
import '../models/trail.dart';
import '../services/backup.dart';
import '../services/geo.dart';
import '../services/import_fit.dart';
import '../services/native_bridge.dart';
import '../services/region_downloader.dart';
import '../services/settings.dart';
import '../services/trail_share.dart';
import '../services/trail_store.dart';
import '../services/updater.dart';
import 'author_screen.dart';
import 'browse_map_screen.dart';
import 'download_region_screen.dart';
import 'region_picker_screen.dart';
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
    // Resume check first (safety-adjacent — an interrupted walk) so it isn't
    // racing a second dialog if a shared file is also pending.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkResume();
      if (mounted) await _checkResumeRecording();
      if (mounted) await _checkImport();
    });
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

  void _toast(String msg, {Duration duration = const Duration(seconds: 4)}) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg), duration: duration));
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
            SizedBox(height: MediaQuery.viewPaddingOf(ctx).bottom),
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

  /// Shown once ever, the first time a walk (or recording) actually starts —
  /// not buried in a settings menu the walker has no reason to visit. Some
  /// OEM battery managers (and plain Android Doze) can freeze or kill the
  /// app mid-walk despite the foreground service, which to a non-technical
  /// walker looks exactly like "the app crashed."
  Future<void> _maybeWarnBattery() async {
    if (Settings.instance.batteryWarningShown.value) return;
    await Settings.instance.setBatteryWarningShown(true);
    final ok = await NativeBridge.isIgnoringBatteryOptimizations();
    if (ok || !mounted) return;
    final fix = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keep tracking reliable'),
        content: const Text(
            "Some phones can stop APS Trails in the background during a "
            "long walk unless it's excluded from battery optimization. You "
            'can turn that on now, or later from Safety & battery settings.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Fix now')),
        ],
      ),
    );
    if (fix == true) await NativeBridge.requestIgnoreBatteryOptimizations();
  }

  Future<void> _recordTrail({RecordingCheckpoint? resume}) async {
    await _maybeWarnBattery();
    if (!mounted) return;
    final region = resume != null ? regionById(resume.regionId) : _activeRegion;
    final draft = await Navigator.push<Trail>(
      context,
      MaterialPageRoute(
          builder: (_) => RecordTrailScreen(region: region, resume: resume)),
    );
    if (draft == null || !mounted) return;
    await _finishRecordedTrail(draft);
  }

  /// Shared by a fresh recording and one resumed from a crash checkpoint:
  /// hands the just-recorded draft to the author screen for review/save,
  /// then logs it as an Activity against the trail's now-real id.
  Future<void> _finishRecordedTrail(Trail draft) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AuthorScreen(trail: draft)),
    );
    // AuthorScreen saves in place (draft.id is set by TrailStore.save), so
    // the walk recorded to create this trail can now be logged against a
    // real trail id — same 20 m floor GuideScreen uses to skip an
    // accidental open/barely-moved session rather than cluttering history.
    final track = draft.recordedTrack;
    if (saved == true && draft.id != null && track != null && draft.walkedMeters >= 20) {
      await TrailStore.instance.addActivity(Activity(
        trailId: draft.id,
        trailName: draft.name,
        startedAt: draft.recordedStartedAt ?? DateTime.now(),
        durationSec: draft.recordedDurationSec ?? 0,
        distanceMeters: draft.walkedMeters,
        elevGainMeters: draft.elevGainMeters,
        track: track,
      ));
      await Settings.instance.addWalk(draft.walkedMeters, draft.elevGainMeters);
    }
    if (saved == true && mounted) setState(_reload);
  }

  Future<void> _edit(Trail trail) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AuthorScreen(trail: trail)),
    );
    if (saved == true) setState(_reload);
  }

  Future<void> _walk(Trail trail) async {
    await _maybeWarnBattery();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GuideScreen(trail: trail)),
    );
    // Refresh so the walk we just finished shows in the trail's totals.
    if (mounted) setState(_reload);
  }

  /// Checks for a walk checkpoint left behind by an interruption (the app
  /// killed by Android, not a deliberate Stop — see GuideScreen/WalkCheckpoint)
  /// and offers to resume it.
  Future<void> _checkResume() async {
    final cp = await TrailStore.instance.loadWalkCheckpoint();
    if (cp == null || !mounted) return;
    final trails = await TrailStore.instance.all();
    Trail? trail;
    for (final t in trails) {
      if (t.id == cp.trailId) {
        trail = t;
        break;
      }
    }
    final found = trail;
    if (found == null) {
      // The trail was deleted since — nothing sensible left to resume into.
      await TrailStore.instance.clearWalkCheckpoint(cp.trailId);
      return;
    }
    if (!mounted) return;
    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Resume unfinished walk?'),
        content: Text(
            'It looks like "${found.name}" didn\'t get a chance to finish '
            'properly last time. Pick up where you left off?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Discard')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Resume')),
        ],
      ),
    );
    if (!mounted) return;
    if (resume == true) {
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => GuideScreen(trail: found, resume: cp)),
      );
      if (mounted) setState(_reload);
    } else {
      await TrailStore.instance.clearWalkCheckpoint(cp.trailId);
    }
  }

  /// Same idea as [_checkResume], but for an in-progress *recording*
  /// (RecordTrailScreen) interrupted before a deliberate Stop — see
  /// [RecordingCheckpoint]. Unlike a walk checkpoint, there's no trail to
  /// look up (the trail doesn't exist yet), so the dialog just names the
  /// region it was recorded in.
  Future<void> _checkResumeRecording() async {
    final cp = await TrailStore.instance.loadRecordingCheckpoint();
    if (cp == null || !mounted) return;
    final region = regionById(cp.regionId);
    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Resume unfinished recording?'),
        content: Text(
            'It looks like a trail recording in ${region.name} didn\'t get '
            'a chance to finish properly last time. Pick up where you left '
            'off?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Discard')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Resume')),
        ],
      ),
    );
    if (!mounted) return;
    if (resume == true) {
      await _recordTrail(resume: cp);
    } else {
      await TrailStore.instance.clearRecordingCheckpoint();
    }
  }

  /// Flips a trail's walking direction in place: reverses the path/anchors,
  /// flips each cue's stack order (so firing sequence reverses too,
  /// including stacked cues at the same spot), and swaps left⇄right and
  /// start⇄finish cue types so turn-by-turn directions stay correct walking
  /// it the other way. Positions are left untouched — a start/finish cue
  /// already sits at the path's old endpoint, so swapping its type alone
  /// correctly relabels it for the new (swapped) endpoint.
  Future<void> _reverseDirection(Trail t) async {
    if (t.path.length < 2) {
      _toast('Nothing to reverse yet — draw or generate a path first');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reverse "${t.name}"?'),
        content: const Text(
            'Flips the walking direction — turn-by-turn directions and the '
            'start/finish will swap to match.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reverse')),
        ],
      ),
    );
    if (ok != true) return;

    t.path = t.path.reversed.toList();
    if (t.anchors.isNotEmpty) t.anchors = t.anchors.reversed.toList();

    if (t.cues.isNotEmpty) {
      final maxOrder =
          t.cues.map((c) => c.order).reduce((a, b) => a > b ? a : b);
      for (final cue in t.cues) {
        cue.order = maxOrder - cue.order;
        reverseCueInPlace(cue);
      }
    }

    await TrailStore.instance.save(t);
    // A checkpoint from an earlier walk stores nextIndex — a position in the
    // cue list that just got reversed, so resuming against it would silently
    // skip the wrong cues (and skip them from the wrong end of the trail).
    // The saved progress can't be meaningfully translated to the opposite
    // direction, so drop it rather than resume into a broken state.
    if (t.id != null) await TrailStore.instance.clearWalkCheckpoint(t.id!);
    if (!mounted) return;
    setState(_reload);
    _toast('Reversed "${t.name}"');
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
  Future<void> _pickRegion() async {
    final r = await Navigator.push<Region>(
      context,
      MaterialPageRoute(
          builder: (_) => RegionPickerScreen(current: _activeRegion)),
    );
    if (r != null && mounted) setState(() => _activeRegion = r);
  }

  void _openMapAreas() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            // Explicit nav-bar inset in addition to the SafeArea above — see
            // the same reasoning in cue_editor_sheet.dart.
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.viewPaddingOf(ctx).bottom),
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
                const Divider(height: 28),
                const Text('Built-in map',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public),
                  title: const Text('Default map (SW BC)'),
                  subtitle: const Text(
                      'Built into the app — update to re-fetch it fresh'),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Update the default map',
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _updateBundledMap();
                    },
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Update (re-download this area)',
                            onPressed: () async {
                              Navigator.pop(ctx);
                              await _updateArea(r);
                            },
                          ),
                          IconButton(
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
                        ],
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

  /// Re-fetches the whole bundled default basemap live from Protomaps,
  /// through the same RegionDownloader/PmTilesWriter pipeline as a
  /// downloaded region — the only way to get fresher/gap-free data onto a
  /// phone that already has the app installed, since the bundled
  /// `southwest_bc.pmtiles` itself only ever changes via a full app update.
  /// Bounds are the union of every bundled bookmark in [kRegions], since
  /// the basemap covers all of them, not just one.
  Future<void> _updateBundledMap() async {
    var west = kRegions.first.west, south = kRegions.first.south;
    var east = kRegions.first.east, north = kRegions.first.north;
    for (final r in kRegions.skip(1)) {
      if (r.west < west) west = r.west;
      if (r.south < south) south = r.south;
      if (r.east > east) east = r.east;
      if (r.north > north) north = r.north;
    }

    if (!await Updater.instance.isOnWifi()) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not on WiFi'),
          content: const Text(
              'Updating the default map re-fetches a large area (likely '
              '200+ MB) and can use significant mobile data. Continue '
              'anyway, or wait until you\'re on WiFi?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Wait for WiFi')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    if (!mounted) return;

    final downloader = RegionDownloader();
    _showBlockingDialog('Estimating size…');
    final estBytes = await downloader.estimateBytes(west, south, east, north);
    final tiles = RegionDownloader.tilesFor(west, south, east, north).length;
    if (mounted) Navigator.pop(context); // close "estimating"
    if (!mounted) return;

    final mb = (estBytes / 1e6).toStringAsFixed(0);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update the default map?'),
        content: Text(
            'Re-fetches the whole built-in coverage area fresh (~$mb MB, '
            '$tiles tiles) and replaces what shipped with the app. This can '
            'take a long time — keep the app open until it finishes. '
            'Trails you\'ve made keep working either way.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Update')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await WakelockPlus.enable();
    final progress = ValueNotifier<DownloadProgress>(DownloadProgress(0, tiles, 0));
    final future = downloader.download(
      id: kMapAsset,
      name: 'Default map',
      west: west, south: south, east: east, north: north,
      onProgress: (p) => progress.value = p,
    );
    _showUpdateProgress(progress, downloader, title: 'Updating default map');
    final updated = await future;
    await WakelockPlus.disable();
    if (mounted) Navigator.pop(context); // close progress
    if (updated == null) {
      _toast('Update cancelled — kept the map that shipped with the app');
      return;
    }
    await Settings.instance.setBundledMapUpdated(true);
    final missing = downloader.failedTileCount;
    _toast(missing > 0
        ? 'Default map updated — $missing tile${missing == 1 ? '' : 's'} '
            'still failed to download'
        : 'Default map updated');
  }

  /// Re-downloads [r]'s exact area under its existing id — refreshes stale
  /// or gap-filled tiles (see RegionDownloader's retry logic) without the
  /// delete-then-download-new dance, which used to hand out a brand-new id
  /// and silently orphan any trail's reference to the old one.
  Future<void> _updateArea(Region r) async {
    final downloader = RegionDownloader();
    _showBlockingDialog('Estimating size…');
    final estBytes =
        await downloader.estimateBytes(r.west, r.south, r.east, r.north);
    final tiles =
        RegionDownloader.tilesFor(r.west, r.south, r.east, r.north).length;
    if (mounted) Navigator.pop(context); // close "estimating"
    if (!mounted) return;

    if (!await _confirmUpdateRegion(r, estBytes)) return;
    if (!mounted) return;

    final progress = ValueNotifier<DownloadProgress>(DownloadProgress(0, tiles, 0));
    final future = downloader.download(
      id: r.id,
      name: r.name,
      west: r.west, south: r.south, east: r.east, north: r.north,
      onProgress: (p) => progress.value = p,
    );
    _showUpdateProgress(progress, downloader);
    final updated = await future;
    if (mounted) Navigator.pop(context); // close progress
    if (updated == null) {
      _toast('Update cancelled — kept the existing map for "${r.name}"');
      return;
    }
    await addUserRegion(updated);
    if (_activeRegion.id == updated.id) _activeRegion = updated;
    final missing = downloader.failedTileCount;
    _toast(missing > 0
        ? 'Updated "${r.name}" — $missing tile${missing == 1 ? '' : 's'} '
            'still failed to download'
        : 'Updated "${r.name}"');
    // download() also (soft-)fetches street/route-graph data for the area —
    // download_region_screen.dart's brand-new-download flow already toasts
    // these; the update flow didn't, so a failure here went completely
    // unnoticed (the bug that motivated this). Longer duration: up to two
    // of these can queue back-to-back after the one above, and the default
    // 4s was reported as too short to actually read one (see
    // download_region_screen.dart's matching fix for the same complaint).
    const warningDuration = Duration(seconds: 7);
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
    if (mounted) setState(() {});
  }

  Future<bool> _confirmUpdateRegion(Region r, int estBytes) async {
    final mb = (estBytes / 1e6).toStringAsFixed(estBytes < 1e7 ? 1 : 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update "${r.name}"?'),
        content: Text(
            'Re-downloads this exact area fresh (~$mb MB) and replaces what\'s '
            'saved now — useful if it looked wrong or incomplete last time. '
            'Trails you made here keep working either way.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Update')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _showUpdateProgress(
      ValueNotifier<DownloadProgress> progress, RegionDownloader downloader,
      {String title = 'Updating area'}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder<DownloadProgress>(
          valueListenable: progress,
          builder: (context, p, _) {
            final pct = p.total == 0 ? 0.0 : p.done / p.total;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // See download_region_screen.dart's matching dialog for why
                // this shows "Step X of Y" rather than just the phase name.
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

  void _showBlockingDialog(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Text(msg),
          ],
        ),
      ),
    );
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
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _pickRegion,
          child: Row(
            children: [
              const Icon(Icons.place, size: 20),
              const SizedBox(width: 6),
              Flexible(
                child: Text(_activeRegion.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w600)),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Browse map',
            icon: const Icon(Icons.explore),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => BrowseMapScreen(region: _activeRegion)),
            ),
          ),
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
            // Bottom padding equal to the "New trail" FAB's footprint so the
            // last row can scroll fully clear of it — without this, the
            // FAB permanently covers that row's trailing 3-dot menu once
            // you've scrolled to the end of the list, with no way to tap it.
            padding: EdgeInsets.only(
                bottom: 88 + MediaQuery.viewPaddingOf(context).bottom),
            itemCount: trails.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final t = trails[i];
              return ListTile(
                isThreeLine: t.walkCount > 0,
                leading: const Icon(Icons.route, size: 34),
                title: Text(t.name),
                subtitle: Text(
                    '${regionForTrail(t).name}  •  '
                    '${Settings.instance.formatDistance(pathLength(t.path))}'
                    ' • ${t.cues.length} ${t.cues.length == 1 ? "cue" : "cues"}'
                    '${t.walkCount > 0 ? '\n${Settings.instance.formatDistance(t.walkedMeters)} • ↑ ${Settings.instance.formatElevation(t.elevGainMeters)} • ${t.walkCount}×' : ''}'),
                trailing: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 28),
                  onSelected: (v) {
                    if (v == 'edit') _edit(t);
                    if (v == 'progress') _progress(t);
                    if (v == 'reverse') _reverseDirection(t);
                    if (v == 'share') TrailShare.shareTrail(t);
                    if (v == 'delete') _delete(t);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (t.walkCount > 0)
                      const PopupMenuItem(
                          value: 'progress', child: Text('Progress')),
                    const PopupMenuItem(
                        value: 'reverse', child: Text('Reverse direction')),
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
