import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/activity.dart' show RecordingCheckpoint, TrackPoint;
import '../models/region.dart';
import '../models/trail.dart';
import '../services/crash_log.dart';
import '../services/cue_gen.dart';
import '../services/geo.dart';
import '../services/gps_filter.dart';
import '../services/native_bridge.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/stillness_watchdog.dart';
import '../services/trail_router.dart';
import '../services/trail_store.dart';
import '../widgets/base_map.dart';
import '../widgets/big_action_card.dart';

/// Records a walked route via GPS ("record trail"): tracks the exact path from
/// start to stop, then auto-builds a Trail — turn cues placed at the forks she
/// actually walked, matching the direction she travelled — ready to save and
/// use like any hand-drawn trail.
class RecordTrailScreen extends StatefulWidget {
  const RecordTrailScreen({super.key, required this.region, this.resume});
  final Region region;

  /// A crash-safe checkpoint to resume from (see [RecordingCheckpoint])
  /// instead of starting a fresh recording — set when the walker chose
  /// "Resume" from the unfinished-recording prompt HomeScreen shows after
  /// the app was reopened following an interruption (killed process, phone
  /// restart) rather than a deliberate Stop.
  final RecordingCheckpoint? resume;

  @override
  State<RecordTrailScreen> createState() => _RecordTrailScreenState();
}

class _RecordTrailScreenState extends State<RecordTrailScreen> {
  MapLibreMapController? _c;
  RouteLayer? _route;
  StreamSubscription<Position>? _sub;
  Timer? _clock;
  Timer? _checkpointTimer;
  final List<LatLng> _path = [];
  LatLng? _last;
  double _meters = 0;
  DateTime? _startedAt;

  /// Smooths raw GPS fixes live as they arrive — see [GpsKalmanFilter]'s doc
  /// for why this exists (the old step-distance-only filter couldn't tell a
  /// noisy fix from a real step, so forest/urban-canyon GPS multipath ended
  /// up recorded as real sideways wander). Created from the first fix.
  GpsKalmanFilter? _filter;

  /// Quality counters for the post-walk note below — plain counts, nothing
  /// surfaced live (the smoothing itself is meant to be fully automatic and
  /// silent while walking).
  int _fixCount = 0;
  int _poorFixCount = 0;

  /// A fix worse than this (metres) counts as "poor" for [_poorFixCount] —
  /// roughly, worse than typical forest-canopy GPS accuracy.
  static const double _poorAccuracyMeters = 20.0;

  /// If more than this fraction of fixes were poor, the post-walk note
  /// mentions it — see [_maybeShowSignalNote].
  static const double _poorFixWarnFraction = 0.3;
  bool _stopping = false;
  bool _cleaning = false;
  String _status = 'Getting your location…';

  // --- Pause/resume state --- (mirrors GuideScreen's identical mechanism;
  // in-app only here, not wired to the background-notification pause/resume
  // action GuideScreen also supports — recording is always a foreground,
  // actively-walked-with-phone-in-hand session, unlike a long guided walk.)
  bool _paused = false;
  DateTime? _pausedAt;
  Duration _pausedTotal = Duration.zero;

  /// Timestamped/elevation track and climb total for this walk — same
  /// fields GuideScreen logs as an Activity, so recording a trail also
  /// leaves real walking history behind instead of just a drawn line. See
  /// [_stop] and HomeScreen._recordTrail for where this gets saved (the
  /// trail has no id yet here, so the Activity itself is logged later).
  final List<TrackPoint> _track = [];
  double _elevGain = 0;
  double? _smoothAlt;
  double? _elevRef;

  int get _elapsedSec {
    if (_startedAt == null) return 0;
    final pausedSoFar = _pausedTotal +
        (_paused && _pausedAt != null
            ? DateTime.now().difference(_pausedAt!)
            : Duration.zero);
    return DateTime.now().difference(_startedAt!).inSeconds -
        pausedSoFar.inSeconds;
  }

  final FlutterTts _tts = FlutterTts();
  late final StillnessWatchdog _watchdog =
      StillnessWatchdog(onNudge: _onStillnessNudge, onSendAlert: _sendStillnessAlert);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    NativeBridge.onAcknowledgeStillness = _acknowledgeStillness;
    final r = widget.resume;
    if (r != null) {
      _path.addAll(r.path);
      if (_path.isNotEmpty) {
        _last = _path.last;
        _lastRaw = _path.last;
      }
      _meters = r.walkedMeters;
      _elevGain = r.elevGainMeters;
      _track.addAll(r.track);
      _startedAt = r.startedAt;
      _pausedTotal = Duration(seconds: r.pausedTotalSec);
      _paused = r.wasPaused;
      // Same reasoning as GuideScreen's identical seeding: a resumed-while-
      // paused checkpoint needs a real _pausedAt too, or the elapsed-time
      // math (and a later Resume tap) would read a null gap as zero.
      _pausedAt = _paused ? DateTime.now() : null;
    }
    _initTts();
    _start();
  }

  Future<void> _initTts() async {
    final voice = Settings.parseVoice(Settings.instance.ttsVoice.value);
    await _tts.setLanguage(voice?['locale'] ?? 'en-US');
    await _tts.setSpeechRate(0.44);
    if (voice != null) {
      try {
        await _tts.setVoice(voice);
      } catch (_) {
        // Voice may have been uninstalled/changed since it was picked in
        // Settings — fall back silently to the locale's system default.
      }
    }
  }

  Future<void> _start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Turn on location services to start.');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission is needed to record.');
      return;
    }
    setState(() => _status = 'Recording');
    _startedAt ??= DateTime.now(); // already set when resuming a checkpoint
    await _ensureBackgroundCapability();
    await NativeBridge.startTracking();
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best, distanceFilter: 3),
    ).listen(_onPosition, onError: _onPositionError);
    // Resumed into a paused checkpoint — freeze immediately rather than
    // silently resuming GPS tracking without a fresh Resume tap.
    if (_paused) _sub?.pause();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _checkpointTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _writeCheckpoint());
  }

  /// Checkpoints the recording so far so it can be resumed if the app is
  /// killed before a deliberate Stop — see [RecordingCheckpoint]. Called
  /// periodically and on pause/resume, mirroring GuideScreen's identical
  /// [_writeCheckpoint].
  Future<void> _writeCheckpoint() async {
    if (_startedAt == null) return;
    try {
      await TrailStore.instance.saveRecordingCheckpoint(RecordingCheckpoint(
        regionId: widget.region.id,
        startedAt: _startedAt!,
        pausedTotalSec: _pausedTotal.inSeconds,
        wasPaused: _paused,
        walkedMeters: _meters,
        elevGainMeters: _elevGain,
        path: _path,
        track: _track,
      ));
    } catch (e, st) {
      // A transient disk/sqflite error here shouldn't take down an
      // in-progress recording — just means this checkpoint write is lost;
      // the next periodic write (or the final clear on Stop) tries again.
      CrashLog.log('Recording checkpoint write', e, st);
    }
  }

  void _pauseRecording() {
    if (_paused || _startedAt == null) return;
    setState(() {
      _paused = true;
      _pausedAt = DateTime.now();
    });
    _sub?.pause();
    _watchdog.pause();
    _tts.stop();
    _writeCheckpoint();
  }

  void _resumeRecording() {
    if (!_paused) return;
    setState(() {
      _pausedTotal += DateTime.now().difference(_pausedAt ?? DateTime.now());
      _paused = false;
      _pausedAt = null;
    });
    _sub?.resume();
    _watchdog.resume();
    _writeCheckpoint();
  }

  /// See GuideScreen's identical handler for why this matters: without an
  /// `onError`, a position-*stream* error (GPS/location-services dropping
  /// out, permission revoked mid-recording) would otherwise be an uncaught
  /// exception with nowhere to go.
  void _onPositionError(Object error, StackTrace stack) {
    CrashLog.log('Position stream (recording)', error, stack);
    if (!mounted) return;
    final String msg;
    if (error is LocationServiceDisabledException) {
      msg = 'Location services turned off — turn them back on to keep recording.';
    } else if (error is PermissionDeniedException) {
      msg = 'Location permission was lost — re-grant it to keep recording.';
    } else {
      msg = 'Lost GPS signal — trying to reconnect…';
    }
    setState(() => _status = msg);
  }

  /// Requests the permissions needed for recording/alerts to survive a locked
  /// screen or a backgrounded app. Best-effort — a decline just keeps this
  /// recording foreground-only, same as before this feature existed.
  Future<void> _ensureBackgroundCapability() async {
    try {
      await Permission.notification.request();
      await Permission.locationAlways.request();
    } catch (_) {}
  }

  void _onStillnessNudge() {
    final smsOn = Settings.instance.sendEmergencySms.value;
    final spoken = smsOn
        ? "Are you still there? Tap I'm OK, or an alert will be sent."
        : "Are you still there? Tap I'm OK, or you'll keep being reminded.";
    NativeBridge.showNudgeNotification('Still there?', spoken);
    if (!mounted) return;
    setState(() {});
    _buzz(long: true);
    _speakSafe(spoken);
  }

  /// Wraps flutter_tts calls, which can throw/reject on devices with no TTS
  /// engine installed or a broken default voice — a real condition on older
  /// phones, and one that would otherwise be an unhandled async exception
  /// (these calls are fire-and-forget from callbacks, not awaited by callers).
  Future<void> _speakSafe(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e, st) {
      CrashLog.log('TTS', e, st);
    }
  }

  Future<void> _buzz({bool long = false}) async {
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(duration: long ? 900 : 400);
      }
    } catch (e, st) {
      CrashLog.log('Vibration', e, st);
    }
  }

  Future<bool> _sendStillnessAlert() async {
    NativeBridge.cancelNudgeNotification();
    final contact = Settings.instance.emergencyPhone.value;
    final pos = _last;
    if (contact.isEmpty || pos == null) return false;
    final link = 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    final ok = await NativeBridge.sendSms(contact,
        'APS Trails alert: stationary for a while while recording a trail. '
        'Last known location: $link');
    if (mounted) setState(() {});
    return ok;
  }

  void _acknowledgeStillness() {
    _watchdog.acknowledge();
    NativeBridge.cancelNudgeNotification();
    if (!mounted) return;
    setState(() {});
  }

  /// Compact one-line stillness-watchdog readout for the debug overlay —
  /// see Settings.debugStillness. Null when the toggle is off.
  String? _debugText() {
    if (!Settings.instance.debugStillness.value) return null;
    final w = _watchdog;
    final fixAge = w.lastFixAt == null
        ? '—'
        : '${DateTime.now().difference(w.lastFixAt!).inSeconds}s ago';
    final acc = w.lastAccuracy == null ? '—' : '${w.lastAccuracy!.round()}m';
    return 'DEBUG phase:${w.phase.name} still:${w.stillFor.inSeconds}s '
        'fix:$fixAge acc:$acc resets:${w.anchorResets} '
        'walked:${w.walkedSinceAnchor.round()}m';
  }

  /// Raw (unfiltered) last fix — kept separate from [_last] (the last
  /// *filtered* point) purely so [_watchdog]'s stillness detection keeps
  /// seeing exactly the same raw step distances it always has. The watchdog
  /// is a separate safety subsystem (the "are you still there?" nudge); it
  /// doesn't need or want GPS smoothing, just deliberately left untouched.
  LatLng? _lastRaw;

  void _onPosition(Position pos) {
    final rawHere = LatLng(pos.latitude, pos.longitude);
    final rawStep = _lastRaw == null ? null : metersBetween(_lastRaw!, rawHere);
    _watchdog.update(rawHere, accuracy: pos.accuracy, stepMeters: rawStep);
    _lastRaw = rawHere;

    _fixCount++;
    if (pos.accuracy > _poorAccuracyMeters) _poorFixCount++;

    // Smooths this fix against the filter's running motion estimate,
    // weighted by the fix's own reported accuracy — see GpsKalmanFilter's
    // doc for why this (not the step-distance gate below) is what actually
    // fixes GPS-noise wander. The filter seeds itself from the first fix
    // automatically.
    _filter ??= GpsKalmanFilter(rawHere);
    final here = _filter!.update(pos);

    final step = _last == null ? null : metersBetween(_last!, here);
    final ele = pos.altitude != 0 ? pos.altitude : null;
    if (_last == null) {
      _path.add(here);
      _track.add(TrackPoint(here, _elapsedSec, ele: ele));
    } else {
      // Coarse sanity backstop against a single pathological (teleport-style)
      // fix — no longer the primary noise defense now that the filter above
      // weighs every fix by its own reported accuracy instead of accepting
      // or rejecting purely by distance.
      if (step! >= 2.5 && step <= 100) {
        _meters += step;
        _path.add(here);
        _track.add(TrackPoint(here, _elapsedSec, ele: ele));
      }
    }
    _last = here;

    // Elevation gain from GPS altitude — same smoothing/hysteresis as
    // GuideScreen's identical logic, so a recorded trail's initial climb
    // total is measured the same way a later guided walk of it would be.
    final acc = pos.altitudeAccuracy;
    if (pos.altitude != 0 && (acc <= 0 || acc <= 20)) {
      final alt = pos.altitude;
      _smoothAlt = _smoothAlt == null ? alt : _smoothAlt! * 0.6 + alt * 0.4;
      final s = _smoothAlt!;
      if (_elevRef == null) {
        _elevRef = s;
      } else if (s - _elevRef! > 4.0) {
        _elevGain += s - _elevRef!;
        _elevRef = s;
      } else if (s - _elevRef! < -4.0) {
        _elevRef = s;
      }
    }

    _c?.animateCamera(CameraUpdate.newLatLng(here));
    _route?.setRoute(_path, '#1565C0');
    if (mounted) setState(() {});
  }

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null) return;
    _route = RouteLayer(c);
    await _route!.ensure();
    // A resumed recording already has a path — draw it immediately instead
    // of waiting for the next GPS fix to trigger the first draw.
    if (_path.length >= 2) await _route!.setRoute(_path, '#1565C0');
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await _sub?.cancel();
    _clock?.cancel();
    _checkpointTimer?.cancel();
    _watchdog.dispose();
    NativeBridge.cancelNudgeNotification();
    await NativeBridge.stopTracking();
    await WakelockPlus.disable();
    // A deliberate Stop — successful or a too-short recording — always
    // clears the checkpoint; there's nothing left to crash-resume into.
    await TrailStore.instance.clearRecordingCheckpoint();
    if (_path.length < 2) {
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() => _cleaning = true);
    final cleaned = await _cleanPath(_path);
    final finalPath = cleaned.path;
    final cues = suggestCues(finalPath, junctions: cleaned.junctions);
    final draft = Trail(
      name: _defaultName(),
      regionId: regionForPoint(finalPath.first).id,
      path: finalPath,
      anchors: [for (final c in cues) c.position],
      cues: cues,
      // Seed the trail's own totals with the walk that recorded it — see
      // the `recordedTrack` doc comment for why the Activity itself isn't
      // saved until HomeScreen knows the trail's id.
      walkedMeters: _meters,
      walkCount: 1,
      elevGainMeters: _elevGain,
      recordedTrack: List.of(_track),
      recordedStartedAt: _startedAt,
      recordedDurationSec: _elapsedSec,
    );
    await _maybeShowSignalNote();
    if (mounted) Navigator.pop(context, draft);
  }

  /// One-time, informational-only note if GPS was consistently poor during
  /// the walk — no decision required, just acknowledging it. The live
  /// smoothing (see [GpsKalmanFilter]) already did what it could
  /// automatically; this just sets expectations for a walk where the phone
  /// itself was reporting meaningfully degraded accuracy for a real chunk of
  /// the recording, rather than silently saying nothing.
  Future<void> _maybeShowSignalNote() async {
    if (_fixCount == 0 || _poorFixCount / _fixCount <= _poorFixWarnFraction) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text('Signal was weak for part of this walk.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Removes GPS jitter (Douglas–Peucker), then nudges each simplified anchor
  /// individually onto the nearest mapped trail/road, if one is close by.
  /// Deliberately does NOT route between anchors — that used to hand the
  /// path to the same shortest-path search auto-generation uses, and one
  /// unmapped or gappy spot anywhere along the recording could send the
  /// search off toward a completely unrelated nearby trail (e.g. cutting
  /// through a park or parking lot), replacing an already-accurate recorded
  /// segment with a router guess. A per-point local snap can only pull a
  /// point a short, bounded distance toward what's actually mapped — it
  /// can never invent a detour, so the recorded shape is always preserved.
  ///
  /// The input is now Kalman-smoothed (see [GpsKalmanFilter]) rather than
  /// raw GPS, so this 8m Douglas-Peucker tolerance is simplifying an
  /// already-clean line, not fighting per-fix jitter — left unchanged since
  /// it's solving a different problem (point-density compression) than the
  /// live filter does (noise removal).
  ///
  /// Also collects real trail-network junctions near each anchor (reusing
  /// the camera position already paid for below) so [_stop] can pass them to
  /// [suggestCues] for "stay straight" cues at forks — this was previously
  /// always empty, silently dropping that cue type for every recorded trail.
  Future<({List<LatLng> path, List<LatLng> junctions})> _cleanPath(List<LatLng> raw) async {
    final anchors = simplifyPath(raw, 8);
    final c = _c;
    if (c == null || anchors.length < 2) {
      return (path: anchors, junctions: const <LatLng>[]);
    }
    final router = TrailRouter(c);
    final out = <LatLng>[];
    final junctions = <LatLng>[];
    for (final a in anchors) {
      // Bring the point into view so the trail/road network around it is
      // rendered and queryable (the router only sees on-screen features).
      const pad = 0.0015;
      await c.moveCamera(CameraUpdate.newLatLngBounds(LatLngBounds(
        southwest: LatLng(a.latitude - pad, a.longitude - pad),
        northeast: LatLng(a.latitude + pad, a.longitude + pad),
      )));
      await Future.delayed(const Duration(milliseconds: 120));
      final snapped = await router.snapPoint(a);
      if (out.isEmpty || metersBetween(out.last, snapped) >= 3) {
        out.add(snapped);
      }
      // Costs a second graph build per anchor (snapPoint above already did
      // one) — acceptable since anchor count here is post-simplification
      // (a handful to a few dozen points), and this all happens during the
      // "Cleaning up the trail…" spinner, not live during the walk.
      junctions.addAll(await router.junctionsNear([a], await router.visibleViewportRect()));
    }
    return (path: out.length >= 2 ? out : anchors, junctions: junctions);
  }

  String _defaultName() {
    final d = DateTime.now();
    return 'Recorded walk ${d.month}/${d.day}';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _clock?.cancel();
    _checkpointTimer?.cancel();
    _watchdog.dispose();
    _tts.stop();
    if (identical(NativeBridge.onAcknowledgeStillness, _acknowledgeStillness)) {
      NativeBridge.onAcknowledgeStillness = null;
    }
    NativeBridge.cancelNudgeNotification();
    NativeBridge.stopTracking();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final debugText = _debugText();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _stop();
      },
      child: Scaffold(
        body: Stack(
          children: [
            BaseMap(
              region: widget.region,
              initialCamera: CameraPosition(
                  target: _last ?? widget.region.center, zoom: 16),
              onMapCreated: (c) => _c = c,
              onStyleLoaded: _onStyleLoaded,
              myLocationEnabled: true,
              trackCameraPosition: true,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 6)
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Recording trail',
                                style: TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.bold)),
                            Text(
                              _startedAt == null
                                  ? _status
                                  : '${Settings.formatDuration(_elapsedSec)}'
                                      '  ·  ${Settings.instance.formatDistance(_meters)}'
                                      '${_paused ? '  ·  Paused' : ''}',
                              style: const TextStyle(
                                  fontSize: 15, color: Colors.black54),
                            ),
                            if (debugText != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(debugText,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                        color: Colors.deepOrange)),
                              ),
                          ],
                        ),
                      ),
                      if (_startedAt != null) ...[
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFEF6C00),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                          ),
                          onPressed: _stopping
                              ? null
                              : (_paused ? _resumeRecording : _pauseRecording),
                          icon: Icon(_paused ? Icons.play_arrow : Icons.pause,
                              size: 24),
                          label: Text(_paused ? 'Resume' : 'Pause',
                              style: const TextStyle(fontSize: 16)),
                        ),
                        const SizedBox(width: 8),
                      ],
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFC62828),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                        onPressed: _stopping ? null : _stop,
                        icon: const Icon(Icons.stop, size: 24),
                        label: const Text('Stop', style: TextStyle(fontSize: 16)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_cleaning)
              Container(
                color: Colors.black38,
                child: const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 16),
                          Text('Cleaning up the trail…',
                              style: TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_watchdog.phase != StillnessPhase.normal) _stillnessCard(),
          ],
        ),
      ),
    );
  }

  Widget _stillnessCard() {
    switch (_watchdog.phase) {
      case StillnessPhase.nudged:
        return BigActionCard(
          color: const Color(0xFFF57F17),
          icon: Icons.pause_circle_outline,
          text: "Haven't moved in a while.\nStill there?",
          dismissIcon: Icons.check_circle,
          dismissTooltip: "I'm OK",
          onRepeat: () => _speakSafe(Settings.instance.sendEmergencySms.value
              ? "Are you still there? Tap I'm OK, or an alert will be sent."
              : "Are you still there? Tap I'm OK, or you'll keep being reminded."),
          onDismiss: _acknowledgeStillness,
        );
      case StillnessPhase.alerting:
        return BigActionCard(
          color: const Color(0xFFC62828),
          icon: Icons.sms_failed,
          text: 'No movement — sending an alert to your emergency contact',
          dismissIcon: Icons.check_circle,
          dismissTooltip: "I'm OK",
          onRepeat: () =>
              _speakSafe('Sending an alert to your emergency contact.'),
          onDismiss: _acknowledgeStillness,
        );
      case StillnessPhase.sent:
        return BigActionCard(
          color: const Color(0xFF2E7D32),
          icon: Icons.check_circle,
          text: 'Alert sent to your emergency contact with your location.',
          dismissIcon: Icons.close,
          dismissTooltip: 'Dismiss',
          onRepeat: () =>
              _speakSafe('An alert was sent to your emergency contact.'),
          onDismiss: _acknowledgeStillness,
        );
      case StillnessPhase.normal:
        return const SizedBox.shrink();
    }
  }
}
