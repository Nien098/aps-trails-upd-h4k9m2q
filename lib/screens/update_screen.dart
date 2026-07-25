import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/native_bridge.dart';
import '../services/updater.dart';

/// Check-for-updates screen: shows the installed version, lets the user
/// check/download/install a newer build from GitHub Releases. The final
/// install step always needs one tap on Android's own confirmation screen —
/// no app can install silently.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  String _installedVersion = '…';
  bool? _canInstall; // null = not checked yet

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) {
      if (mounted) {
        setState(() => _installedVersion = '${p.version}+${p.buildNumber}');
      }
    });
    NativeBridge.canInstallPackages().then((can) {
      if (mounted) setState(() => _canInstall = can);
    });
    if (Updater.instance.status.value.phase == UpdatePhase.idle) {
      Updater.instance.check();
    }
  }

  Future<void> _download() async {
    if (!await Updater.instance.isOnWifi()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Connect to Wi-Fi to download the update')));
      return;
    }
    await Updater.instance.download();
  }

  Future<void> _install() async {
    final can = await NativeBridge.canInstallPackages();
    if (!can) {
      setState(() => _canInstall = false);
      return;
    }
    await Updater.instance.install();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App updates')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          Text('Installed version: $_installedVersion',
              style: const TextStyle(fontSize: 16, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 20),
          ValueListenableBuilder<UpdateStatus>(
            valueListenable: Updater.instance.status,
            builder: (context, status, _) => _body(status),
          ),
        ],
      ),
    );
  }

  Widget _body(UpdateStatus status) {
    switch (status.phase) {
      case UpdatePhase.idle:
      case UpdatePhase.checking:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        );

      case UpdatePhase.upToDate:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
                SizedBox(width: 10),
                Text("You're up to date", style: TextStyle(fontSize: 18)),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => Updater.instance.check(),
              icon: const Icon(Icons.refresh),
              label: const Text('Check for updates'),
            ),
          ],
        );

      case UpdatePhase.available:
        final info = status.info!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Update available: ${info.versionName}',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('${(info.sizeBytes / 1024 / 1024).round()} MB',
                style: const TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(info.notes, style: const TextStyle(fontSize: 15)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _download,
              icon: const Icon(Icons.download),
              label: const Text('Download update'),
            ),
          ],
        );

      case UpdatePhase.downloading:
        final pct = status.total > 0 ? status.received / status.total : 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Downloading…', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: status.total > 0 ? pct : null),
            const SizedBox(height: 8),
            Text(
                '${(status.received / 1024 / 1024).round()} / '
                '${(status.total / 1024 / 1024).round()} MB',
                style: const TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
          ],
        );

      case UpdatePhase.downloaded:
      case UpdatePhase.installing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Update ${status.info?.versionName ?? ''} ready to install',
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 12),
            if (_canInstall == false) ...[
              const Text(
                  "APS Trails needs permission to install updates. "
                  "Tap below, allow it in Settings, then come back and try again.",
                  style: TextStyle(fontSize: 14, color: Color(0xFF4A4A4A))),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: NativeBridge.requestInstallPackagesPermission,
                child: const Text('Allow installs'),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton.icon(
              onPressed: status.phase == UpdatePhase.installing ? null : _install,
              icon: const Icon(Icons.system_update_alt),
              label: const Text('Install update'),
            ),
            const SizedBox(height: 6),
            const Text(
                "Android will ask you to confirm the install — that's normal.",
                style: TextStyle(fontSize: 13, color: Color(0xFF4A4A4A))),
          ],
        );

      case UpdatePhase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Couldn\'t check for updates: ${status.error ?? 'unknown error'}',
                style: const TextStyle(fontSize: 15, color: Color(0xFFC62828))),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Updater.instance.check(),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        );
    }
  }
}
