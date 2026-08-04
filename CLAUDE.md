# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RadarMap (Xcode project name; product name "RadarMap", bundle `uz.radarmap.ios`) is a native iOS speed-camera map + voice anti-radar navigator for Uzbekistan. SwiftUI, no third-party dependencies — only Apple frameworks (MapKit, CoreLocation, CoreMotion, AVFoundation, CoreHaptics, ActivityKit, WidgetKit, MetricKit, CarPlay, WatchConnectivity, AppIntents). It also ships a CarPlay navigator scene and an Apple Watch companion (`RadarWatch`). Paired with a self-hosted VPS backend (camera DB, OSRM routing, speed limits, crowdsourcing API).

**Language convention:** all code comments, user-facing strings, and git commit messages are in Russian. `README.md` is the fullest overview (in Russian). Match this when writing new code, strings, and commits. User-facing text goes through `String(localized:)` and the `Shared/Localizable.xcstrings` catalog (ru + uz); the app also exposes an in-app RU/UZ language override (`AppSettings`).

**`ARCHITECTURE.md`** (Russian) is the companion to this file: it states the layering (MV, no ViewModels) and the 12 coding/review rules the project is written against (errors never swallowed, constants in `AppConfig`, UserDefaults only via `Storage`, network only via `APIClient`, heavy work only via `@concurrent`, …). Read it before non-trivial changes.

## Build, test, run

Single-scheme project (`RadarMap`). Four targets: the app (which also hosts the CarPlay scene), `RadarMapWidgets` (Live Activity + home widget), `RadarWatch` (watchOS companion, deploys **watchOS 11.0**), and `RadarMapTests` (XCTest). App + widgets deploy to **iOS 18.0**; the test target and project baseline are iOS 26.2. `DEVELOPMENT_TEAM = AT27NPXG3V`.

**Use the `mcp__xcode__*` tools for everything Xcode-related — building, tests, previews, build logs, diagnostics, and project-file edits. They are the only supported build/test path for this project — do not use `xcodebuild` or other CLI tools.** They drive the already-open Xcode instance, so they reuse its build state and are far faster on the iterative loop. If Xcode is not running, open the project in Xcode first rather than reaching for a CLI build.

**Every `mcp__xcode__*` tool takes a `tabIdentifier`.** Call `mcp__xcode__XcodeListWindows` once at the start of a session to get it (it also reports the active scheme and run destination), then reuse that identifier for all subsequent calls.

Build & diagnostics:
- `mcp__xcode__BuildProject` — build the active scheme and wait for completion.
- `mcp__xcode__GetBuildLog` — read the current/last build log; filter by `severity` (`error`/`warning`/`remark`, default `error`), `pattern` (regex over messages/commands), or `glob` (paths). Triage build failures with this instead of scraping raw output.
- `mcp__xcode__XcodeListNavigatorIssues` — issues currently in Xcode's Issue Navigator (build errors, package-resolution/workspace problems).
- `mcp__xcode__XcodeRefreshCodeIssuesInFile` — live compiler diagnostics (errors/warnings/notes) for a single file without a full build.

Tests (run against the active scheme's active test plan):
- `mcp__xcode__GetTestList` — discover tests; the full grep-friendly list is written to `fullTestListPath` (grep by `TEST_TARGET` / `TEST_IDENTIFIER` / `TEST_FILE_PATH`).
- `mcp__xcode__RunAllTests` — run the whole plan.
- `mcp__xcode__RunSomeTests` — run specific tests; build each specifier from the `targetName` + `identifier` fields returned by `GetTestList` (e.g. target `RadarMapTests` with identifier `GeoMathTests` for a class, or `GeoMathTests/testBearingCardinalDirections` for one test).

Previews & snippets:
- `mcp__xcode__RenderPreview` — build and snapshot a `#Preview`/`PreviewProvider` by `sourceFilePath` + zero-based `previewDefinitionIndexInFile`; can override preview variants.
- `mcp__xcode__RunCodeSnippet` — build and run a Swift snippet in a source file's context (sees its `fileprivate` decls); returns `print` output. Useful for quickly exercising pure geometry/store helpers.

Docs & project files:
- `mcp__xcode__DocumentationSearch` — semantic search of Apple Developer Documentation (optionally scoped to frameworks).
- `mcp__xcode__Xcode{Read,Write,Update,MV,RM,MakeDir,Glob,Grep,LS,GetCurrentFile}` operate on the **Xcode project organization**. Prefer `XcodeWrite`/`XcodeMV`/`XcodeRM`/`XcodeMakeDir` when adding, moving, or deleting source files: they update the `.xcodeproj` and target membership automatically, which plain filesystem edits do not. For pure text edits to files already in the project, the regular Read/Edit tools are fine.

For actually launching and driving the app on the simulator (interacting with the UI, capturing runtime logs, inspecting on-screen state) — which the `mcp__xcode__*` tools do not cover — use the `ios-debugger-agent` skill.

Tests are deliberately narrow: pure geometry, scoring, and store logic (`GeoMathTests`, `RouteGeometryTests`, `SpeedLimitTests`, `TripTrackTests`, `DrivingScoreTests`, `CameraStoreTests`) — no UI or network. A repo-checked-in Claude Code skill, **`/quality`** (`.claude/skills/quality`), runs a full pre-release quality pass (architecture, code review, battery, localization, build + tests). Note `CameraStoreTests` shares one `CameraStore` across the run (deallocating a `@MainActor` class mid-test crashes the runtime) and persists to Documents/UserDefaults, so it scrubs prior artifacts in `freshStore()`.

## Architecture

### Dependency injection
`AppEnvironment` (`App/AppEnvironment.swift`) is the composition root — a single `@MainActor @Observable` object, `AppEnvironment.shared`, built once and shared by the phone SwiftUI scene *and* the CarPlay scene (CarPlay may connect before the SwiftUI scene). Injected via SwiftUI `.environment(...)`, read with `@Environment(AppEnvironment.self)`. It owns every service and **wires cross-service callbacks in its `init`** (e.g. `MotionService.onDrivingStart` → start trip; `RouteService.onManeuver` → speak). To understand how a feature is triggered end-to-end, read this `init` first — the services themselves are decoupled and only know about closures.

### Concurrency model
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES` (Swift 5 language mode). Nearly everything is implicitly `@MainActor`. Because approachable concurrency turns on `NonisolatedNonsendingByDefault`, a plain `nonisolated async` runs on the **caller's** actor — so `Task { await Self.heavy() }` from the main actor stays on main. To actually get off main, heavy work is marked **`@concurrent`** (see `CameraRepository` DB decode, `JSONFile`); stateless utilities (`Log`, `JSONFile`) are `nonisolated enum` so a call from `@concurrent` code doesn't hop back to main. Pure geometry helpers are `nonisolated static`; some still run via `Task.detached` (`RouteService.apply` cameras-along-route, `SpeedLimitService`). `CLLocationManagerDelegate` callbacks are `nonisolated` and hop to `@MainActor` via `Task { @MainActor in ... }`. (See ARCHITECTURE.md rule 11.)

### The heart: `LocationService`
This is the most important and most complex file. It runs **two GPS modes**, selected centrally in `applyLocationMode()`:
- **Silent background** — significant-location-change + up to 20 `CLCircularRegion` geofences (iOS hard limit) around the nearest cameras; the system wakes the app on region entry → local notification. Near-zero battery.
- **Trip mode** (`startTrip`/`endTrip`) — continuous high-accuracy GPS with active alerts even when backgrounded (requires "Always" auth). Auto-started/stopped by `MotionService` (CoreMotion) when `settings.autoStartTrip`.

The escalation and radar-style measurement logic has been extracted into two **pure, tested `nonisolated struct`s** in `Services/` that `LocationService` orchestrates: `AlertEngine` (escalating approach thresholds 1–3 with hysteresis; `effectiveRadius` is the "smart radius" — warn N seconds out, not fixed meters) and `PassTracking` (records the minimum speed in an 80 m measurement zone at the traverse point of each camera, radar-style). `LocationService` itself still owns the directional filter (only warn about cameras ahead within ±70° of course — `isAhead`), adaptive accuracy (relax GPS when far from cameras/maneuvers — `tuneAdaptiveAccuracy`), and CoreHaptics escalation via `AlertPlayer.haptic(level:)`. Speed-limit matching and route progress are driven from here (not the UI) so voice keeps working when backgrounded.

### `RouteService` — routing (own engine)
Apple Maps does not route inside Uzbekistan, so `calculate()` tries `MKDirections` first and falls back to the **self-hosted OSRM server**. Produces engine-agnostic `Variant`s (each with cameras-along-route count and turn-by-turn `RouteStep`s). Live progress (`updateProgress`, called per GPS tick) handles arrival detection, next-camera/next-maneuver, voice maneuver staging, and off-route reroute (with GPS-noise confirmation ticks + cooldown). All the geometry (`project`, `camerasAlong`, `traveledPrefix`) is `nonisolated static` and runs off-main.

### `CameraStore` (`CameraRepository`) — data
Merged set = bundled `Resources/cameras.json` + user-added `custom` + crowdsourced `mobile` − `hiddenIDs`. Two caches invalidated together in `dataChanged()`: a `mergedCache` list and a **grid spatial index** (0.05° ≈ 5.5 km cells) so `nearest(to:)` and `cameras(in:)` never scan all ~3300 cameras on the hot path (retile fires every ~1.5 km driven). `revision` increments on any change; UI observes it. OTA updates (`applyRemote`) validate, atomically write to `Documents/cameras_remote.json`, and swap in memory; the downloaded copy survives app updates and is preferred over the bundled DB on next launch.

### Other services
- `RemoteSyncService` — daily OTA check of the camera DB against the server version.
- `MobileCameraService` — crowdsourced mobile-radar reports; polls every 3 min in foreground only; anonymous device UUID.
- `SpeedLimitService` — matches OSM `maxspeed` for the current road (position + course), warns on overspeed with a tolerance; ~3 MB DB, indexed for microsecond per-tick matching.
- `AlertPlayer` — preloaded beep + `AVSpeechSynthesizer` (plays over silent mode, ducks other audio) **plus CoreHaptics**: `haptic(level:)` fires a distinct pattern per alert level instead of one generic buzz.
- `WatchBridgeService` — pushes the trip HUD (speed, next-camera, alert level) to `RadarWatch` over `WatchConnectivity`; the watch escalates with wrist haptics.
- `FeedbackService` — in-app feedback form submission (see `Features/Settings/FeedbackFormView`).
- `CameraDirection` — "smart direction to camera": prefers the route heading, falls back to a smoothed course, with a wide dead zone to avoid flip-flopping.
- `LiveActivityService` / `MetricsService` (MetricKit) / `NotificationService` (one updatable notification per trip, not a stack).

### Configuration
**`Support/AppConfig.swift` is the single source of truth for all tunable constants** — alert radii, timings, map zoom/clustering thresholds, directional angles, reroute tuning, and server URLs. Change behavior here, not scattered across files. Server base is `syncBaseURL` (currently `http://45.130.148.94:8090`; OSRM at `/osrm`) — TODO before App Store: domain + HTTPS.

The rest of `Support/` enforces the ARCHITECTURE.md rules and is where the shared plumbing lives, so use it rather than reinventing:
- **`APIClient`** — the only place that touches the network (base URL, per-request/resource timeouts, status check, JSON en/decode, logging). Services describe *what* they want, not *how* to make the request.
- **`Storage`** — typed `UserDefaults` access; every key is a case in one enum, no raw string keys in code. `AppSettings` is the one exception (its own typed `Keys` façade).
- **`Log`** — `os.Logger` split by subsystem (`Log.alerts`, `Log.sync`, …); a `nonisolated enum` so `@concurrent` code can log without hopping to main. Errors are logged, never silently `try?`-swallowed.
- **`JSONFile`** — atomic JSON read/write off-main; **`Concurrency`**, **`Formatting`**, **`GeoMath`** — small stateless helpers. `Extensions/SwiftUI/SwiftUIBackports.swift` holds iOS 18 fallbacks for iOS 26 APIs.

### UI
The app follows **MV (Model–View), not MVVM** — there are no ViewModel layers. Views read `@Observable` models/services directly; per-screen UI state lives in an `@Observable` **screen-state model** (e.g. `MapState`, which does buffered annotation loading + clustering to keep panning smooth), which owns screen state but does not format data for the view. `RootView` gates onboarding → `MapScreen`, and drives foreground/background GPS mode from `scenePhase`. Features are organized by folder under `Features/` (Map, Search, Trip, Settings, Onboarding). Dark-only ("radar detector" aesthetic) — `.preferredColorScheme(.dark)`, styled via `DesignSystem/` (`Theme`, `Components`, plus `StatTile`, `SpeedLimitSign`, `ShareCardShell`, `TripMapSnapshot`).

### Trip domain & «Итоги» (post-trip summary)
Trip analytics live in `Models/`, not in views (ARCHITECTURE.md rule "data in the model"): `TripRecord` (one saved trip), `TripHistory` (rolling history), `TripStats` (aggregates + track simplification), and `DrivingScore` — which also holds `FineSchedule` (Uzbekistan overspeed fines in BRV), `LifetimeStats`, and `Achievement`. All the math is `nonisolated static` and unit-tested (`DrivingScoreTests`). The «Итоги» screens under `Features/Trip/` (`TripStatsSheet`, `TripStatsCards`, `TripDetailSheet`, `TripHistorySection`, `SpeedProfileChart`, `PassMapSheet`, `StatsInfoSheets`) render a driving rating, real fines-based savings ("штрафы за 30 дней"), streaks, per-camera pass speeds, and shareable cards. `ReviewPromptModifier` drives the App Store review prompt.

### CarPlay & Apple Watch
`CarPlay/` (`CarPlaySceneDelegate`, `CarPlayMapScreen`, `CarPlayMapView`) is a full navigator scene — camera map, speed HUD, alerts, quick "where to" routing. The phone scene and CarPlay share one composition root via `AppEnvironment.shared` (CarPlay can connect before the SwiftUI scene comes up). `RadarWatch/` (`RadarWatchApp`, `WatchHUDView`, `WatchSession`) is a watchOS companion showing the trip HUD with escalating wrist haptics, fed by `WatchBridgeService` over `WatchConnectivity`.

### Widgets & sharing
`RadarMapWidgets` (Live Activity in Dynamic Island + home stats widget). Shared code lives in `Shared/`: `CameraActivityAttributes` (Live Activity contract) and `SharedDefaults` (App-Group `UserDefaults` snapshot for the home widget). **Gotcha:** App Groups are currently disabled in both `.entitlements` files (free Apple ID limitation), and `SharedDefaults.appGroup` (`group.test.RadarMap`) does not match the commented-out entitlement group (`group.uz.radarmap.ios`) — the home widget's shared data is effectively inert until a paid account re-enables App Groups and the IDs are reconciled.

## Backend

The VPS itself is provisioned separately (nginx, Docker, cron), but the app-facing backend code now lives in **`server/`** (deployed with `deploy_api.sh`):
- `api.py` — the crowdsourcing/metrics/feedback API: stdlib-only (`sqlite3` + `http.server`), listens on `127.0.0.1:8091`, exposed by nginx at `:8090/api/`. Mobile-radar reports merge via up/down **votes** (`/api/report`, `/api/vote`) with per-device caps against ID rotation; markers are rate-limited and TTL'd. `test_api.py` covers it.
- `snap_cameras.py` — offline pass that snaps the ~3341 camera coordinates from data.egov.uz to the OSM road axis **by matching road name** (not just nearest road, to avoid moving a camera onto a parallel street); outputs land in `server/snap/`.

The VPS also serves the camera DB and speed-limit files (nginx :8090) and runs OSRM in Docker (CH algorithm, `--mmap`) on an Uzbekistan OSM graph. Cron jobs refresh the camera DB nightly from data.egov.uz (sha256-idempotent) and the road graph + speed limits monthly.
