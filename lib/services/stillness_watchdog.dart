import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'geo.dart';
import 'settings.dart';

enum StillnessPhase { normal, nudged, alerting, sent }

/// Watches a walk's GPS stream for prolonged inactivity and escalates: a big
/// on-screen + spoken nudge once stationary for [Settings.nudgeMinutes], then
/// (if not acknowledged) an SMS to the emergency contact after a further
/// [Settings.escalateMinutes]. A failed send (no signal) retries periodically
/// until it succeeds or the walker moves again. Disabled entirely unless
/// [Settings.safetyEnabled] is on.
class StillnessWatchdog {
  StillnessWatchdog({
    required this.onNudge,
    required this.onSendAlert,
  }) {
    // A genuinely stationary phone with a good GPS lock is exactly the case
    // where Android's location provider stops emitting fixes at all (nothing
    // has moved past distanceFilter) — so the elapsed-time check can't rely
    // solely on update() being re-entered by a new fix. This ticks the same
    // check on a wall clock regardless of whether fixes keep arriving.
    _checkTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _evaluate());
  }

  /// Called once when the nudge should show/speak.
  final VoidCallback onNudge;

  /// Attempts to send the alert; return true once the carrier confirms it
  /// went out. May be called again (retried) if it returns false.
  final Future<bool> Function() onSendAlert;

  static const _stillRadiusMeters = 20.0;
  static const _retryEvery = Duration(minutes: 2);

  LatLng? _anchor;
  DateTime? _anchorTime;
  StillnessPhase phase = StillnessPhase.normal;
  Timer? _retryTimer;
  Timer? _checkTimer;

  /// Cumulative walked distance (m) since the anchor was last set. Straight-
  /// line distance from the anchor alone misses genuine movement that loops
  /// or paces within [_stillRadiusMeters] (net displacement stays small even
  /// though real distance covered keeps growing) — this catches that case.
  double _distSinceAnchor = 0;

  // --- Debug-only readout (see Settings.debugStillness) ---
  /// When the last GPS fix was received, regardless of feature state.
  DateTime? lastFixAt;
  /// Accuracy (metres) reported with the last fix, if the caller provided one.
  double? lastAccuracy;
  /// How many times the anchor has jumped >20m and restarted the still-clock
  /// this walk — a high count while the phone is stationary points at noisy
  /// fixes rather than an actual timing bug.
  int anchorResets = 0;

  /// Seconds accumulated at the current anchor, live (not just at last fix).
  Duration get stillFor =>
      _anchorTime == null ? Duration.zero : DateTime.now().difference(_anchorTime!);

  /// Cumulative walked distance (m) since the anchor was set — debug readout.
  double get walkedSinceAnchor => _distSinceAnchor;

  /// Feed each GPS fix here, with [stepMeters] = the distance from the
  /// previous fix (null for the first fix of the walk). No-ops entirely when
  /// the feature is off.
  void update(LatLng pos, {double? accuracy, double? stepMeters}) {
    if (!Settings.instance.safetyEnabled.value) return;
    lastFixAt = DateTime.now();
    lastAccuracy = accuracy;
    // Ignore sub-2.5m GPS jitter and >100m bad fixes, same filter the walk
    // screens use for their displayed distance stat — so noise from a truly
    // stationary phone can't accumulate into a false "moving" signal.
    if (stepMeters != null && stepMeters >= 2.5 && stepMeters <= 100) {
      _distSinceAnchor += stepMeters;
    }

    final jumped =
        _anchor == null || metersBetween(_anchor!, pos) > _stillRadiusMeters;
    final walked = _distSinceAnchor > _stillRadiusMeters;
    if (jumped || walked) {
      if (_anchor != null) anchorResets++;
      _anchor = pos;
      _anchorTime = DateTime.now();
      _distSinceAnchor = 0;
      if (phase != StillnessPhase.normal) _reset();
      return;
    }

    _evaluate();
  }

  /// The actual phase-escalation check, run both right after a fix confirms
  /// we're still within the anchor radius, and independently every tick of
  /// [_checkTimer] so a quiet GPS stream can't stall the clock.
  void _evaluate() {
    if (!Settings.instance.safetyEnabled.value) return;
    if (_anchorTime == null) return; // no fix yet this walk
    if (phase == StillnessPhase.sent) return; // terminal until she moves again

    final stillSec = DateTime.now().difference(_anchorTime!).inSeconds;
    final nudgeSec = Settings.instance.nudgeMinutes.value * 60;
    final alertSec = nudgeSec + Settings.instance.escalateMinutes.value * 60;

    if (phase == StillnessPhase.normal && stillSec >= nudgeSec) {
      phase = StillnessPhase.nudged;
      onNudge();
    } else if (phase == StillnessPhase.nudged && stillSec >= alertSec) {
      if (Settings.instance.sendEmergencySms.value) {
        phase = StillnessPhase.alerting;
        _attemptSend();
      } else {
        // Reminder-only mode: keep nudging instead of ever texting anyone —
        // useful just to catch a walk left running after the walker stopped.
        _anchorTime = DateTime.now();
        onNudge();
      }
    }
  }

  Future<void> _attemptSend() async {
    final ok = await onSendAlert();
    _retryTimer?.cancel();
    if (ok) {
      phase = StillnessPhase.sent;
    } else if (phase == StillnessPhase.alerting) {
      _retryTimer = Timer(_retryEvery, _attemptSend);
    }
  }

  /// "I'm OK" — cancels any pending escalation/retry and resets the clock.
  void acknowledge() {
    _retryTimer?.cancel();
    _anchor = null;
    _anchorTime = null;
    phase = StillnessPhase.normal;
  }

  void _reset() {
    _retryTimer?.cancel();
    phase = StillnessPhase.normal;
  }

  void dispose() {
    _retryTimer?.cancel();
    _checkTimer?.cancel();
  }
}
