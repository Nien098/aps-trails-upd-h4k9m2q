import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/region.dart';
import '../models/trail.dart';
import '../services/cue_gen.dart';
import '../services/geo.dart';
import '../services/native_bridge.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/stillness_watchdog.dart';
import '../services/trail_router.dart';
import '../widgets/base_map.dart';
import '../widgets/big_action_card.dart';

/// Records a walked route via GPS ("record trail"): tracks the exact path from
/// start to stop, then auto-builds a Trail — turn cues placed at the forks she
/// actually walked, matching the direction she travelled — ready to save and
/// use like any hand-drawn trail.
class RecordTrailScreen extends StatefulWidget {
  const RecordTrailScreen({super.key, required this.region});
  final Region region;

  @override
  State<RecordTrailScreen> createState() => _RecordTrailScreenState();
}

class _RecordTrailScreenState extends State<RecordTrailScreen> {
  MapLibreMapController? _c;
  RouteLayer? _route;
  StreamSubscription<Position>? _sub;
  Timer? _clock;
  final List<LatLng> _path = [];
  LatLng? _last;
  double _meters = 0;
  DateTime? _startedAt;
  bool _stopping = false;
  bool _cleaning = false;
  String _status = 'Getting your location…';

  final FlutterTts _tts = FlutterTts();
  late final StillnessWatchdog _watchdog =
      StillnessWatchdog(onNudge: _onStillnessNudge, onSendAlert: _sendStillnessAlert);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    NativeBridge.onAcknowledgeStillness = _acknowledgeStillness;
    _tts.setLanguage('en-US');
    _tts.setSpeechRate(0.44);
    _start();
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
    _startedAt = DateTime.now();
    await _ensureBackgroundCapability();
    await NativeBridge.startTracking();
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best, distanceFilter: 3),
    ).listen(_onPosition);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
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
    Vibration.hasVibrator().then((v) {
      if (v == true) Vibration.vibrate(duration: 900);
    });
    _tts.speak(spoken);
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

  void _onPosition(Position pos) {
    final here = LatLng(pos.latitude, pos.longitude);
    final step = _last == null ? null : metersBetween(_last!, here);
    _watchdog.update(here, accuracy: pos.accuracy, stepMeters: step);
    if (_last == null) {
      _path.add(here);
    } else {
      if (step! >= 2.5 && step <= 100) {
        _meters += step;
        _path.add(here);
      }
    }
    _last = here;
    _c?.animateCamera(CameraUpdate.newLatLng(here));
    _route?.setRoute(_path, '#1565C0');
    if (mounted) setState(() {});
  }

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null) return;
    _route = RouteLayer(c);
    await _route!.ensure();
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await _sub?.cancel();
    _clock?.cancel();
    _watchdog.dispose();
    NativeBridge.cancelNudgeNotification();
    await NativeBridge.stopTracking();
    await WakelockPlus.disable();
    if (_path.length < 2) {
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() => _cleaning = true);
    final finalPath = await _cleanPath(_path);
    final cues = suggestCues(finalPath);
    final draft = Trail(
      name: _defaultName(),
      regionId: regionForPoint(finalPath.first).id,
      path: finalPath,
      anchors: [for (final c in cues) c.position],
      cues: cues,
    );
    if (mounted) Navigator.pop(context, draft);
  }

  /// Removes GPS jitter (Douglas–Peucker), then snaps the simplified anchors
  /// onto any mapped trail/road network — nudging the route onto real paths
  /// where they exist, and keeping a clean straight line where they don't.
  Future<List<LatLng>> _cleanPath(List<LatLng> raw) async {
    final anchors = simplifyPath(raw, 8);
    final c = _c;
    if (c == null || anchors.length < 2) return anchors;
    final router = TrailRouter(c);
    final out = <LatLng>[anchors.first];
    for (var i = 1; i < anchors.length; i++) {
      final a = out.last, b = anchors[i];
      if (metersBetween(a, b) < 3) continue;
      // Bring both points into view so the trail/road network around them is
      // rendered and queryable (the router only sees on-screen features).
      const pad = 0.004;
      await c.moveCamera(CameraUpdate.newLatLngBounds(LatLngBounds(
        southwest: LatLng(
            (a.latitude < b.latitude ? a.latitude : b.latitude) - pad,
            (a.longitude < b.longitude ? a.longitude : b.longitude) - pad),
        northeast: LatLng(
            (a.latitude > b.latitude ? a.latitude : b.latitude) + pad,
            (a.longitude > b.longitude ? a.longitude : b.longitude) + pad),
      )));
      await Future.delayed(const Duration(milliseconds: 120));
      final conn = await router.connect(from: a, to: b);
      out.addAll(conn.polyline.skip(1));
    }
    return out;
  }

  String _defaultName() {
    final d = DateTime.now();
    return 'Recorded walk ${d.month}/${d.day}';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _clock?.cancel();
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
              initialCamera: CameraPosition(target: widget.region.center, zoom: 16),
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
                                  : '${Settings.formatDuration(DateTime.now().difference(_startedAt!).inSeconds)}'
                                      '  ·  ${Settings.instance.formatDistance(_meters)}',
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
          onRepeat: () => _tts.speak(Settings.instance.sendEmergencySms.value
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
              _tts.speak('Sending an alert to your emergency contact.'),
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
              _tts.speak('An alert was sent to your emergency contact.'),
          onDismiss: _acknowledgeStillness,
        );
      case StillnessPhase.normal:
        return const SizedBox.shrink();
    }
  }
}
