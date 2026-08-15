# CLAUDE.md — TrailGuide ("APS Trails")

Offline hiking-trail app for the user's parents (Lower Mainland BC), now also
being tested by the user's brother in the Jakarta/Tangerang area of Indonesia.
Flutter + MapLibre GL + Protomaps `.pmtiles` vector tiles, fully
offline-capable (bundled/downloaded region tiles, no network needed on a
walk). Android is the only shipped target; Windows desktop build exists but
is secondary.

## Current state (as of v1.5.0+134)

Beyond the original trail-drawing/walking app, this project now also has:
offline street/trail search (`SearchService`), a view-only "Browse Map" mode,
map bookmarks (pin/categorize/jump to spots, with real icons on the map —
see `bookmark.dart`/`bookmark_layer.dart`), point-to-point offline walking
directions (`NavigateScreen`, phase 1 of turn-by-turn nav — walking-only,
with a "stick to roads" toggle, no vehicle-routing data), and — the big one
— a bundled, offline, region-wide **routing graph** (`RouteGraphStore`) that
upgrades trail-drawing/generation/bail-out routing from "only sees what's
currently rendered on screen" to "sees the whole downloaded/bundled area."

On top of that, `region_downloader.dart` has been substantially reworked
this cycle (see **Search & routing infrastructure** below for the Overpass
side and **PMTiles tile reuse & region merge** for the tile side): the flat
per-cell-skip Overpass strategy became adaptive/recursive cell subdivision,
and a whole new `PmTilesReader` (mirroring the existing `PmTilesWriter`)
now lets downloads/updates reuse already-downloaded tiles instead of
re-fetching them, and lets overlapping/adjacent downloaded regions merge
into one map instead of staying fragmented. Read **PMTiles tile reuse &
region merge** below before touching `pmtiles_reader.dart`,
`pmtiles_writer.dart`, or `region_downloader.dart`'s tile-fetch/merge logic
— this is hand-rolled binary format work with real, specific gotchas.

See **Search & routing infrastructure**, **PMTiles tile reuse & region
merge**, and **Known limitations / next steps** below for the full picture
— read those before touching any of `search_service.dart`,
`route_graph_store.dart`, `trail_router.dart`'s offline-merge code, or
`region_downloader.dart`, all of which have real, hard-won lessons baked in
already.

App size has grown substantially from these additions: bundled assets alone
are now ~337MB total (basemap + streets.sqlite + route_graph.sqlite, the last
of which is Git-LFS-tracked since it exceeds GitHub's 100MB per-file limit).
This is expected and was confirmed with the user at each size jump — don't
be alarmed by it, but do keep flagging *further* size jumps before bundling
more diagnostic/regional data (see below).

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
- **Git LFS is installed and configured** (`git lfs install` already run,
  `.gitattributes` tracks `assets/data/route_graph.sqlite`). That file is
  >100MB, over GitHub's hard per-file limit for normal git objects — if it
  (or any other bundled data asset) grows past ~100MB, `git lfs track` it
  *before* committing, or the push will be rejected outright (`GH001: Large
  files detected`). If a commit with an untracked huge file is made and
  rejected, the commit is still only local (never pushed) — safe to
  `git reset --soft HEAD~1`, `git lfs track` the path, re-add, and recommit
  clean rather than trying to rewrite history after the fact.
- Python (for `tools/build_streets_db.py`/`build_route_graph.py`): plain
  `python` on PATH, stdlib `sqlite3` module — already confirmed to have both
  FTS5 and R-tree compiled in on this machine, no extra install needed.

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

## Ship every app change by default — don't stop at local verification

Once a code/asset change in `lib/`, `assets/`, or `android/` is implemented
and locally verified (`flutter analyze` + a successful build), run the full
release workflow below through to completion (bump → build → verify
versionCode → commit/tag/push → GitHub release → upload) in the same
session — this is not a separate follow-up step that waits for the user to
say "ship it" or "release this." Local verification is step 2/3 of shipping,
not a stopping point. There is no Play Store; the in-app updater is the only
way the user's parents ever receive a build, so an unshipped change never
reaches them no matter how well it was verified locally.

Only skip shipping when the user explicitly says to hold off (e.g. "don't
ship yet," "just show me the diff first," mid-task exploratory changes not
meant to be real yet).

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
  in-memory graph (`_Graph`/`_Seg`, keyed by ~1m-rounded coordinate strings,
  not real OSM node IDs — connectivity is purely "shared/near-shared
  coordinates," see `_Graph._key`/`_mergeNearbyNodes`) from two merged
  sources: whatever trail/road vector features are currently rendered on
  screen (`queryRenderedFeaturesInRect`) **plus** the bundled/downloaded
  offline route graph (`RouteGraphStore.waysInBounds`, merged in via
  `_addFeaturesToGraph`'s `geoBounds` param — see **Search & routing
  infrastructure** below). Exposes: `connect()`/`between()` (tap-to-tap
  routing, real pathfinding, can produce detours — used by "Follow trails"
  draw mode), `snapPoint()`/`snapStroke()` (pure local nearest-edge nudge, no
  pathfinding — used by record-mode cleanup and drag-draw tracing; also
  merges offline data now, safe to do since there's no path-cost
  accumulation to go wrong the way Dijkstra can), `generate()` (auto-generate
  a route from the network, with boundary-polygon and coverage-walk padding
  support), `nearestRoad()`/`junctionsNear()`.
- `lib/screens/author_screen.dart` — the trail editor. Owns `_trail.anchors`
  (sparse, user-facing waypoints) and `_segments` (dense per-anchor-hop
  coordinate arrays — this is the actual editable geometry). Three drawing
  modes, mutually exclusive (activating one force-clears the other two's
  mode flags — don't add a fourth without doing the same, or its icon can
  get stuck showing "active"): tap-to-tap (`_addAnchor`), drag-trace
  (`_dragDrawMode`), and grab-and-bend (`_adjustLineMode`, pure geometric
  Gaussian-falloff deformation, no trail lookups — see `_deformSegment`).
  Anchors are also freely draggable *during* line-adjust mode (checked first
  in `_onAdjustPanStart`, before the mid-line search — see
  `_draggingAnchorIndex`/`_commitAnchorPosition`), not just via the older
  long-press → action-sheet → tap-to-place flow (`_placeMovingAnchor`, which
  now shares the same commit helper). `_densify()` keeps every segment's
  vertices ≤8m apart so edits stay local. `_composePath()` flattens
  `_segments` back into `_trail.path` for rendering/saving. Undo
  (`_pushUndo`/`_undo`) is a snapshot stack of `_EditSnapshot` (anchors +
  segments + cues), pushed immediately before every geometry-mutating
  action. `_DrawGestureSurface` is the shared widget behind the
  boundary/drag-draw/line-adjust tools' full-screen drag overlay — see the
  gotchas below for why it exists instead of a plain `GestureDetector`.
  `Scaffold(resizeToAvoidBottomInset: false)` — see gotchas.
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
  crash/pause-resume via `WalkCheckpoint`. Also has the search FAB (see
  below) and `resizeToAvoidBottomInset: false`.
- `lib/screens/browse_map_screen.dart` — new, view-only "Browse Map" mode
  (pan/zoom/search freely, no trail/edit context). Owns its own `Region`
  state and can swap basemaps on demand (unlike Guide/Author, which are tied
  to one trail's region) — the only screen where search is unconfined
  (`confineTo: null`).
- `lib/screens/region_picker_screen.dart` — full-screen area picker
  (replaced an app-bar dropdown that got cramped once downloaded regions
  piled up alongside the bundled ones).
- `lib/services/offline_map.dart`, `pmtiles_writer.dart`,
  `region_downloader.dart` — offline `.pmtiles` handling: bundled regions,
  downloading new ones, and writing on-device PMTiles v3 from an online
  download. `RegionDownloader.download()` also fetches street-name
  (`SearchService.addStreets`) and route-graph (`RouteGraphStore.addWays`)
  data for the downloaded bbox via tiled Overpass requests — see **Search &
  routing infrastructure** and **Known limitations** below, this has real
  caps/gotchas.
- `lib/services/trail_store.dart` — SQLite persistence (`sqflite`),
  versioned schema migrations. Trail data only — no FTS5/R-tree needed here,
  unlike the newer search/route-graph stores (see below), so `sqflite`
  (OS-provided SQLite) is fine for this one.
- `lib/services/native_bridge.dart` + `android/.../TrackingService.kt` —
  platform channel to a foreground Android service for background GPS
  tracking, stillness-nudge SMS, notification actions. Same pattern reused
  by `DownloadKeepAliveService.kt` (started for the duration of any region
  download/update via `NativeBridge.startDownloadKeepAlive`/
  `stopDownloadKeepAlive`) — without it, Android could suspend the isolate
  within seconds of the app being backgrounded or the screen locking
  mid-download, silently stalling a multi-minute download over a slow
  connection.
- `lib/services/cue_gen.dart` — auto turn-cue generation from a path
  (degree-of-turn heuristic; junction-awareness/"stay straight" cues at real
  crossroads is a known, explicitly deferred gap).
- `assets/style/style.json` — Protomaps' official light theme, adapted for
  offline fonts/pmtiles URL. Don't hand-roll style changes without checking
  this is still based on the upstream theme.
- `lib/models/region.dart` — `kRegions` is now just **2** bundled bookmarks
  (`vancouver_mainland`, `victoria`), merged down from an original 12
  separate Lower Mainland entries that all pointed at the same shared
  basemap file anyway (picking between them was more choice than the data
  supported). All bundled regions share one pmtiles (`kMapAsset`); only a
  user-*downloaded* region has its own separate `mapAsset`/pmtiles file —
  this distinction matters a lot for `BrowseMapScreen`'s basemap-swap logic
  and `SearchService`'s `confineTo` filtering (both keyed on `mapAsset`, not
  on region *name* — merging/renaming bundled regions doesn't invalidate
  anything already using `mapAsset` comparisons). Also has `regionForTrail(Trail)`
  — resolves a trail's region primarily by its stored `regionId`, falling
  back to geography (bbox containing the trail's own first point) when that
  id no longer matches any current region. Needed because a downloaded
  region's id isn't stable across delete+redownload (a fresh download always
  mints a new `dl_<timestamp>` id) — without this fallback, deleting and
  redownloading the same area silently orphaned every trail that pointed at
  the old id, dropping them onto the wrong (default bundled) basemap. Use
  this instead of `regionById(trail.regionId)` anywhere a `Trail` is in
  scope; `AuthorScreen`/`GuideScreen` additionally persist the correction
  back to `TrailStore` once found, so a trail "self-heals" on first open.
- `lib/models/bookmark.dart`, `lib/services/bookmark_layer.dart`,
  `lib/services/marker_icon_renderer.dart`, `lib/widgets/bookmark_edit_sheet.dart`,
  `lib/screens/bookmarks_screen.dart` — saved points of interest, independent
  of any trail. `BookmarkCategory` drives the marker's badge color;
  `Bookmark.icon` is a separately-chosen glyph (defaults to the category's,
  but freely overridable from a curated ~30-icon list, `kBookmarkIcons`) so
  a pin can actually look like the thing it marks. Map markers are real
  rendered icons, not colored dots — `marker_icon_renderer.dart` rasterizes
  (icon + colored circular badge) to a PNG via `dart:ui`, registered as a
  named map image (`MapLibreMapController.addImage`) and drawn as a
  `Symbol` annotation (the plugin's annotation API takes real images for
  icons, not Flutter widgets). Reachable from `BrowseMapScreen` (long-press
  to add / tap to act on a pin) and `AuthorScreen` (jump to a bookmark while
  editing). `AuthorScreen.initialCenter` lets "start a new trail here" (from
  a bookmark or a bare long-press) open the editor already centered on a
  specific spot instead of the region's generic bookmarked center.
- `lib/screens/navigate_screen.dart` — point-to-point walking directions:
  pick a start (defaults to GPS) and destination (search/bookmark/map tap),
  route via `TrailRouter.connect()` (the same real pathfinding "Follow
  trails" draw mode already uses, just for two arbitrary points), draw it
  with `RouteLayer`, then hand an ephemeral (`id: null`, never saved unless
  the walk is banked as an Activity) `Trail` with `cue_gen.dart`-generated
  cues straight to `GuideScreen` for turn-by-turn walking. Deliberately
  walking-only — no vehicle-routing data (no one-way/turn-restriction/speed
  tags) — with a "Stick to roads" toggle (`Surface.roads`) as a safety
  preference, not a driving-directions substitute. Reachable from
  `BrowseMapScreen`'s Directions FAB, which passes its *current* camera
  position through as `NavigateScreen.initialCamera` (it owns a separate
  map/camera, so without this it'd always open on the region's generic
  center instead of wherever the caller was actually looking).

## Search & routing infrastructure (added this project cycle)

Three bundled SQLite files under `assets/data/`, each with a matching
dev-time Python build script under `tools/` (Overpass-API-based, run
manually, never at app runtime):

- **`streets.sqlite`** (`tools/build_streets_db.py`) — street *names* only,
  one representative point per unique name, FTS5-indexed. Powers
  `SearchService`'s street search. Small (a few MB).
- **`route_graph.sqlite`** (`tools/build_route_graph.py`) — full road/trail/
  sidewalk *geometry* (every way, not deduped by name), R-tree-indexed for
  fast bbox lookups. Powers `RouteGraphStore`, merged into `TrailRouter`'s
  graph. Much bigger than the name index (full geometry, not one point) —
  this is the dominant driver of the app's ~337MB size.
- Both are opened via **`package:sqlite3`** (FFI, bundles its own native
  SQLite with FTS5 *and* R-tree compiled in), **not** `sqflite` — `sqflite`
  on Android talks to the OS-provided SQLite via platform channel, which
  frequently lacks these extensions (confirmed root cause of a real shipped
  bug: search silently spun forever on real devices because the FTS5 query
  threw and the UI never checked `snap.hasError`). Verify any *new* SQLite
  extension need the same way — don't assume by analogy, prove it (a quick
  `dart run` script against `package:sqlite3` directly is enough, no need
  for a full device build).
- Runtime services (`lib/services/search_service.dart`,
  `lib/services/route_graph_store.dart`) both follow the same
  copy-on-first-run pattern as `OfflineMap` — bundled asset → app documents
  dir, re-copied only if the file size changed (so an app update with a
  bigger bundled asset does trigger a re-copy automatically).
- `lib/widgets/map_search_bar.dart` — the actual search UI. **Not**
  `showSearch()`/`SearchDelegate`: that does a hard `Navigator.push` of an
  opaque route, which unmounts the map's native platform view entirely
  (confirmed — there's no way to keep the map visible underneath a
  `SearchDelegate`). Hand-rolled floating `Card` overlay instead, matching
  this app's existing floating-widget idiom (`_ModeBar`, `_Hint`). Also
  exports `jumpCamera()` — see gotchas for why the naive
  `animateCamera(newLatLngZoom(...))` isn't safe for a long-distance jump.
- Downloaded (non-bundled) regions get their own streets/route-graph data
  fetched live via `RegionDownloader.download()` at download/update time —
  tiled into a grid of Overpass requests (mirrors the dev-scripts' tiling).
  On a cell failure (504/timeout), `_fetchCellAdaptive` now recursively
  quarters that cell and retries the smaller pieces (down to a 0.05° floor,
  3 levels deep) instead of just skipping it — the fix for a dense area
  (Jakarta-scale) silently ending up with big data gaps even after real
  bytes downloaded. Governed by a single wall-clock budget (4 minutes,
  `_overpassTimeBudget`) rather than a cell-count cap — cell count stopped
  being meaningful once cells can subdivide — and that deadline is checked
  *during* `_postOverpass`'s own retry loop too, not just between cells
  (a slow/hanging/rate-limited request could otherwise burn most of the
  budget on its own; see Known limitations for how this was actually found).
  `RegionDownloader.streetsCoverage`/`routeGraphCoverage` (0.0-1.0, not a
  binary pass/fail) report how much of the requested area actually
  succeeded — `coverageWarning()` turns that into a user-facing message
  that distinguishes "0%, not available at all" from "73% complete."

## PMTiles tile reuse & region merge (added this project cycle)

Before this, every downloaded region got its own wholly separate
`.pmtiles` file, even when the area was already (fully or partially)
covered by the bundled map or another downloaded region — real reported
storage bloat and fragmentation (downloading just "Vancouver city"
produced its own small separate map even though the bundled
"Vancouver - Mainland" map already covered that area). Fixed with a
from-scratch, staged system:

- `lib/services/pmtiles_ids.dart` — the Hilbert-curve tile-id encoding,
  shared verbatim by the writer and reader so they can never silently
  drift apart (a divergence there is silent data corruption, not a crash).
- `lib/services/pmtiles_reader.dart` — reads tiles back out of an existing
  `.pmtiles` archive, mirroring `pmtiles_writer.dart`'s exact narrow shape
  (no internal/tile compression, MVT-only, no content-dedup — `open()`
  throws `FormatException` on anything else, never guesses). `getTile`/
  `hasTile`/`locate`/`readAt` for individual tiles, `listTileIds()` for a
  cheap directory-only presence enumeration (never touches the
  multi-hundred-MB tile-data region). Fully round-trip-tested against the
  writer (`test/pmtiles_roundtrip_test.dart`, including the large-archive
  root→leaf directory split case) before it was ever used against a real
  downloaded region's file. **The single trickiest bit to get right**,
  mirrored exactly from `PmTilesWriter._serialize()`: a directory entry's
  offset varint is `0` when byte-contiguous with the previous entry,
  otherwise `realOffset + 1` (the `+1` reserves `0` as an unambiguous
  sentinel) — get this backwards and every tile after the first
  non-contiguous jump decodes to the wrong byte range.
- `RegionDownloader._reuseCandidates()` — before fetching a tile, checks
  every already-on-disk archive whose bbox overlaps the requested area
  (this region's own current file first for an update — most
  authoritative — then other overlapping downloaded regions, then the
  bundled map last) and copies bytes straight from whichever has it
  instead of hitting the network. Presence is checked via each candidate's
  `listTileIds()` built into a `Set` once, not one file-seek per tile per
  candidate. This is why "Update this area" got much faster (it's
  essentially always 100% reusable, since it re-requests the exact same
  bbox under the exact same id) and why a fresh download over
  already-covered ground is now cheap too.
- **Region merge** (`download_region_screen.dart`): a new selection that
  overlaps or is near-adjacent (`RegionDownloader.bboxesOverlap`'s
  `tolerance` param — independently-drawn rectangles essentially never
  share an exact edge) to existing downloaded region(s) offers to merge
  instead of silently creating another separate file. Accepting widens the
  download to the union bbox (tile reuse above then transparently pulls
  whatever's already downloaded, so only genuinely new territory hits the
  network) and re-suggests a name from the union area's dominant place
  (`_suggestName`, see below). **Safety property**: the old region(s) are
  never touched until the new merged archive is verified — reopened with
  `PmTilesReader`, confirmed its tile count is at least as large as the
  biggest region being replaced — only then are the old regions removed
  and every trail that belonged to one of them reassigned to the new
  region's id directly (`_reassignTrails`, on top of `regionForTrail`'s
  geography fallback, which stays as a safety net regardless). A
  failed/incomplete merge leaves every existing separate map exactly as it
  was — nothing about this ever mutates an existing file in place or
  deletes anything before the replacement is confirmed good.
- `download_region_screen.dart`'s `_suggestName()` — auto-suggests a
  placeholder name for a new (or merged) download from the dominant place
  label already rendered on the live preview map within the bbox: queries
  `places_locality`/`places_region`/`places_country` style layers
  (`assets/style/style.json`) via `queryRenderedFeaturesInRect`, picks by
  highest `population_rank` (Protomaps' place-importance field), ties
  broken by distance to the bbox center. A plain editable text field
  pre-filled with the suggestion, so accepting it / tweaking it / replacing
  it outright are all just "type in the box" — no extra UI needed.
- **Deliberately deferred, not forgotten**: an explicit free-disk-space
  check before starting a merge (old file(s) + new file must coexist on
  disk simultaneously, same as a single-region update already implicitly
  requires) — no existing free-space API in this codebase to build on, and
  not essential to the core safety property above (verify-before-delete
  already guarantees old data is never lost even if a merge fails from
  running out of space partway through).

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
- **MapLibre's `animateCamera` does a Mapbox-style "flyTo" on Android for any
  long-distance + zoom-changing jump — it zooms OUT mid-transition** (an arc
  effect, inherited from Mapbox GL's algorithm). If the flight dips below
  wherever the offline data floor is (`BaseMap`'s `minMaxZoomPreference`
  starts at zoom 10; no tiles below it), you get real black frames — this
  bit the search "jump to result" feature (fine on GPS recenter, which never
  changes zoom/never moves far). Fix: `jumpCamera()` in
  `map_search_bar.dart` splits it into an instant `moveCamera` reposition
  (no flight) + a short local zoom-only `animateCamera` — by the time the
  animated step starts there's no ground distance left to arc over. Use this
  helper for any future long-distance camera jump; don't call
  `animateCamera(newLatLngZoom(...))` directly for one.
- **A `Scaffold`'s default `resizeToAvoidBottomInset: true` shrinks the body
  — and any live `MapLibreMap` filling it — every time the keyboard opens.**
  Resizing a native GL surface mid-frame causes visible
  flicker/black-frame/distortion, and separately, any `bottom:`-anchored
  `Positioned` widget (e.g. `author_screen.dart`'s `_ModeBar`) gets pushed up
  on top of whatever's near the keyboard instead of staying pinned under it.
  Every screen with a live map (`GuideScreen`, `AuthorScreen`,
  `BrowseMapScreen`) sets `resizeToAvoidBottomInset: false` — do the same on
  any new map screen with a text field that can summon the keyboard.
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
- **`List.cast<T>()` is a *lazy* cast — it does not check any element's
  type when called, only when something later actually iterates the
  result.** This was a real, shipped bug, not a hypothetical: Overpass
  can return a bare non-`Map` element in its `elements` array under load
  (confirmed — a dense/huge-area query is exactly where this is most
  likely), and `(jsonDecode(text)['elements'] as List).cast<Map>()` in
  `_postOverpass` let that malformed element sail through untouched —
  only to throw an *uncaught* exception later, deep inside
  `_fetchOverpassTiled`'s per-cell aggregation loop, discarding an entire
  in-progress route-graph fetch (real progress and all) and reporting
  "not available" with zero indication why. Fixed by eagerly filtering to
  genuine `Map` elements right after decoding, inside `_postOverpass`'s
  own try/catch, so a malformed element becomes "one fewer usable element
  this attempt" instead of a crash three call frames away with no
  diagnostic trail. If a future bug report describes a download reaching
  real progress and then failing with no obvious cause, check for this
  exact class of issue before anything else — look for a lazy
  `.cast<T>()`/`as T` sitting between where data is fetched and where it's
  actually consumed.
- **A generic `catch (_) { ... }` swallows the one clue that would explain
  an intermittent, hard-to-reproduce bug report.** The two `_downloadInner`
  catch blocks (streets/route-graph fetch) now call `CrashLog.log()` with
  the real exception + stack trace instead of silently eating it — this is
  exactly what let the `.cast<Map>()` bug above get root-caused from a real
  device's log instead of another round of guessing. `CrashLog.share()`
  (Settings → "Share diagnostics log") opens the OS share sheet with the
  local log file — ask for this before speculating further on a report
  that doesn't reproduce locally.
- **A download/update's progress dialog restarts each phase's percentage
  from 0% by design** (tile count, Overpass cell count, and bytes-copied
  are three incomparable scales — there's no honest single percentage
  spanning all of them) — but reported directly as "it reached 65% then
  reset to 17%," read as a real regression by someone only glancing
  occasionally rather than watching the phase label change. Fixed by
  showing "Step X of Y" (`DownloadProgress.step`/`totalSteps`, computed in
  `_downloadInner`) alongside the phase name — a change in *step number* is
  unmistakably a new phase, unlike a percent that can plausibly (if
  wrongly) look like it went backward. Any new phase added to the download
  pipeline needs its own step number threaded through, not just a new
  `phase:` string.

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

## Known limitations / next steps

- **Adaptive/recursive Overpass cell sizing is now built** (see **Search &
  routing infrastructure** above, `_fetchCellAdaptive`) — a cell that
  504s/times out gets quartered and retried smaller instead of just being
  skipped, down to a 0.05° floor, governed by a single 4-minute wall-clock
  budget rather than a flat cell-count cap. This replaced the original flat
  60-cell/45s caps, which were confirmed too coarse for a hyper-dense
  megacity (even a cell 1/36th the app's default 0.15° size reliably
  504-timed-out over central Jakarta). Even with adaptive sizing, a
  sufficiently large/dense/rate-limited area can still legitimately come
  back with partial (not 0%, not 100%) coverage — that's now reported
  honestly via `streetsCoverage`/`routeGraphCoverage` rather than hidden
  behind a binary pass/fail. If a report describes 0% coverage specifically
  (not partial), check `CrashLog` first (see the gotcha above) before
  assuming it's just density/rate-limiting — that combination is exactly
  what surfaced the `.cast<Map>()` bug.
- **`jakarta_metro_test` and `tangerang_test`** (in both
  `route_graph.sqlite` and `streets.sqlite`) are **diagnostic-only bundled
  data**, not real app regions — no `Region`/`kRegions` entry, no bundled
  basemap/pmtiles for them. They exist purely because `RouteGraphStore`/
  `SearchService` query by raw geographic bbox overlap, not by region
  name/id, so bundling extra data for an area works regardless of which
  *map* (the visual pmtiles) a user has separately downloaded there. Built
  with unbounded dev-time patience via `tools/build_route_graph.py`/
  `build_streets_db.py`'s `CELL_OVERRIDES` (0.05° cells for these two,
  vs. the default 0.15°/0.20°) — confirmed this is necessary, not
  optional, for this density. If asked to add more Indonesian coverage
  (Bogor, Bekasi, or the full Jabodetabek metro), **check real size first**:
  a small 0.10°×0.10° sample over central Jakarta alone produced 42k
  elements — the full Jabodetabek metro the user originally wanted would
  extrapolate to hundreds of MB, which is why the bundled area was
  deliberately shrunk to just the dense core instead. Always measure a
  small sample before committing to a large fetch+bundle, same as every
  other data-size decision in this project.
- **`tools/build_route_graph.py`/`build_streets_db.py` already tolerate
  permanently-failing cells** (soft-fail per cell, keep whatever succeeded —
  don't let one bad cell crash/lose an entire region's progress). If writing
  a *new* one-off data-fetch script for this project, copy that pattern
  rather than letting a single `raise` propagate up through the whole loop.
- App size trajectory this cycle, for reference if asked "why is the app so
  big now": ~281MB baseline (basemap + engine + native libs, already present
  before this cycle) → +1MB (streets.sqlite) → +131MB (route_graph.sqlite,
  bundled regions) → +17MB/+10MB (Jakarta/Tangerang route diagnostic data)
  → +1MB (Jakarta/Tangerang street diagnostic data) → **~337MB current**.
  Route graph geometry (not street names, not the basemap) is by far the
  biggest line item — keep that in mind before bundling more of it.

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
