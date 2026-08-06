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
import '../services/crash_log.dart';
import '../services/cue_gen.dart';
import '../services/geo.dart';
import '../services/native_bridge.dart';
import '../services/route_layer.dart';
import '../services/settings.dart';
import '../services/stillness_watchdog.dart';
import '../services/trail_router.dart';
import '../services/trail_store.dart';
import '../widgets/base_map.dart';
import '../widgets/big_action_card.dart';
import 'activity_detail_screen.dart';

/// The cue to actually show, speak, and colour for [cue] on the return leg
/// (see [_GuideScreenState._turnBack]): [cue] itself, unchanged, unless it's
/// a left/right cue and the walker has turned back — in which case this
/// returns a brand-new [Cue] of the *opposite* type at the same spot, so its
/// icon, colour, label, and spoken phrase all come from that type's own
/// canonical definition (`CueType.label`/`defaultSpoken`) together, as one
/// consistent unit.
///
/// This replaced two rounds of trying to edit the original cue's *wording*
/// in place (matching against today's default text, then a regex word-swap)
/// — both left real bugs, because a cue's saved text and its type can drift
/// out of sync in ways that are hard to fully predict. Building a fresh cue
/// straight from the reversed type sidesteps that entirely: there's nothing
/// to get out of sync. The trade-off is that any custom wording the trail's
/// author wrote (e.g. "at the big oak tree") isn't carried over — there's no
/// reliable way to un-say a custom forward-direction phrase for the opposite
/// direction, so this intentionally falls back to the type's plain default
/// phrasing instead, which is always correct.
Cue effectiveCue(Cue cue, bool turnedBack) {
  if (!turnedBack || (cue.type != CueType.left && cue.type != CueType.right)) {
    return cue;
  }
  return Cue(
    type: reversedCueType(cue.type),
    position: cue.position,
    order: cue.order,
    radiusMeters: cue.radiusMeters,
  );
}

/// The three ways a walker can bail out partway through a walk — see
/// [_GuideScreenState._openBailOutMenu].
enum _BailOutMode { reverse, toStart, toRoad }

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

  /// Set once the walker bails out via any of the three Turn-back options
  /// (see [_openBailOutMenu]) — hides the Turn-back button (one-way for the
  /// rest of this walk) regardless of which option they picked. The saved
  /// [Trail] itself is never touched by any of the three, so a later normal
  /// walk of it is unaffected.
  bool _turnedBack = false;

  /// True only for the "reverse course" option — the other two bail-out
  /// options install a freshly computed route with its own freshly
  /// generated cues (see [_installComputedRoute]), already correctly
  /// oriented for walking it start-to-end, so they must NOT go through the
  /// left/right flip below a second time.
  bool _reverseDirectionSwap = false;

  /// A second, distinctly-coloured route line for the "shortest way back to
  /// start" / "nearest road" bail-out options — kept separate from
  /// [_routeLayer] (which keeps showing the original trail, greyed) so both
  /// can be on screen together. Lazily created only if one of those options
  /// is actually used.
  RouteLayer? _escapeRouteLayer;

  /// The path the off-route check compares against — null (meaning
  /// [Trail.path]) until a computed escape route is installed, from then on
  /// that route's own path.
  List<LatLng>? _activePath;

  /// The cue to actually show/speak/colour for [cue] — see [effectiveCue].
  /// [Cue.type] on the *original* objects in [_cues]/[Trail.cues] is never
  /// mutated: [_drawCues]'s completed-marker lookup depends on those staying
  /// the same shared identity, so only the rendered/spoken representation
  /// swaps, never the underlying data.
  Cue _shown(Cue cue) => effectiveCue(cue, _reverseDirectionSwap);

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
    ).listen(_onPosition, onError: _onPositionError);
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
    _toast('Skipped: ${_shown(skipped).label}');
    _drawCues(); // grey out the skipped marker immediately
    _writeCheckpoint();
  }

  /// Opens the three bail-out choices, then confirms and executes whichever
  /// one is picked. Reached from the Turn-back button — hidden once
  /// [_turnedBack] regardless of which option was used, since all three are
  /// one-way for the rest of this walk.
  Future<void> _openBailOutMenu() async {
    final mode = await showModalBottomSheet<_BailOutMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('How do you want to get back?',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.u_turn_left, color: Color(0xFF795548)),
              title: const Text('Reverse course'),
              subtitle: const Text('Retrace your steps exactly back to the start.'),
              onTap: () => Navigator.pop(ctx, _BailOutMode.reverse),
            ),
            ListTile(
              leading: const Icon(Icons.near_me, color: Color(0xFFE91E63)),
              title: const Text('Shortest way back to start'),
              subtitle: const Text(
                  "Find the quickest mapped path back to the trailhead — "
                  "may not be the way you came."),
              onTap: () => Navigator.pop(ctx, _BailOutMode.toStart),
            ),
            ListTile(
              leading: const Icon(Icons.directions_car_outlined, color: Color(0xFFE91E63)),
              title: const Text('Nearest road'),
              subtitle: const Text('Find the quickest mapped path out to the nearest road.'),
              onTap: () => Navigator.pop(ctx, _BailOutMode.toRoad),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (mode != null) await _confirmBailOut(mode);
  }

  /// Confirms the chosen option — irreversible for this walk, so worth a
  /// deliberate second tap rather than a single accidental one — then runs it.
  Future<void> _confirmBailOut(_BailOutMode mode) async {
    final (String title, String body) = switch (mode) {
      _BailOutMode.reverse => (
          'Turn back to the start?',
          'This reverses your remaining cues so they guide you back the '
              'way you came, and cancels the cues still ahead of you. '
              "This can't be undone for this walk."
        ),
      _BailOutMode.toStart => (
          'Find the shortest way back?',
          'This finds the quickest mapped path back to the trailhead — it '
              "may not be the path you walked in on. This can't be undone "
              'for this walk.'
        ),
      _BailOutMode.toRoad => (
          'Exit to the nearest road?',
          'This finds the quickest mapped path out to the nearest road, '
              "whichever direction that is. This can't be undone for this "
              'walk.'
        ),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true) return;
    switch (mode) {
      case _BailOutMode.reverse:
        _reverseCourse();
      case _BailOutMode.toStart:
        await _routeToStart();
      case _BailOutMode.toRoad:
        await _routeToNearestRoad();
    }
  }

  /// Bails out of the rest of the trail and heads back to the start: the
  /// cues already fired become the walk's new (and only) remaining cues, in
  /// reverse order, so they fire correctly heading the other way; every cue
  /// still ahead is dropped for the rest of this walk. Runtime-only — see
  /// [_turnedBack].
  void _reverseCourse() {
    final passed = _cues.sublist(0, _nextIndex);
    setState(() {
      _cues
        ..clear()
        ..addAll(passed.reversed);
      _nextIndex = 0;
      _turnedBack = true;
      _reverseDirectionSwap = true;
      _activeCard = null;
    });
    _toast('Turned back — guiding you to the start');
    _drawCues();
    _writeCheckpoint();
  }

  /// Computes the shortest mapped path from here back to the trail's start
  /// point — not necessarily retracing the walked path — and installs it as
  /// the walk's new route. Falls back to [_reverseCourse] with a plain
  /// explanation if no mapped route can be found (off the edge of the
  /// downloaded map area, or genuinely no connected trail/road nearby).
  Future<void> _routeToStart() async {
    final pos = _lastPos;
    final c = _c;
    final start = widget.trail.path.isNotEmpty ? widget.trail.path.first : null;
    if (pos == null || c == null || start == null) {
      _toast("Couldn't find a mapped route — reversing your course instead");
      _reverseCourse();
      return;
    }
    final connection = await TrailRouter(c).connect(from: pos, to: start);
    if (!connection.followed) {
      _toast("Couldn't find a mapped route back to the start — "
          'reversing your course instead');
      _reverseCourse();
      return;
    }
    await _installComputedRoute(connection.polyline,
        toast: 'Guiding you the shortest way back to the start');
  }

  /// Computes the shortest mapped path from here to the nearest point
  /// classified as a road — whichever direction that is — and installs it
  /// as the walk's new route. Same not-found fallback as [_routeToStart].
  Future<void> _routeToNearestRoad() async {
    final pos = _lastPos;
    final c = _c;
    if (pos == null || c == null || !mounted) {
      _toast("Couldn't find a mapped route — reversing your course instead");
      _reverseCourse();
      return;
    }
    final size = MediaQuery.of(context).size;
    final connection = await TrailRouter(c).nearestRoad(
      from: pos,
      viewport: Rect.fromLTWH(0, 0, size.width, size.height),
    );
    if (connection == null) {
      _toast("Couldn't find a nearby road — reversing your course instead");
      _reverseCourse();
      return;
    }
    await _installComputedRoute(connection.polyline,
        toast: 'Guiding you the shortest way to the nearest road');
  }

  /// Shared by [_routeToStart]/[_routeToNearestRoad]: draws [path] as a
  /// second, distinctly-coloured route line (the original trail's line
  /// greys out rather than disappearing, so it's clear it's no longer the
  /// active route), and replaces the walk's cues with freshly generated
  /// turn-by-turn cues for this new path — already correctly oriented for
  /// walking it start-to-end, so unlike [_reverseCourse] these must NOT go
  /// through the left/right swap (see [_reverseDirectionSwap]).
  Future<void> _installComputedRoute(List<LatLng> path, {required String toast}) async {
    final c = _c;
    if (c == null) return;
    await _routeLayer?.setRoute(widget.trail.path, '#9E9E9E');
    _escapeRouteLayer ??= RouteLayer(c, id: 'escape-route');
    await _escapeRouteLayer!.ensure();
    await _escapeRouteLayer!.setRoute(path, '#E91E63');
    final cues = suggestCues(path);
    setState(() {
      _cues
        ..clear()
        ..addAll(cues);
      _nextIndex = 0;
      _turnedBack = true;
      _activeCard = null;
      _activePath = path;
      _offRoute = false;
      _offRouteCardShown = false;
    });
    _toast(toast);
    _drawCues();
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
    try {
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
    } catch (e, st) {
      // A transient disk/sqflite error here shouldn't take down an in-progress
      // walk — it just means this particular checkpoint write is lost; the
      // next periodic write (or the final save on Stop) tries again.
      CrashLog.log('Checkpoint write', e, st);
    }
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

    // Off-route check against whichever path is actually active — the
    // trail's own drawn path normally, or a computed escape route once one
    // has been installed (see _installComputedRoute); otherwise a walker
    // correctly following a "shortest way back" route that legitimately
    // leaves the original trail would be endlessly told they're off-trail.
    // Skipped on a tick that fired a cue. Announcements are fire-and-forget
    // so they never block updates.
    final activePath = _activePath ?? widget.trail.path;
    if (!firedCue && activePath.length >= 2) {
      final d = distanceToPath(me, activePath);
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

  /// Handles a stream *error* from the position stream — as opposed to a
  /// position update — which `.listen(_onPosition)` alone would otherwise
  /// leave uncaught (Dart rethrows an unhandled stream error as an async
  /// exception with nowhere to go). On a real trail this is a real
  /// condition, not a hypothetical: GPS/location-services can genuinely drop
  /// out under tree cover or in a canyon, or location permission can be
  /// revoked mid-walk. Keeps the walk alive rather than crashing — the
  /// stream itself keeps listening for a position once the underlying
  /// condition clears.
  void _onPositionError(Object error, StackTrace stack) {
    CrashLog.log('Position stream', error, stack);
    if (!mounted) return;
    final String msg;
    if (error is LocationServiceDisabledException) {
      msg = 'Location services turned off — turn them back on to keep tracking.';
    } else if (error is PermissionDeniedException) {
      msg = 'Location permission was lost — re-grant it to keep tracking.';
    } else {
      msg = 'Lost GPS signal — trying to reconnect…';
    }
    setState(() => _status = msg);
    _toast(msg);
  }

  void _fireCue(Cue cue) {
    _lastFire = DateTime.now();
    setState(() {
      _activeCard = cue;
      _offRouteCardShown = false;
    });
    _buzz();
    final spoken = _shown(cue).spoken;
    if (spoken.trim().isNotEmpty) _speak(spoken);
    // Passing a node may flip a dual marker to its return direction.
    _drawCues();
    _writeCheckpoint();
  }

  void _announceOffRoute() {
    _buzz(long: true);
    _speak('You are off the trail. Turn around to get back on the trail.');
  }

  /// Wraps flutter_tts calls, which can throw/reject on devices with no TTS
  /// engine installed or a broken default voice — a real condition on older
  /// phones, and one that would otherwise be an unhandled async exception
  /// (every call site here is fire-and-forget from a stream/timer callback,
  /// not awaited by its caller).
  Future<void> _speak(String text) async {
    _lastSpoken = text;
    if (mounted) setState(() {});
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

  /// Grey used for cues already passed (fired or manually skipped) — clearly
  /// distinct from every real cue-type/stacked colour, so completed vs.
  /// upcoming is obvious on the map at a glance without needing to compare
  /// numbers, and stays legible whether resuming a walk or checking progress
  /// after a run of skips.
  static const _completedColorHex = '#9E9E9E';

  /// Bumped on every [_drawCues] call and checked between each await inside
  /// it — see that method's doc for why.
  int _drawGeneration = 0;

  /// Draws the cue markers, each labelled with its stack position so the map
  /// reads consistently with the cue list. Cues sharing (almost) the same
  /// spot stay at that one spot — drawn as a single marker in a distinct
  /// "stacked" colour, with every cue in the stack listed on its own line
  /// (e.g. "2. Go right" / "8. Go left" / "15. Go straight") so it's obvious
  /// several cues live there without splitting them apart on the map. Cues
  /// already passed (index < _nextIndex — fired naturally or skipped) draw
  /// grey instead of their normal colour; a stacked spot only greys out once
  /// every cue there is done.
  ///
  /// This is called from several places in quick succession — firing a cue,
  /// skipping one, turning back — each a separate un-awaited async call, so
  /// two calls can genuinely overlap (e.g. a cue fires right as the walker
  /// taps Turn back); [_drawGeneration] makes every call check, after each
  /// await, whether a newer call has since started, stopping immediately
  /// instead of racing a newer call to the finish and drawing stale markers
  /// after it.
  ///
  /// Circles and symbols are each added in one batched `addCircles`/
  /// `addSymbols` call rather than one-at-a-time in the loop below — the
  /// underlying plugin rebuilds that whole layer's GeoJSON source on *every*
  /// individual `addCircle`/`addSymbol` call, not incrementally, and text
  /// layout (glyph shaping + collision) is far more expensive to redo than a
  /// plain circle repaint. Looping calls one at a time — as this used to —
  /// meant the symbol layer's string of full-source rebuilds could still be
  /// catching up after the circle layer's had already finished, which reads
  /// as exactly "the marker colours updated but the text didn't" (map
  /// correct on next redraw, but wrong at the moment it mattered). Batching
  /// to one rebuild each removes that gap entirely.
  Future<void> _drawCues() async {
    final c = _c;
    if (c == null) return;
    final myGeneration = ++_drawGeneration;
    await c.clearSymbols();
    await c.clearCircles();
    if (myGeneration != _drawGeneration) return;

    // _cues is already sorted by order — that sort position is the display
    // rank, always a clean 1..N regardless of gaps in the raw order values.
    // After a turn-back (see [_turnedBack]), _cues only holds the return
    // leg's cues, so a cue can genuinely have no rank at all — one that was
    // cancelled outright rather than merely not-yet-reached; it displays the
    // same as "completed" (grey, unnumbered) either way.
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

    final circleOptions = <CircleOptions>[];
    final symbolOptions = <SymbolOptions>[];
    for (final group in groups) {
      final stacked = group.length > 1;
      if (stacked) {
        group.sort((a, b) => (rank[a] ?? 1 << 30).compareTo(rank[b] ?? 1 << 30));
      }
      final completed =
          group.every((cue) => (rank[cue] ?? _nextIndex) <= _nextIndex);
      final pos = group.first.position;
      circleOptions.add(CircleOptions(
        geometry: pos,
        circleRadius: stacked ? 13 : 11,
        circleColor: completed
            ? _completedColorHex
            : (stacked ? stackedCueColorHex : cueColorHex(_shown(group.first).type)),
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: stacked ? 4 : 3,
      ));
      // One symbol per cue rather than one joined multi-line symbol for a
      // stack — multi-line text field rendering has proven fragile here (a
      // combined "1. Start\n6. Finish" label could end up not drawing at
      // all), where plain single-line labels have been reliable. Each line
      // gets its own vertical offset so a stack still reads as one list.
      for (var i = 0; i < group.length; i++) {
        final cue = group[i];
        symbolOptions.add(SymbolOptions(
          geometry: pos,
          textField: '${rank[cue] ?? "–"}. ${_shown(cue).label}',
          textSize: 15,
          textColor: completed ? '#757575' : '#1a1a1a',
          textHaloColor: '#ffffff',
          textHaloWidth: 2,
          textAnchor: 'top',
          textOffset: Offset(0, 1.1 + i * 0.95),
        ));
      }
    }

    if (myGeneration != _drawGeneration) return;
    if (circleOptions.isNotEmpty) await c.addCircles(circleOptions);
    if (myGeneration != _drawGeneration) return;
    if (symbolOptions.isNotEmpty) await c.addSymbols(symbolOptions);
    // Cue markers can legitimately sit close together along a trail (a tight
    // switchback, several turns down one short block). MapLibre's symbol
    // layer defaults to hiding a label outright rather than showing two that
    // collide — fine for a general map's clutter, wrong for markers we
    // deliberately placed and numbered; a hidden "3. Turn left" reads as
    // exactly the "the dots lost their labels" bug this addresses. A no-op
    // after the first successful call (checked internally by the plugin).
    if (myGeneration != _drawGeneration) return;
    await c.setSymbolTextAllowOverlap(true);
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
                  rank: _nextIndex < _cues.length ? _nextIndex + 1 : null,
                  onSkip: _nextIndex < _cues.length ? _skipCue : null,
                  turnedBack: _turnedBack,
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
            Builder(builder: (context) {
              final shown = _shown(_activeCard!);
              final text = shown.spoken.trim().isEmpty ? shown.label : shown.spoken;
              return BigActionCard(
                color: cueColor(shown.type),
                icon: cueIcon(shown.type),
                text: text,
                onRepeat: () => _speak(text),
                onDismiss: () => setState(() => _activeCard = null),
                number: _cues.indexOf(_activeCard!) + 1,
              );
            })
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
                onTurnBack: _turnedBack ? null : _openBailOutMenu,
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
    this.onTurnBack,
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

  /// Null hides the button — used once the walker has already turned back
  /// (one-way for the rest of this walk, per design).
  final VoidCallback? onTurnBack;
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
          if (walking && onTurnBack != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: 'Turn back to the start',
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF795548),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 12),
                    minimumSize: Size.zero,
                  ),
                  onPressed: onTurnBack,
                  child: const Icon(Icons.u_turn_left, size: 22),
                ),
              ),
            ),
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
      {required this.nextCue,
      required this.distance,
      this.rank,
      this.onSkip,
      this.turnedBack = false});

  final Cue? nextCue;
  final double? distance;

  /// Shows this cue's direction-flipped type/text instead of its stored
  /// one — see [effectiveCue].
  final bool turnedBack;

  /// This cue's 1-based position in the trail's stack order, matching the
  /// number on its map marker — so it's obvious which cue you're looking at
  /// (or about to skip) when checking against the map, especially after
  /// resuming a walk or skipping several in a row.
  final int? rank;

  /// Advances past this cue without firing it — for a resumed walk that
  /// landed at a slightly-off position where a cue (or several) genuinely
  /// already passed. Null (no button shown) when there's no next cue.
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final cue = nextCue;
    final shown = cue == null ? null : effectiveCue(cue, turnedBack);
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
      ),
      child: shown == null
          ? const Text('Follow the trail',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center)
          : Row(
              children: [
                Icon(cueIcon(shown.type), size: 44, color: cueColor(shown.type)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rank == null ? 'Next' : 'Next · #$rank',
                          style: const TextStyle(
                              fontSize: 15, color: Colors.black54)),
                      Text(shown.label,
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

