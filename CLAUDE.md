# CLAUDE.md — TrailGuide ("APS Trails")

Offline hiking-trail app for the user's parents (Lower Mainland BC). Flutter +
MapLibre GL + Protomaps `.pmtiles` vector tiles, fully offline-capable
(bundled/downloaded region tiles, no network needed on a walk). Android is the
only shipped target; Windows desktop build exists but is secondary.

## Environment & tool paths (Windows)

Do not guess these — verified paths for this machine:

- Flutter SDK: `F:\dev\flutter` (on PATH as `flutter`/`flutter.bat`)
- Android SDK: `C:\Users\Ryan\AppData\Local\Android\Sdk` (i.e. `$LOCALAPPDATA\Android\Sdk`)
- `aapt.exe` (for verifying a built APK's versionCode/versionName): pick the
  newest folder under `$LOCALAPPDATA/Android/Sdk/build-tools/` — currently
  `37.0.0`. Example:
  `"$LOCALAPPDATA/Android/Sdk/build-tools/37.0.0/aapt.exe" dump badging build/app/outputs/flutter-apk/app-release.apk`
- Dart SDK: embedded inside the Flutter SDK.
- GitHub publish token: `TrailGuide\.release_token` (gitignored, plain-text
  PAT). Read it, don't ask the user for a fresh one unless a curl call comes
  back 401 (token revoked).
- Repo remote: `https://github.com/Nien098/aps-trails-upd-h4k9m2q.git`, branch
  `main`.
- Shell: this session runs the Bash tool (Git Bash), not PowerShell — use
  POSIX syntax (`$VAR`, forward slashes) even though the OS is Windows.

## Core commands

- Analyze (always run before shipping, compare against baseline below):
  `flutter analyze` (whole project) or `flutter analyze lib/` (skip the one
  stale test file)
- Build release APK: `flutter build apk --release --build-name=X.Y.Z --build-number=N`
  — **always pass both `--build-name`/`--build-number` explicitly**, matching
  whatever was just written to `pubspec.yaml`'s `version:` line. Takes
  ~75-90s; run it with `run_in_background: true` and keep working/reply while
  it builds rather than blocking on it.
- Run tests: `flutter test` — **expect one pre-existing failure**
  (`test/widget_test.dart` references a nonexistent `MyApp` class, unrelated
  stale boilerplate, not a real regression).
- Format: `dart format .`
- Clean: `flutter clean && flutter pub get` — slow, only use when something's
  genuinely stuck (stale build cache, plugin registration issue), not as a
  routine step.

## `flutter analyze` baseline — memorize this, don't re-diagnose it

Every clean run of `flutter analyze` on this codebase reports exactly these
4 pre-existing, harmless items (line numbers drift as files are edited, that's
normal and not a signal of anything):
1. 3× `unintended_html_in_doc_comment` in `lib/models/region.dart` (angle
   brackets in a doc comment being read as HTML — cosmetic only)
2. 1× `use_build_context_synchronously` in `lib/screens/author_screen.dart`
   (a genuine minor async/BuildContext lint, never fixed, never blocking)

`flutter analyze` (no path, whole project) additionally shows a 5th item: the
`test/widget_test.dart` `MyApp` error above — that's `test/`, not `lib/`, and
unrelated to app code.

**After any edit, only investigate NEW issues beyond this exact set of 4/5.**
Don't re-verify or explain away the baseline every time — it's expected.

## Release workflow (version bump → build → ship)

This is the established, repeatable pattern — follow it exactly, don't
improvise a different flow:

1. Bump `pubspec.yaml`'s `version: X.Y.Z+N` (bump `N` by 1 per shipped build;
   `X.Y.Z` rarely changes).
2. `flutter build apk --release --build-name=X.Y.Z --build-number=N` in the
   background.
3. Verify the built APK's actual versionCode with `aapt.exe dump badging`
   (path above) — don't just trust the bump, confirm it landed.
4. `git add` the specific changed files (never `-A`/`.`), commit with a
   message ending in `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
5. `git tag X.Y.Z+N && git push origin main && git push origin X.Y.Z+N`.
6. Create a GitHub Release via the API (not `gh`, this repo uses direct curl
   + the PAT): write a small JSON body (`tag_name`, `name`, `body`,
   `draft:false`, `prerelease:false`) to a scratchpad file, `curl -X POST` to
   `https://api.github.com/repos/Nien098/aps-trails-upd-h4k9m2q/releases`,
   grab the returned release `id`.
7. Upload the APK as a release asset: `curl -X POST` with
   `Content-Type: application/vnd.android.package-archive` and
   `--data-binary @build/app/outputs/flutter-apk/app-release.apk` to
   `.../releases/<id>/assets?name=app-release.apk`. This upload is slow
   (~150-290MB) — run it `run_in_background: true` too, don't block the turn
   on it. Confirm `"state":"uploaded"` and that `size` matches the local
   build.
8. The app has its own in-app GitHub-Releases-based updater
   (`lib/services/updater.dart`) — this is how the user actually receives
   builds, there is no Play Store distribution.

Don't skip steps 3 or the final upload-size check — a half-uploaded or
wrong-versionCode release has bitten this project before.

## Architecture map (where things live)

- `lib/services/trail_router.dart` — the routing/snapping engine. Builds an
  in-memory graph (`_Graph`/`_Seg`) from whatever trail/road vector features
  are currently rendered on screen (`queryRenderedFeaturesInRect` — **only
  sees what's actually rendered in the current viewport**, a recurring
  source of bugs when a caller queries too small/wrong an area). Exposes:
  `connect()`/`between()` (tap-to-tap routing, real pathfinding, can produce
  detours — used by "Follow trails" draw mode), `snapPoint()`/`snapStroke()`
  (pure local nudge, no pathfinding — used by record-mode cleanup and
  drag-draw tracing), `generate()` (auto-generate a route from the visible
  network, with boundary-polygon and coverage-walk padding support).
- `lib/screens/author_screen.dart` — the trail editor. Owns `_trail.anchors`
  (sparse, user-facing waypoints) and `_segments` (dense per-anchor-hop
  coordinate arrays — this is the actual editable geometry). Three drawing
  modes, mutually exclusive (activating one force-clears the other two's
  mode flags — don't add a fourth without doing the same, or its icon can
  get stuck showing "active"): tap-to-tap (`_addAnchor`), drag-trace
  (`_dragDrawMode`), and grab-and-bend (`_adjustLineMode`, pure geometric
  Gaussian-falloff deformation, no trail lookups — see `_deformSegment`).
  `_densify()` keeps every segment's vertices ≤8m apart so edits stay local.
  `_composePath()` flattens `_segments` back into `_trail.path` for
  rendering/saving. Undo (`_pushUndo`/`_undo`) is a snapshot stack of
  `_EditSnapshot` (anchors + segments + cues), pushed immediately before
  every geometry-mutating action — not just the tap-to-tap draw path, so a
  cue edit, a drag-draw commit, or a line-nudge is just as undoable as a
  drawn point. `_DrawGestureSurface` is the shared widget behind the
  boundary/drag-draw/line-adjust tools' full-screen drag overlay — see the
  gotchas below for why it exists instead of a plain `GestureDetector`.
- `lib/services/geo.dart` — shared geometry math (`metersBetween`,
  `nearestPointOnPath`/`nearestPointOnPolyline`, `distanceToPath`,
  `simplifyPath` Douglas-Peucker, `_projectOntoSegment` private per-file).
- `lib/services/route_layer.dart` / `boundary_layer.dart` — thin GeoJSON
  source/layer wrappers around `MapLibreMapController`. `RouteLayer.setRoute`
  is vertex-count-agnostic — always draws a smooth LineString regardless of
  how dense the input array is, so densifying editable geometry never makes
  the visible line look different.
- `lib/screens/record_trail_screen.dart` — GPS-track recording; cleanup
  (`_cleanPath`) snaps each simplified point individually (`snapPoint`, no
  routing between points) — this was deliberately changed away from
  `connect()`-style routing because routing between distant recorded points
  could jump onto a wrong/unrelated nearby trail.
- `lib/screens/guide_screen.dart` — turn-by-turn walking mode (TTS + cues),
  crash/pause-resume via `WalkCheckpoint`.
- `lib/services/offline_map.dart`, `pmtiles_writer.dart`,
  `region_downloader.dart` — offline `.pmtiles` handling: bundled regions,
  downloading new ones, and writing on-device PMTiles v3 from an online
  download.
- `lib/services/trail_store.dart` — SQLite persistence (sqflite), versioned
  schema migrations.
- `lib/services/native_bridge.dart` + `android/.../TrackingService.kt` —
  platform channel to a foreground Android service for background GPS
  tracking, stillness-nudge SMS, notification actions.
- `lib/services/cue_gen.dart` — auto turn-cue generation from a path
  (degree-of-turn heuristic; junction-awareness/"stay straight" cues at real
  crossroads is a known, explicitly deferred gap).
- `assets/style/style.json` — Protomaps' official light theme, adapted for
  offline fonts/pmtiles URL. Don't hand-roll style changes without checking
  this is still based on the upstream theme.

## Hard-won gotchas (don't re-discover these)

- **Screen-pixel vs logical-pixel mismatch**: `toScreenLocation`,
  `queryRenderedFeaturesInRect`, and `toLatLng` all operate in the MapView's
  native device pixels — NOT Flutter's logical/dp pixels from
  `MediaQuery.of(context).devicePixelRatio` — a `GestureDetector`'s
  `localPosition` must be multiplied by `devicePixelRatio` before passing to
  `controller.toLatLng(Point(...))`. Getting this wrong silently
  shrinks/offsets results toward one corner instead of erroring.
- **`queryRenderedFeaturesInRect` only sees currently-rendered geometry** —
  if a caller needs a feature far outside the current camera view, either
  move the camera first or pass a `seedPath`/wider query rect. This has been
  the root cause of several "can't find a route back to X" bugs.
- **A Flutter-side `CustomPaint` overlay does not reliably render live on
  top of MapLibre's native Android platform view.** For any live drag
  preview, push updates through an actual map GeoJSON layer instead (see how
  `BoundaryLayer`/the `strokePreview` `RouteLayer` instance are used) — this
  was tried the other way first and silently failed to update during a drag.
- **Routing/pathfinding (`connect()`/`between()`) vs. pure local snap
  (`snapPoint()`/`snapStroke()`) are deliberately different tools.** Routing
  can produce a real detour when data has a gap or an out-and-back trail's
  two legs are mapped close together (wrong-leg jumps). Anywhere the goal is
  "nudge this point onto the trail without guessing a path," use the local
  snap family, not routing — this distinction has been the subject of
  multiple rounds of bug reports when conflated.
- **Editing-tool "ripple"/bounding logic must ultimately be bounded by real
  geometry (real anchors, real influence radius), not just algorithmic
  heuristics like a step-count cap** — several iterations of the line-adjust
  tool looked locally correct in code review but still misbehaved on real
  out-and-back trails until the underlying editable array itself was made
  dense (`_densify`, ~8m spacing) and the deformation model switched to pure
  geometric falloff (no trail graph queries at all) rather than
  snap-then-ripple.
- **`testWidgets`'s fake clock deadlocks against real `sqflite` DB I/O.** Use
  plain `test()` for logic that touches the real database; only use
  `testWidgets` for pure-UI tests that don't hit storage. (See
  `reference_flutter_widget_test_sqflite.md` in memory.)
- **Always bump `pubspec.yaml`'s build number before rebuilding a sideload
  APK**, even for a trivial change — same versionCode + same signature means
  some installers silently show "Open" instead of "Install" and the update
  never actually lands on the device.
- **A full-screen `HitTestBehavior.opaque` overlay stops a sibling
  `Listener` *underneath* it from ever seeing pointer events at all** —
  not just gesture-arena events, but raw signals like mouse-wheel scroll
  too. This is why each drawing tool's screen-covering drag-catcher (used
  to claim single-finger drag input for itself) silently broke
  `BaseMap`'s own wheel-zoom handling the moment any tool was turned on:
  the overlay wasn't competing for the gesture, it was hiding the map's
  `Listener` from hit-testing entirely. Fixed by giving the tool's own
  overlay (`_DrawGestureSurface`) an `onPointerSignal` handler that
  forwards scroll straight to `controller.animateCamera`, rather than
  relying on anything beneath it to see the event.
- **`BaseMap.gesturesEnabled = false` (used while a drawing tool is active,
  so a single-finger touch can't also drag/rotate the camera underneath the
  draw) disables *all* of MapLibre's native gestures, including two-finger
  pan/pinch** — there's no partial mode that keeps multi-touch camera
  control while blocking single-finger. Two-finger panning during
  drag-draw/line-adjust/boundary-draw is therefore hand-rolled in
  `_DrawGestureSurface`: it tracks active pointer count itself via
  `Listener.onPointerDown/Move/Up`, treats 1 pointer as the draw gesture and
  ≥2 as camera-pan (calling `CameraUpdate.scrollBy` directly), and abandons
  an in-progress single-finger draw the moment a second finger lands (no
  partial commit).
- **`CameraUpdate.scrollBy(dx, dy)`'s doc ("positive dx moves the camera
  target east") describes the opposite of what it does to the *visible
  content* on this map/platform combo in practice.** Confirmed on-device:
  to make the map content follow the fingers during a manual two-finger pan
  (natural touch-drag panning), pass the raw per-finger delta straight
  through — do **not** negate it, despite what the "moves the camera
  target" framing in the SDK doc would suggest. Also: `scrollBy`'s dx/dy
  are logical (dp) pixels, not native device pixels — unlike
  `toLatLng`/`toScreenLocation` elsewhere in this file, the Android side
  multiplies by density itself, so don't multiply by `devicePixelRatio`
  before passing it in.

## Code style actually used here (not generic Dart style guide filler)

- Doc comments explain **why**, not what — a hidden constraint, a prior bug
  this code avoids, a non-obvious tradeoff. Trivial comments restating the
  code are not the norm in this file set; match the existing density, don't
  under- or over-comment relative to it.
- No speculative abstractions "for later." Every layer/tool added this
  project cycle (BoundaryLayer, the second `RouteLayer` instance used for
  live preview, `_deformSegment`) was a direct, minimal answer to a specific
  reported problem, modeled structurally on an existing working pattern
  rather than invented fresh.
- `const` constructors, sound null safety, camelCase/PascalCase — standard
  Dart conventions, already consistently followed; no need to sweep-fix
  these unless touching that code anyway.

## Efficiency / working-agreement notes (the user has explicitly asked to minimize token spend)

- **Prefer real evidence over theorizing.** When a routing/rendering bug is
  unclear, decode/inspect the actual data (real `.pmtiles` vector tiles, a
  real screenshot, a real `flutter analyze` run) rather than iterating on
  guesses. This project has working precedent for reassembling and decoding
  the bundled `.pmtiles` archive in Python when needed.
- **Match verification effort to actual risk.** A 4-line trivial fix doesn't
  need a full analyze/build/emulator cycle; a routing/geometry change that's
  already burned multiple rounds of real-device bug reports does.
- **This project has no local emulator-based verification loop in practice**
  — the user tests every build on their own real Android device and reports
  back with screenshots. Don't spin up an emulator "to check" unless
  specifically useful; `flutter analyze` + a successful `flutter build apk`
  is the realistic ceiling of what can be verified without the user.
- **Batch independent background work**: version bump → build (background)
  → continue talking/summarizing while it runs → verify versionCode → git
  commit/tag/push → GitHub release create → APK upload (background) is the
  established rhythm; don't block a turn waiting on a build/upload that's
  already running in the background.
- **Persistent memory**: this project already has several memory files
  tracked outside this repo (project_trailguide.md and
  reference_trailguide_*.md) — check those for context on decisions made in
  prior sessions (e.g. safety/background-tracking timing, updater
  mechanics, region-download pipeline) before re-deriving them.
