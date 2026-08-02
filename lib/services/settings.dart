import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide preferences. Currently just the distance unit system, kept in a
/// [ValueNotifier] so widgets can rebuild when it changes.
class Settings {
  Settings._();
  static final Settings instance = Settings._();

  static const _kMetric = 'metric_units';
  static const _kAllTime = 'all_time_meters';
  static const _kAllTimeElev = 'all_time_elev_meters';
  static const _kWeight = 'body_weight_kg';
  static const _kSafetyEnabled = 'safety_enabled';
  static const _kEmergencyPhone = 'emergency_phone';
  static const _kNudgeMinutes = 'stillness_nudge_minutes';
  static const _kEscalateMinutes = 'stillness_escalate_minutes';
  static const _kDebugStillness = 'debug_stillness_overlay';
  static const _kSendEmergencySms = 'send_emergency_sms';
  static const _kTrailLineColor = 'basemap_trail_line_color';
  static const _kTrailLineDashed = 'basemap_trail_line_dashed';

  /// true = metric (m / km), false = imperial (ft / mi). Defaults to metric.
  final ValueNotifier<bool> metric = ValueNotifier(true);

  /// Lifetime distance walked across every trail (metres).
  final ValueNotifier<double> allTimeMeters = ValueNotifier(0);

  /// Lifetime elevation gained (climbed) across every trail (metres).
  final ValueNotifier<double> allTimeElevMeters = ValueNotifier(0);

  /// Body weight in kg, used only to estimate calories. Defaults to 70 kg.
  final ValueNotifier<double> weightKg = ValueNotifier(70);

  /// Whether the stillness safety alert is on. Opt-in (off by default) since
  /// it requires extra permissions (SMS, background location).
  final ValueNotifier<bool> safetyEnabled = ValueNotifier(false);

  /// Emergency contact phone number for the stillness alert SMS.
  final ValueNotifier<String> emergencyPhone = ValueNotifier('');

  /// Minutes stationary before the on-screen/spoken nudge fires.
  final ValueNotifier<int> nudgeMinutes = ValueNotifier(8);

  /// Additional minutes stationary (after the nudge) before the SMS sends.
  final ValueNotifier<int> escalateMinutes = ValueNotifier(8);

  /// Shows a live phase/timer/GPS-fix readout on the walk screens, for
  /// diagnosing the stillness alert during testing. Off by default.
  final ValueNotifier<bool> debugStillness = ValueNotifier(false);

  /// Whether an unacknowledged nudge escalates to the emergency SMS. When
  /// off, the nudge just keeps repeating (a reminder-only mode — e.g. to
  /// catch a walk/record session left running after the walker stopped)
  /// instead of ever texting the emergency contact. On by default.
  final ValueNotifier<bool> sendEmergencySms = ValueNotifier(true);

  /// Colour (hex) of the background map's generic hiking-path line — the
  /// "other trails in the area" clutter, not a trail you've authored (those
  /// draw in their own per-trail colour on top). Defaults to a solid indigo,
  /// distinct from every cue-marker colour.
  final ValueNotifier<String> trailLineColor = ValueNotifier('#3F51B5');

  /// Whether that background trail line is dashed. Off (solid) by default —
  /// a dashed line was the original complaint: hard to follow where several
  /// trails run close together.
  final ValueNotifier<bool> trailLineDashed = ValueNotifier(false);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    metric.value = p.getBool(_kMetric) ?? true;
    allTimeMeters.value = p.getDouble(_kAllTime) ?? 0;
    allTimeElevMeters.value = p.getDouble(_kAllTimeElev) ?? 0;
    weightKg.value = p.getDouble(_kWeight) ?? 70;
    safetyEnabled.value = p.getBool(_kSafetyEnabled) ?? false;
    emergencyPhone.value = p.getString(_kEmergencyPhone) ?? '';
    nudgeMinutes.value = p.getInt(_kNudgeMinutes) ?? 8;
    escalateMinutes.value = p.getInt(_kEscalateMinutes) ?? 8;
    debugStillness.value = p.getBool(_kDebugStillness) ?? false;
    sendEmergencySms.value = p.getBool(_kSendEmergencySms) ?? true;
    trailLineColor.value = p.getString(_kTrailLineColor) ?? '#3F51B5';
    trailLineDashed.value = p.getBool(_kTrailLineDashed) ?? false;
  }

  Future<void> setMetric(bool value) async {
    metric.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kMetric, value);
  }

  Future<void> setWeightKg(double kg) async {
    weightKg.value = kg;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kWeight, kg);
  }

  Future<void> setSafetyEnabled(bool value) async {
    safetyEnabled.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSafetyEnabled, value);
  }

  Future<void> setEmergencyPhone(String phone) async {
    emergencyPhone.value = phone;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kEmergencyPhone, phone);
  }

  Future<void> setNudgeMinutes(int minutes) async {
    nudgeMinutes.value = minutes;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kNudgeMinutes, minutes);
  }

  Future<void> setEscalateMinutes(int minutes) async {
    escalateMinutes.value = minutes;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kEscalateMinutes, minutes);
  }

  Future<void> setDebugStillness(bool value) async {
    debugStillness.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDebugStillness, value);
  }

  Future<void> setSendEmergencySms(bool value) async {
    sendEmergencySms.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSendEmergencySms, value);
  }

  Future<void> setTrailLineColor(String hex) async {
    trailLineColor.value = hex;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTrailLineColor, hex);
  }

  Future<void> setTrailLineDashed(bool value) async {
    trailLineDashed.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kTrailLineDashed, value);
  }

  /// Adds a finished walk's distance and elevation gain to the lifetime totals.
  Future<void> addWalk(double meters, double elevMeters) async {
    allTimeMeters.value += meters;
    allTimeElevMeters.value += elevMeters;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kAllTime, allTimeMeters.value);
    await p.setDouble(_kAllTimeElev, allTimeElevMeters.value);
  }

  /// Formats a distance given in metres per the current unit system.
  String formatDistance(double meters) => format(meters, metric.value);

  /// Pure formatter (metric flag explicit) so it's usable without the notifier.
  static String format(double meters, bool metric) {
    if (metric) {
      if (meters < 1000) return '${meters.round()} m';
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    final feet = meters * 3.28084;
    if (feet < 528) return '${feet.round()} ft'; // under 0.1 mile
    return '${(meters / 1609.344).toStringAsFixed(1)} mi';
  }

  /// Formats an elevation (always in m or ft — never km/mi) per unit system.
  String formatElevation(double meters) => elevation(meters, metric.value);

  static String elevation(double meters, bool metric) {
    if (metric) return '${meters.round()} m';
    return '${(meters * 3.28084).round()} ft';
  }

  /// Average pace as mm:ss per km (or per mile), e.g. "12:30 /km".
  String formatPace(double meters, int seconds) {
    if (meters < 1 || seconds <= 0) return '—';
    final units = metric.value ? meters / 1000 : meters / 1609.344;
    if (units <= 0) return '—';
    final secPerUnit = seconds / units;
    final m = secPerUnit ~/ 60;
    final s = (secPerUnit % 60).round();
    return '$m:${s.toString().padLeft(2, '0')} /${metric.value ? 'km' : 'mi'}';
  }

  /// Average speed, e.g. "4.8 km/h" (or mph).
  String formatSpeed(double meters, int seconds) {
    if (seconds <= 0) return '—';
    final hours = seconds / 3600;
    final dist = metric.value ? meters / 1000 : meters / 1609.344;
    return '${(dist / hours).toStringAsFixed(1)} ${metric.value ? 'km/h' : 'mph'}';
  }

  /// Elapsed time as h:mm:ss or m:ss.
  static String formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Rough calorie estimate for walking [meters] at the set body weight.
  /// Uses ~0.53 kcal per kg per km — good enough for a "roughly this much".
  int estimateCalories(double meters) =>
      (weightKg.value * (meters / 1000) * 0.53).round();
}
