import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../cue_style.dart';
import '../models/activity.dart';
import '../models/region.dart';
import '../models/trail.dart';
import '../services/geo.dart';
import '../services/native_bridge.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/stillness_watchdog.dart';
import '../services/trail_store.dart';
import '../widgets/base_map.dart';
import '../widgets/big_action_card.dart';
import 'activity_detail_screen.dart';

/// Walking mode: follows the user's GPS along a saved trail and delivers each
/// cue as a giant card + spoken voice + buzz. Designed for low vision — big,
/// high-contrast, and audible so the walker barely needs to read.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key, required this.trail, this.resume});

  final Trail trail;

  /// A crash-safe checkpoint to resume from (see [WalkCheckpoint]) instead of
  /// starting a fresh walk — set when the walker chose "Resume" from the
  /// unfinished-walk prompt shown after the app was reopened following an
  /// interruption (killed process, phone restart) rather than a deliberate Stop.
  final WalkCheckpoint? resume;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  /// How far off the path (metres) before we warn the walker.
  static const _offRouteMeters = 30;

  /// Distance (metres) back within which we consider them on-track again.
  static const _backOnRouteMeters = 18;

  MapLibreMapController? _c;
  StreamSubscription<Position>? _posSub;
  Timer? _debugTick; // refreshes the debug overlay every second between fixes
  final FlutterTts _tts = FlutterTts();

  int _nextIndex = 0; // index into trail.cues of the next expected cue
  Cue? _activeCard; // cue currently shown on the big card (null = none)
  bool _offRoute = false;
  bool _offRouteCardShown = false;
  double? _distToNext; // metres to the next cue
  bool _follow = true;
  String _status = 'Getting your location…';
  String? _lastSpoken; // for the "repeat" button

  double _walkMeters = 0; // distance walked this outing
  LatLng? _lastPos; // previous fix, for step accumulation
  bool _walkSaved = false; // guard so a walk is only banked once

  double _elevGain = 0; // cumulative climb (m) this outing
  double? _smoothAlt; // low-pass-filtered altitude
  double? _elevRef; // baseline the next climb is measured from

  DateTime? _startedAt; // when tracking began, for duration + timestamps
  final List<TrackPoint> _track = []; // recorded GPS track for this walk

  // --- Pause/resume state ---
  bool _paused = false;
  DateTime? _pausedAt;
  Duration _pausedTotal = Duration.zero; // accumulated across every pause
  Timer? _checkpointTimer;

  /// Elapsed walking time, excluding time spent paused (both banked pauses
  /// and, if currently paused, the one in progress).
  int get _elapsedSec {
    if (_startedAt == null) return 0;
    final pausedSoFar = _pausedTotal +
        (_paused && _pausedAt != null
            ? DateTime.now().difference(_pausedAt!)
            : Duration.zero);
    return DateTime.now().difference(_startedAt!).inSeconds -
        pausedSoFar.inSeconds;
  }

  /// Minimum gap between two cue announcements, so overlapping outbound/return
  /// cues can't pop two cards (and speak over each other) on the same tick.
  static const _minFireGap = Duration(seconds: 3);
  DateTime _lastFire = DateTime.fromMillisecondsSinceEpoch(0);

  late final StillnessWatchdog _watchdog =
      StillnessWatchdog(onNudge: _onStillnessNudge, onSendAlert: _sendStillnessAlert);

  /// Cues fire strictly in ascending [Cue.order] — see that field's doc for
  /// why this replaced geometric path-projection ordering (it couldn't
  /// disambiguate a path crossing itself more than twice; explicit stack
  /// order has no such limit, and a "same spot, different message" node —
  /// what used to be one dual-action cue — is just two ordinary cues now).
  late final List<Cue> _cues = List.of(widget.trail.cues)
    ..sort((a, b) => a.order.compareTo(b.order));

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // keep the screen on while walking
    NativeBridge.onAcknowledgeStillness = _acknowledgeStillness;
    NativeBridge.onPauseWalk = _pauseWalk;
    NativeBridge.onResumeWalk = _resumeWalk;
    final r = widget.resume;
    if (r != null) {
      _nextIndex = r.nextIndex.clamp(0, _cues.length);
      _walkMeters = r.walkedMeters;
      _elevGain = r.elevGainMeters;
      _track.addAll(r.track);
      _startedAt = r.startedAt;
      _pausedTotal = Duration(seconds: r.pausedTotalSec);
      _paused = r.wasPaused;
      // If it was paused when it died, _pausedAt needs a real value too —
      // _resumeWalk() unconditionally reads it, and leaving it null would
      // crash that call (silently, inside setState) the moment Resume is
      // tapped. "Now" is also the semantically correct anchor: the entire
      // time the app was closed should count as paused time, same as the
      // time spent looking at the resume prompt before tapping Resume.
      _pausedAt = _paused ? DateTime.now() : null;
      _lastPos = r.lastPos;
    }
    _initTts();
    _startLocation();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.44); // slower & clearer
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> _startLocation() async {
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
      setState(() => _status = 'Location permission is needed to guide you.');
      return;
    }
    setState(() => _status = 'Walking');
    _startedAt ??= DateTime.now(); // already set when resuming a checkpoint
    await _ensureBackgroundCapability();
    await NativeBridge.startTracking();
    if (_paused) await NativeBridge.updateTrackingNotification(true);
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
      ),
    ).listen(_onPosition);
    // Resumed into a paused checkpoint — freeze immediately rather than
    // silently resuming GPS tracking without a fresh Resume tap.
    if (_paused) _posSub?.pause();
    _checkpointTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _writeCheckpoint());
    if (Settings.instance.debugStillness.value) {
      _debugTick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Requests the permissions needed for tracking/cues/alerts to survive a
  /// locked screen or a backgrounded app. Best-effort — a decline just means
  /// this walk stays foreground-only, same as before this feature existed.
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
    _speak(spoken);
  }

  Future<bool> _sendStillnessAlert() async {
    NativeBridge.cancelNudgeNotification();
    final contact = Settings.instance.emergencyPhone.value;
    final pos = _lastPos;
    if (contact.isEmpty || pos == null) return false;
    final link = 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    final ok = await NativeBridge.sendSms(contact,
        'APS Trails alert: stationary for a while during "${widget.trail.name}". '
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

  /// Pauses GPS-driven processing (distance/elevation/cue-firing/off-route/
  /// camera-follow all flow through the same position stream, so pausing it
  /// is enough — no separate guard needed in [_onPosition]) and the
  /// stillness watchdog (otherwise a deliberate rest break would eventually
  /// look identical to an actual stillness emergency). Callable from the
  /// on-screen button or the tracking notification's action.
  void _pauseWalk() {
    if (_paused || _startedAt == null) return;
    setState(() {
      _paused = true;
      _pausedAt = DateTime.now();
    });
    _posSub?.pause();
    _watchdog.pause();
    _tts.stop();
    NativeBridge.updateTrackingNotification(true);
    _writeCheckpoint();
  }

  void _resumeWalk() {
    if (!_paused) return;
    setState(() {
      // Fallback (not just !) so a null _pausedAt can never silently crash
      // this setState and leave the button looking like it does nothing —
      // that's exactly how a resumed-while-paused checkpoint broke Resume
      // before _pausedAt was seeded alongside _paused in initState.
      _pausedTotal += DateTime.now().difference(_pausedAt ?? DateTime.now());
      _paused = false;
      _pausedAt = null;
    });
    _posSub?.resume();
    _watchdog.resume();
    NativeBridge.updateTrackingNotification(false);
    _writeCheckpoint();
  }

  /// Advances past the next cue without firing it — for when a resumed walk
  /// lands at a slightly-off position and the walker (or whoever's helping)
  /// knows a cue or several have already genuinely been passed. Deliberately
  /// dumb and repeatable (tap once per cue to skip) rather than an
  /// auto-"jump to nearest cue" guess.
  void _skipCue() {
    if (_nextIndex >= _cues.length) return;
    final skipped = _cues[_nextIndex];
    setState(() => _nextIndex++);
    _toast('Skipped: ${skipped.label}');
    _writeCheckpoint();
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Checkpoints the walk so far so it can be resumed if the app is killed
  /// before a deliberate Stop — see [WalkCheckpoint]. Cheap single-row
  /// upsert; called on every cue fire, on pause/resume, and periodically
  /// (see [_checkpointTimer]) while walking.
  Future<void> _writeCheckpoint() async {
    final id = widget.trail.id;
    if (id == null || _startedAt == null) return;
    await TrailStore.instance.saveWalkCheckpoint(WalkCheckpoint(
      trailId: id,
      trailName: widget.trail.name,
      startedAt: _startedAt!,
      pausedTotalSec: _pausedTotal.inSeconds,
      wasPaused: _paused,
      nextIndex: _nextIndex,
      walkedMeters: _walkMeters,
      elevGainMeters: _elevGain,
      lastPos: _lastPos,
      track: _track,
    ));
  }

  void _onPosition(Position pos) {
    final me = LatLng(pos.latitude, pos.longitude);
    final step = _lastPos == null ? null : metersBetween(_lastPos!, me);
    _watchdog.update(me, accuracy: pos.accuracy, stepMeters: step);

    // Accumulate walked distance. Ignore sub-2.5 m jitter and >100 m jumps (a
    // bad fix), so standing still or a GPS glitch doesn't inflate the total.
    final tSec = _elapsedSec;
    final ele = pos.altitude != 0 ? pos.altitude : null;
    if (_lastPos == null) {
      _track.add(TrackPoint(me, tSec, ele: ele));
    } else {
      if (step! >= 2.5 && step <= 100) {
        _walkMeters += step;
        _track.add(TrackPoint(me, tSec, ele: ele));
      }
    }
    _lastPos = me;

    // Elevation gain from GPS altitude. Altitude is noisy, so smooth it and only
    // count sustained climbs above a threshold (hysteresis) — this filters
    // metre-to-metre jitter that would otherwise inflate the total. Samples with
    // a known-bad altitude accuracy are skipped.
    final acc = pos.altitudeAccuracy;
    if (pos.altitude != 0 && (acc <= 0 || acc <= 20)) {
      final alt = pos.altitude;
      _smoothAlt = _smoothAlt == null ? alt : _smoothAlt! * 0.6 + alt * 0.4;
      final s = _smoothAlt!;
      if (_elevRef == null) {
        _elevRef = s;
      } else if (s - _elevRef! > 4.0) {
        _elevGain += s - _elevRef!; // sustained climb
        _elevRef = s;
      } else if (s - _elevRef! < -4.0) {
        _elevRef = s; // descending: reset baseline lower
      }
    }

    // Follow the walker with the camera.
    if (_follow) {
      _c?.animateCamera(CameraUpdate.newLatLng(me));
    }

    // Cue triggering comes first: reaching a cue means you're on the trail,
    // so it should win over any off-route warning this tick.
    var firedCue = false;
    if (_nextIndex < _cues.length) {
      final next = _cues[_nextIndex];
      final dist = metersBetween(me, next.position);
      setState(() => _distToNext = dist);
      // Hold off if we just fired one, so two nearby cues don't stack; the cue
      // stays "next" and fires on a later tick once the gap has passed.
      final settled = DateTime.now().difference(_lastFire) >= _minFireGap;
      if (dist <= next.radiusMeters && settled) {
        _nextIndex++;
        _fireCue(next);
        firedCue = true;
      }
    } else {
      setState(() => _distToNext = null);
    }

    // Off-route check against the drawn path (skipped on a tick that fired a
    // cue). Announcements are fire-and-forget so they never block updates.
    if (!firedCue && widget.trail.path.length >= 2) {
      final d = distanceToPath(me, widget.trail.path);
      if (!_offRoute && d > _offRouteMeters) {
        _offRoute = true;
        setState(() {
          _offRouteCardShown = true;
          _activeCard = null;
        });
        _announceOffRoute();
      } else if (_offRoute && d < _backOnRouteMeters) {
        _offRoute = false;
        setState(() => _offRouteCardShown = false);
        _speak('You are back on the trail');
      }
    }
  }

  void _fireCue(Cue cue) {
    _lastFire = DateTime.now();
    setState(() {
      _activeCard = cue;
      _offRouteCardShown = false;
    });
    _buzz();
    if (cue.spoken.trim().isNotEmpty) _speak(cue.spoken);
    // Passing a node may flip a dual marker to its return direction.
    _drawCues();
    _writeCheckpoint();
  }

  void _announceOffRoute() {
    _buzz(long: true);
    _speak('You are off the trail. Turn around to get back on the trail.');
  }

  Future<void> _speak(String text) async {
    _lastSpoken = text;
    if (mounted) setState(() {});
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> _buzz({bool long = false}) async {
    if (await Vibration.hasVibrator()) {
      Vibration.vibrate(duration: long ? 900 : 400);
    }
  }

  RouteLayer? _routeLayer;

  Future<void> _onMapCreated(MapLibreMapController c) async => _c = c;

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null) return;
    _routeLayer = RouteLayer(c);
    await _routeLayer!.ensure();
    await _routeLayer!.setRoute(widget.trail.path, widget.trail.color);
    await _drawCues();
  }

  /// Draws the cue markers, each labelled with its stack position so the map
  /// reads consistently with the cue list. Cues sharing (almost) the same
  /// spot stay at that one spot — drawn as a single marker in a distinct
  /// "stacked" colour, with every cue in the stack listed on its own line
  /// (e.g. "2. Go right" / "8. Go left" / "15. Go straight") so it's obvious
  /// several cues live there without splitting them apart on the map.
  Future<void> _drawCues() async {
    final c = _c;
    if (c == null) return;
    await c.clearSymbols();
    await c.clearCircles();

    // _cues is already sorted by order — that sort position is the display
    // rank, always a clean 1..N regardless of gaps in the raw order values.
    final rank = <Cue, int>{for (var i = 0; i < _cues.length; i++) _cues[i]: i + 1};
    final groups = <List<Cue>>[];
    for (final cue in widget.trail.cues) {
      final match = groups
          .where((g) => metersBetween(g.first.position, cue.position) < 1.0);
      if (match.isNotEmpty) {
        match.first.add(cue);
      } else {
        groups.add([cue]);
      }
    }

    for (final group in groups) {
      final stacked = group.length > 1;
      if (stacked) group.sort((a, b) => rank[a]!.compareTo(rank[b]!));
      final pos = group.first.position;
      await c.addCircle(CircleOptions(
        geometry: pos,
        circleRadius: stacked ? 13 : 11,
        circleColor: stacked ? stackedCueColorHex : cueColorHex(group.first.type),
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: stacked ? 4 : 3,
      ));
      await c.addSymbol(SymbolOptions(
        geometry: pos,
        textField: group.map((cue) => '${rank[cue]}. ${cue.label}').join('\n'),
        textSize: 15,
        textColor: '#1a1a1a',
        textHaloColor: '#ffffff',
        textHaloWidth: 2,
        textAnchor: 'top',
        textOffset: const Offset(0, 1.1),
      ));
    }
  }

  Region get _region => regionById(widget.trail.regionId);

  CameraPosition get _initialCamera {
    // Resuming a checkpoint centres on where the walk actually was, not the
    // trailhead.
    final target = widget.resume?.lastPos ??
        (widget.trail.path.isNotEmpty ? widget.trail.path.first : _region.center);
    return CameraPosition(target: target, zoom: 16);
  }

  Future<void> _recenter() async {
    setState(() => _follow = true);
    // Jump straight to the last known position instead of waiting for the next
    // GPS tick; fall back to a fresh fix if we don't have one yet.
    final here = _lastPos ??
        await Geolocator.getCurrentPosition().then(
            (p) => LatLng(p.latitude, p.longitude),
            onError: (_) => null);
    if (here != null) await _c?.animateCamera(CameraUpdate.newLatLng(here));
    await _c?.animateCamera(CameraUpdate.bearingTo(0));
    await _c?.animateCamera(CameraUpdate.tiltTo(0));
  }

  /// Banks this outing into the trail's lifetime totals and logs it as an
  /// Activity. Runs once (guarded), ignoring trivially short sessions. Returns
  /// the saved activity (or null when nothing was banked).
  Future<Activity?> _saveWalk() async {
    if (_walkSaved) return null;
    _walkSaved = true;
    final id = widget.trail.id;
    // Any path that reaches here — Stop or the dispose() backstop — means
    // this walk session is over one way or another, so whatever checkpoint
    // exists is stale from this point on.
    if (id != null) await TrailStore.instance.clearWalkCheckpoint(id);
    if (_walkMeters < 20) return null; // accidental open / barely moved
    if (id != null) {
      await TrailStore.instance.recordWalk(id, _walkMeters, _elevGain);
    }
    await Settings.instance.addWalk(_walkMeters, _elevGain);
    return TrailStore.instance.addActivity(Activity(
      trailId: id,
      trailName: widget.trail.name,
      startedAt: _startedAt ?? DateTime.now(),
      durationSec: _elapsedSec,
      distanceMeters: _walkMeters,
      elevGainMeters: _elevGain,
      track: List.of(_track),
    ));
  }

  Future<void> _stop() async {
    final activity = await _saveWalk();
    if (!mounted) return;
    if (activity == null) {
      Navigator.pop(context);
      return;
    }
    // Replace the walk screen with its summary; Done there returns home.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ActivityDetailScreen(activity: activity, justFinished: true),
      ),
    );
  }

  @override
  void dispose() {
    _saveWalk(); // backstop for the system back button
    _posSub?.cancel();
    _debugTick?.cancel();
    _checkpointTimer?.cancel();
    _tts.stop();
    _watchdog.dispose();
    if (identical(NativeBridge.onAcknowledgeStillness, _acknowledgeStillness)) {
      NativeBridge.onAcknowledgeStillness = null;
    }
    if (identical(NativeBridge.onPauseWalk, _pauseWalk)) {
      NativeBridge.onPauseWalk = null;
    }
    if (identical(NativeBridge.onResumeWalk, _resumeWalk)) {
      NativeBridge.onResumeWalk = null;
    }
    NativeBridge.cancelNudgeNotification();
    NativeBridge.stopTracking();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stillnessVisible = _watchdog.phase != StillnessPhase.normal;
    final cardVisible =
        _offRouteCardShown || _activeCard != null || stillnessVisible;
    // Height (above the safe-area bottom) reserved by the banner/strip so the
    // side buttons never sit on top of it. Measured in the same SafeArea space
    // as the banner itself, so it stays consistent whether or not the Android
    // nav bar is showing.
    final reservedBottom = cardVisible ? 118.0 : 112.0;

    return Scaffold(
      // Order matters: the map is at the back, then the bottom banner, then the
      // side buttons, and finally the top bar — drawn last so its Stop button
      // (the way back to the trail list) can never be covered by anything.
      body: Stack(
        children: [
          BaseMap(
            region: _region,
            initialCamera: _initialCamera,
            onMapCreated: _onMapCreated,
            onStyleLoaded: _onStyleLoaded,
            myLocationEnabled: true,
            trackCameraPosition: true,
          ),

          // Bottom "next cue" strip (hidden while a big card is up). Bounded by
          // an explicit Positioned so it can only ever be as tall as its
          // content — never a full-screen wash over the map.
          if (!cardVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _NextCueStrip(
                  nextCue: _nextIndex < _cues.length ? _cues[_nextIndex] : null,
                  distance: _distToNext,
                  onSkip: _nextIndex < _cues.length ? _skipCue : null,
                ),
              ),
            ),

          // Recenter (also faces north + flattens). Sits above the banner,
          // sharing the banner's SafeArea so it clears the Android nav bar too.
          Positioned(
            right: 16,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: reservedBottom),
                child: FloatingActionButton(
                  heroTag: 'recenter',
                  onPressed: _recenter,
                  child: const Icon(Icons.my_location),
                ),
              ),
            ),
          ),

          // Persistent "repeat last direction" button (big target, left side).
          if (_lastSpoken != null && !cardVisible)
            Positioned(
              left: 16,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: reservedBottom),
                  child: FloatingActionButton.extended(
                    heroTag: 'repeat',
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    onPressed: () => _speak(_lastSpoken!),
                    icon: const Icon(Icons.volume_up, size: 28),
                    label: const Text('Repeat', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ),
            ),

          // The big cue card / off-route card / stillness-alert overlay.
          if (_offRouteCardShown)
            BigActionCard(
              color: const Color(0xFFC62828),
              icon: Icons.u_turn_left,
              text: 'Off the trail\nTurn around',
              onRepeat: _announceOffRoute,
              onDismiss: () => setState(() => _offRouteCardShown = false),
            )
          else if (_activeCard != null)
            BigActionCard(
              color: cueColor(_activeCard!.type),
              icon: cueIcon(_activeCard!.type),
              text: _activeCard!.spoken.trim().isEmpty
                  ? _activeCard!.label
                  : _activeCard!.spoken,
              onRepeat: () => _speak(_activeCard!.spoken.trim().isEmpty
                  ? _activeCard!.label
                  : _activeCard!.spoken),
              onDismiss: () => setState(() => _activeCard = null),
            )
          else if (stillnessVisible)
            _stillnessCard(),

          // Top status strip — anchored to the top and drawn last so Stop is
          // always tappable (guaranteed route back to the trail list).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _TopBar(
                title: widget.trail.name,
                walking: _status == 'Walking',
                paused: _paused,
                statusText: _status,
                elapsedSec: _elapsedSec,
                meters: _walkMeters,
                elevGain: _elevGain,
                onStop: _stop,
                onPauseResume: _paused ? _resumeWalk : _pauseWalk,
                debugText: _debugText(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact one-line stillness-watchdog readout for the debug overlay
  /// (phase / accumulated still time / GPS fix freshness / accuracy / anchor
  /// resets so far) — see Settings.debugStillness. Null when the toggle is off.
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

  Widget _stillnessCard() {
    switch (_watchdog.phase) {
      case StillnessPhase.nudged:
        return BigActionCard(
          color: const Color(0xFFF57F17),
          icon: Icons.pause_circle_outline,
          text: "Haven't moved in a while.\nStill there?",
          dismissIcon: Icons.check_circle,
          dismissTooltip: "I'm OK",
          onRepeat: () => _speak(Settings.instance.sendEmergencySms.value
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
          onRepeat: () => _speak('Sending an alert to your emergency contact.'),
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
              _speak('An alert was sent to your emergency contact.'),
          onDismiss: _acknowledgeStillness,
        );
      case StillnessPhase.normal:
        return const SizedBox.shrink();
    }
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.walking,
    required this.paused,
    required this.statusText,
    required this.elapsedSec,
    required this.meters,
    required this.elevGain,
    required this.onStop,
    required this.onPauseResume,
    this.debugText,
  });

  final String title;
  final bool walking;
  final bool paused;
  final String statusText;
  final int elapsedSec;
  final double meters;
  final double elevGain;
  final VoidCallback onStop;
  final VoidCallback onPauseResume;
  final String? debugText;

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                if (!walking)
                  Text(statusText,
                      style:
                          const TextStyle(fontSize: 13, color: Colors.black54))
                else if (paused)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.pause_circle_filled,
                            size: 18, color: Color(0xFFF57F17)),
                        const SizedBox(width: 6),
                        Text('Paused — ${Settings.formatDuration(elapsedSec)}',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFF57F17))),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 2,
                      children: [
                        _stat(Icons.timer_outlined,
                            Settings.formatDuration(elapsedSec)),
                        _stat(Icons.straighten, s.formatDistance(meters)),
                        _stat(Icons.speed, s.formatPace(meters, elapsedSec)),
                        _stat(Icons.trending_up, s.formatElevation(elevGain)),
                      ],
                    ),
                  ),
                if (debugText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(debugText!,
                        style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: Colors.deepOrange)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (walking)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: paused
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFFF57F17),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                onPressed: onPauseResume,
                icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 22),
                label: Text(paused ? 'Resume' : 'Pause',
                    style: const TextStyle(fontSize: 15)),
              ),
            ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            onPressed: onStop,
            icon: const Icon(Icons.stop, size: 22),
            label: const Text('Stop', style: TextStyle(fontSize: 15)),
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.black54),
        const SizedBox(width: 3),
        Text(text,
            style:
                const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _NextCueStrip extends StatelessWidget {
  const _NextCueStrip(
      {required this.nextCue, required this.distance, this.onSkip});

  final Cue? nextCue;
  final double? distance;

  /// Advances past this cue without firing it — for a resumed walk that
  /// landed at a slightly-off position where a cue (or several) genuinely
  /// already passed. Null (no button shown) when there's no next cue.
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final cue = nextCue;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
      ),
      child: cue == null
          ? const Text('Follow the trail',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center)
          : Row(
              children: [
                Icon(cueIcon(cue.type), size: 44, color: cueColor(cue.type)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Next',
                          style: TextStyle(fontSize: 15, color: Colors.black54)),
                      Text(cue.label,
                          style: const TextStyle(
                              fontSize: 26, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                if (distance != null)
                  Text(Settings.instance.formatDistance(distance!),
                      style: const TextStyle(
                          fontSize: 30, fontWeight: FontWeight.bold)),
                if (onSkip != null)
                  IconButton(
                    tooltip: 'Skip this cue',
                    onPressed: onSkip,
                    icon: const Icon(Icons.skip_next),
                  ),
              ],
            ),
    );
  }
}

