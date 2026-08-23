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
  static const _kDetourFactor = 'trail_router_detour_factor';
  static const _kBatteryWarningShown = 'battery_warning_shown';
  static const _kShareStats = 'share_card_stats';
  static const _kTtsVoice = 'tts_voice';
  static const _kBundledMapUpdated = 'bundled_map_updated';
  static const _kDriveModeFollow = 'drive_mode_follow';
  static const _kUiScale = 'ui_scale';
  static const _kChevronScale = 'chevron_scale';
  static const _kChevronVisible = 'chevron_visible';

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

  /// How far (as a multiple of the straight-line distance) "Follow trails"
  /// will detour to trace real trail geometry between two drawn points,
  /// before giving up and falling back to a straight segment. Higher values
  /// follow tighter switchbacks/bends but risk occasionally cutting through
  /// an unrelated nearby trail loop. Defaults to 2.5x.
  final ValueNotifier<double> detourFactor = ValueNotifier(2.5);

  /// Whether the one-time "keep tracking reliable" battery-optimization
  /// prompt has already been shown at the start of a walk (see
  /// HomeScreen._maybeWarnBattery). Shown once ever, regardless of the
  /// walker's choice — this isn't meant to nag every walk, just make sure
  /// they see it once; Settings → Safety & battery covers it permanently
  /// after that.
  final ValueNotifier<bool> batteryWarningShown = ValueNotifier(false);

  /// Which optional stats (beyond the always-shown Distance/Time/Pace)
  /// appear on the walk-share card — see ShareActivityScreen. Remembered
  /// across shares rather than reset every time. Defaults to just elevation
  /// gain, matching the card's original look.
  final ValueNotifier<Set<String>> shareStats = ValueNotifier({'elevation'});

  /// The spoken-cue voice, as "name|locale" matching what
  /// `FlutterTts.getVoices` reports on this device — see
  /// SettingsScreen's voice picker. Empty string = system default for
  /// whatever language is requested (the app's original behaviour, and
  /// still what a fresh install gets), since the actual list of installed
  /// voices is phone-specific and can't be baked in as a fixed default.
  final ValueNotifier<String> ttsVoice = ValueNotifier('');

  /// True once the bundled default basemap has been replaced by a live
  /// re-download (HomeScreen's "Update" on the built-in map) — see
  /// OfflineMap._copyBaked, which checks this before ever re-copying the
  /// older data baked into the APK back over a freshly-updated file.
  final ValueNotifier<bool> bundledMapUpdated = ValueNotifier(false);

  /// Guide-mode camera style: off (default) = flat, north-up "birds-eye"
  /// view; on = tilted and rotated to face the walker's direction of
  /// travel, the same idea as a car nav app's driving view. Remembered
  /// across walks like every other preference here, rather than resetting
  /// each time — someone who prefers one style is unlikely to want to
  /// re-pick it on every single walk.
  final ValueNotifier<bool> driveModeFollow = ValueNotifier(false);

  /// Overall size of the on-map "HUD" chrome — mode-bar/toolbar buttons, the
  /// search bar, hint banners and their text — on the walking/authoring/
  /// browsing screens. A straight multiplier applied both to text (via a
  /// [MediaQuery] textScaler override, app-wide) and, per screen, to the
  /// floating button clusters themselves (via a scale transform anchored to
  /// each cluster's own screen corner, so it grows toward the visible area
  /// rather than off-edge). Added for accessibility — older/low-vision users
  /// need bigger touch targets and text than a fixed default serves everyone.
  /// Defaults to 1.0 (unchanged from before this existed).
  final ValueNotifier<double> uiScale = ValueNotifier(1.0);

  /// Size of the direction chevrons drawn along a route/trail line — see
  /// [RouteLayer]. A multiplier on top of that layer's own base icon size, so
  /// 1.0 always means "whatever this app already shipped with", independent
  /// of the base constant. Same accessibility motivation as [uiScale], kept
  /// as its own separate setting since a walker may want bigger arrows
  /// without necessarily wanting a bigger toolbar (or vice versa). Defaults
  /// to 0.5 — the original 1.0 (this app's original fixed 1.3x base size)
  /// was reported live (2026-08-22, web trail designer) as much too large
  /// while actually drawing a trail, crowding the screen.
  final ValueNotifier<double> chevronScale = ValueNotifier(0.5);

  /// Whether the direction chevrons render at all — off entirely, not just
  /// small, for someone who wants a completely uncluttered view of the trail
  /// line while drawing. Independent of [chevronScale] (which still applies
  /// once turned back on) rather than overloading scale 0 to mean "hidden",
  /// since a real MapLibre icon layer at size 0 isn't guaranteed to render
  /// as cleanly invisible as an explicit opacity toggle. Defaults to true
  /// (visible) — unchanged from before this existed.
  final ValueNotifier<bool> chevronVisible = ValueNotifier(true);

  /// Parses a saved [ttsVoice] value into the map `FlutterTts.setVoice`
  /// expects, or null if unset/malformed (falls back to system default).
  static Map<String, String>? parseVoice(String v) {
    final parts = v.split('|');
    if (parts.length != 2 || parts[0].isEmpty) return null;
    return {'name': parts[0], 'locale': parts[1]};
  }

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
    detourFactor.value = p.getDouble(_kDetourFactor) ?? 2.5;
    batteryWarningShown.value = p.getBool(_kBatteryWarningShown) ?? false;
    shareStats.value = (p.getStringList(_kShareStats) ?? const ['elevation']).toSet();
    ttsVoice.value = p.getString(_kTtsVoice) ?? '';
    bundledMapUpdated.value = p.getBool(_kBundledMapUpdated) ?? false;
    driveModeFollow.value = p.getBool(_kDriveModeFollow) ?? false;
    uiScale.value = p.getDouble(_kUiScale) ?? 1.0;
    chevronScale.value = p.getDouble(_kChevronScale) ?? 0.5;
    chevronVisible.value = p.getBool(_kChevronVisible) ?? true;
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

  Future<void> setDetourFactor(double value) async {
    detourFactor.value = value.clamp(1.5, 6.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kDetourFactor, detourFactor.value);
  }

  Future<void> setBatteryWarningShown(bool value) async {
    batteryWarningShown.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBatteryWarningShown, value);
  }

  Future<void> setShareStats(Set<String> keys) async {
    shareStats.value = keys;
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kShareStats, keys.toList());
  }

  Future<void> setTtsVoice(String voice) async {
    ttsVoice.value = voice;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTtsVoice, voice);
  }

  Future<void> setBundledMapUpdated(bool value) async {
    bundledMapUpdated.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBundledMapUpdated, value);
  }

  Future<void> setDriveModeFollow(bool value) async {
    driveModeFollow.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDriveModeFollow, value);
  }

  Future<void> setUiScale(double value) async {
    uiScale.value = value.clamp(0.85, 1.75);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kUiScale, uiScale.value);
  }

  Future<void> setChevronScale(double value) async {
    chevronScale.value = value.clamp(0.1, 1.5);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kChevronScale, chevronScale.value);
  }

  Future<void> setChevronVisible(bool value) async {
    chevronVisible.value = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kChevronVisible, value);
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
