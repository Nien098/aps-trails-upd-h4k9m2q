import 'package:flutter/services.dart';

/// Bridge to the small native-Android helpers the background tracking and
/// emergency-alert features need: starting/stopping the tracking foreground
/// service, sending SMS, and checking/requesting battery-optimization
/// exemption. See MainActivity.kt / TrackingService.kt.
class NativeBridge {
  static const _ch = MethodChannel('trailguide/native');

  /// Called when the "I'm OK" action on the stillness-nudge notification is
  /// tapped (see MainActivity/StillnessAckReceiver) — the current walk/record
  /// screen sets this to its `_acknowledgeStillness`, so the nudge can be
  /// silenced from the notification shade without opening the app, the same
  /// way snoozing an alarm doesn't require unlocking the phone.
  static void Function()? onAcknowledgeStillness;

  /// Registers the native→Dart callback handler. Call once at app startup.
  static void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'acknowledgeStillness') {
        onAcknowledgeStillness?.call();
      }
    });
  }

  /// Posts the actionable "Still there?" notification (with an "I'm OK"
  /// action) so a nudge can be silenced without opening the app.
  static Future<void> showNudgeNotification(String title, String text) async {
    try {
      await _ch.invokeMethod(
          'showNudgeNotification', {'title': title, 'text': text});
    } catch (_) {}
  }

  /// Clears the nudge notification (acknowledged, escalated, or walk ended).
  static Future<void> cancelNudgeNotification() async {
    try {
      await _ch.invokeMethod('cancelNudgeNotification');
    } catch (_) {}
  }

  /// Starts the foreground service that keeps the app alive with the screen
  /// off or the app backgrounded during a walk.
  static Future<void> startTracking() async {
    try {
      await _ch.invokeMethod('startTracking');
    } catch (_) {}
  }

  static Future<void> stopTracking() async {
    try {
      await _ch.invokeMethod('stopTracking');
    } catch (_) {}
  }

  /// Sends an SMS and reports whether the carrier actually accepted it (not
  /// just that the call didn't throw) — false on no signal/no SIM/etc.
  static Future<bool> sendSms(String phone, String message) async {
    try {
      final ok = await _ch.invokeMethod<bool>(
          'sendSms', {'phone': phone, 'message': message});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True if this app is already exempt from Android's Doze/App Standby
  /// battery restrictions (the standard, cross-OEM whitelist).
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final v = await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog to request that exemption.
  static Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _ch.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// Launches the system package installer on a downloaded APK. Always shows
  /// Android's own install-confirmation screen — no app can install silently.
  static Future<void> installApk(String path) async {
    try {
      await _ch.invokeMethod('installApk', {'path': path});
    } catch (_) {}
  }

  /// Whether this app is allowed to trigger installs (the "install unknown
  /// apps" permission, separate from the one-time sideload toggle used to
  /// install TrailGuide itself). Always true below Android 8.
  static Future<bool> canInstallPackages() async {
    try {
      final v = await _ch.invokeMethod<bool>('canInstallPackages');
      return v ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system settings screen to grant that permission.
  static Future<void> requestInstallPackagesPermission() async {
    try {
      await _ch.invokeMethod('requestInstallPackagesPermission');
    } catch (_) {}
  }
}
