import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/activity.dart';
import '../models/region.dart';
import '../models/trail.dart';
import 'settings.dart';
import 'trail_store.dart';

/// Result of a restore: how many of each item were newly added.
class RestoreResult {
  RestoreResult(this.trails, this.activities, this.regions);
  final int trails;
  final int activities;
  final int regions;
}

/// One-file backup and restore of everything a user can't otherwise recover:
/// trails, walk history, settings, and downloaded-region metadata. Downloaded
/// *map tiles* aren't included (too large / re-downloadable) — just the region
/// entries, so they can be re-downloaded.
class BackupService {
  static const _marker = 'trailguide-backup';

  /// Writes a backup file to temp storage and returns its path.
  static Future<String> writeBackupFile() async {
    final trails = await TrailStore.instance.all();
    final activities = await TrailStore.instance.activities();
    final map = {
      'app': _marker,
      'version': 1,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'settings': {
        'metric': Settings.instance.metric.value,
        'weightKg': Settings.instance.weightKg.value,
      },
      'regions': [for (final r in userRegions) r.toJson()],
      'trails': [for (final t in trails) t.toBackupJson()],
      'activities': [for (final a in activities) a.toRow()],
    };
    final dir = await getTemporaryDirectory();
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final file = File(
        '${dir.path}/aps-trails-backup-${d.year}${two(d.month)}${two(d.day)}.tgbackup');
    await file.writeAsString(jsonEncode(map));
    return file.path;
  }

  /// Creates a backup file and opens the OS share sheet to save/send it.
  static Future<void> share() async {
    final path = await writeBackupFile();
    await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: 'application/json')],
      subject: 'APS Trails backup',
      text: 'APS Trails backup. Open this file with APS Trails to restore.',
    ));
  }

  static bool looksLikeBackup(String text) {
    try {
      final m = jsonDecode(text);
      return m is Map && m['app'] == _marker;
    } catch (_) {
      return false;
    }
  }

  static DateTime? backupDate(String text) {
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      final ms = (m['exportedAt'] as num?)?.toInt();
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// Merges a backup into the current data (never destructive): trails deduped
  /// by name+created-time, walks by start-time, regions by id.
  static Future<RestoreResult> restore(String text) async {
    final m = jsonDecode(text) as Map<String, dynamic>;

    final s = m['settings'] as Map?;
    if (s != null) {
      await Settings.instance.setMetric(s['metric'] as bool? ?? true);
      await Settings.instance
          .setWeightKg((s['weightKg'] as num?)?.toDouble() ?? 70);
    }

    var regionsAdded = 0;
    for (final rj in (m['regions'] as List? ?? [])) {
      final r = Region.fromJson((rj as Map).cast<String, dynamic>());
      if (!userRegions.any((e) => e.id == r.id)) {
        await addUserRegion(r);
        regionsAdded++;
      }
    }

    final existingTrails = await TrailStore.instance.all();
    final trailKeys = {
      for (final t in existingTrails)
        '${t.name}|${t.createdAt.millisecondsSinceEpoch}'
    };
    var trailsAdded = 0;
    for (final tj in (m['trails'] as List? ?? [])) {
      final t = Trail.fromBackupJson((tj as Map).cast<String, dynamic>());
      final key = '${t.name}|${t.createdAt.millisecondsSinceEpoch}';
      if (!trailKeys.contains(key)) {
        await TrailStore.instance.restoreTrail(t);
        trailKeys.add(key);
        trailsAdded++;
      }
    }

    final existingActs = await TrailStore.instance.activities();
    final actKeys = {
      for (final a in existingActs) a.startedAt.millisecondsSinceEpoch ~/ 60000
    };
    var actsAdded = 0;
    for (final aj in (m['activities'] as List? ?? [])) {
      final a = Activity.fromRow((aj as Map).cast<String, Object?>());
      final key = a.startedAt.millisecondsSinceEpoch ~/ 60000;
      if (!actKeys.contains(key)) {
        await TrailStore.instance.addActivity(a);
        await Settings.instance.addWalk(a.distanceMeters, a.elevGainMeters);
        actKeys.add(key);
        actsAdded++;
      }
    }

    return RestoreResult(trailsAdded, actsAdded, regionsAdded);
  }
}
