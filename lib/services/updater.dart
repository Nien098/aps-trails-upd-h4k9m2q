import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'native_bridge.dart';

/// A release fetched from GitHub — its tag must exactly match `pubspec.yaml`'s
/// `version:` (e.g. `1.5.0+11`) with the built APK attached as an asset.
class UpdateInfo {
  UpdateInfo({
    required this.versionName,
    required this.buildNumber,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.notes,
  });

  final String versionName; // "1.5.0"
  final int buildNumber; // 11
  final String downloadUrl;
  final int sizeBytes;
  final String notes; // release body, shown as a plain-text changelog
}

enum UpdatePhase { idle, checking, upToDate, available, downloading, downloaded, installing, error }

class UpdateStatus {
  UpdateStatus(
    this.phase, {
    this.info,
    this.received = 0,
    this.total = 0,
    this.filePath,
    this.error,
  });

  final UpdatePhase phase;
  final UpdateInfo? info;
  final int received;
  final int total;
  final String? filePath;
  final String? error;
}

/// Checks GitHub Releases for a newer build than the one currently installed,
/// downloads it (WiFi only, by design — a 270MB+ APK on mobile data would be
/// a nasty surprise), and hands it to the native installer intent. Android
/// never allows a silent install, so the final step always needs one tap on
/// the system's own confirmation dialog.
class Updater {
  Updater._();
  static final Updater instance = Updater._();

  final ValueNotifier<UpdateStatus> status = ValueNotifier(UpdateStatus(UpdatePhase.idle));

  bool get _isPlaceholderRepo => kUpdateRepo.startsWith('REPLACE_ME');

  Future<bool> isOnWifi() async {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.wifi);
  }

  /// Checks for a newer release. When [autoDownloadOnWifi] is true and a
  /// newer build is found while on WiFi, immediately starts the download too
  /// — this is the "app notices and grabs it" auto path used on launch.
  /// Manual "Check for updates" taps should pass false and let the user
  /// decide whether to download from the available-update screen.
  Future<void> check({bool autoDownloadOnWifi = false}) async {
    if (_isPlaceholderRepo) {
      status.value = UpdateStatus(UpdatePhase.error,
          error: 'Update source not configured yet.');
      return;
    }
    status.value = UpdateStatus(UpdatePhase.checking);
    try {
      final info = await _fetchLatest();
      final current = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(current.buildNumber) ?? 0;
      if (info == null || info.buildNumber <= currentBuild) {
        status.value = UpdateStatus(UpdatePhase.upToDate);
        return;
      }
      status.value = UpdateStatus(UpdatePhase.available, info: info);
      if (autoDownloadOnWifi && await isOnWifi()) {
        await download();
      }
    } catch (e) {
      status.value = UpdateStatus(UpdatePhase.error, error: e.toString());
    }
  }

  Future<UpdateInfo?> _fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(kUpdateApiUrl));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'TrailGuide-app');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?)?.trim();
      if (tag == null) return null;
      final plus = tag.indexOf('+');
      if (plus < 0) return null;
      final versionName = tag.substring(0, plus);
      final buildNumber = int.tryParse(tag.substring(plus + 1));
      if (buildNumber == null) return null;

      final assets = (json['assets'] as List?) ?? const [];
      Map<String, dynamic>? apkAsset;
      for (final a in assets) {
        final m = a as Map<String, dynamic>;
        if ((m['name'] as String? ?? '').endsWith('.apk')) {
          apkAsset = m;
          break;
        }
      }
      if (apkAsset == null) return null;

      return UpdateInfo(
        versionName: versionName,
        buildNumber: buildNumber,
        downloadUrl: apkAsset['browser_download_url'] as String,
        sizeBytes: (apkAsset['size'] as num?)?.toInt() ?? 0,
        notes: (json['body'] as String?)?.trim() ?? '',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> download() async {
    final info = status.value.info;
    if (info == null) return;
    status.value = UpdateStatus(UpdatePhase.downloading, info: info, total: info.sizeBytes);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/updates');
      await dir.create(recursive: true);
      final path = '${dir.path}/trailguide-${info.versionName}+${info.buildNumber}.apk';
      final file = File(path);
      final sink = file.openWrite();

      final req = await client.getUrl(Uri.parse(info.downloadUrl));
      req.headers.set('User-Agent', 'TrailGuide-app');
      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 302) {
        await resp.drain();
        await sink.close();
        status.value = UpdateStatus(UpdatePhase.error,
            info: info, error: 'Download failed (${resp.statusCode})');
        return;
      }
      final total = resp.contentLength > 0 ? resp.contentLength : info.sizeBytes;
      var received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        status.value = UpdateStatus(UpdatePhase.downloading,
            info: info, received: received, total: total);
      }
      await sink.close();
      status.value = UpdateStatus(UpdatePhase.downloaded, info: info, filePath: path);
    } catch (e) {
      status.value = UpdateStatus(UpdatePhase.error, info: info, error: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// Hands the downloaded APK to Android's own installer. This always shows
  /// the system's install-confirmation screen — there is no way for a normal
  /// app to install silently, on any Android version, without root or MDM.
  Future<void> install() async {
    final path = status.value.filePath;
    if (path == null) return;
    status.value = UpdateStatus(UpdatePhase.installing,
        info: status.value.info, filePath: path);
    await NativeBridge.installApk(path);
  }

  void reset() => status.value = UpdateStatus(UpdatePhase.idle);
}
