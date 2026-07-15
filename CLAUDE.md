# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RadarMap (Xcode project name; product name "RadarMap", bundle `uz.rasul.radarmap`) is a native iOS speed-camera map + voice anti-radar navigator for Uzbekistan. SwiftUI, no third-party dependencies — only Apple frameworks (MapKit, CoreLocation, CoreMotion, AVFoundation, ActivityKit, WidgetKit, MetricKit). Paired with a self-hosted VPS backend (camera DB, OSRM routing, speed limits, crowdsourcing API).

**Language convention:** all code comments, user-facing strings, and git commit messages are in Russian. `README.md` is the fullest overview (in Russian). Match this when writing new code, strings, and commits. User-facing text goes through `String(localized:)` and the `Shared/Localizable.xcstrings` catalog (ru + uz).

## Build, test, run

Single-scheme project (`RadarMap`). Three targets: the app, `RadarMapWidgets` (Live Activity + home widget), `RadarMapTests` (XCTest). App + widgets deploy to **iOS 18.0**; the test target and project baseline are iOS 26.2. `DEVELOPMENT_TEAM = AT27NPXG3V`.

**Use the `mcp__xcode__*` tools for everything Xcode-related — building, tests, previews, build logs, diagnostics, and project-file edits. Always prefer them over `xcodebuild` or other CLI tools.** They drive the already-open Xcode instance, so they reuse its build state and are far faster than a cold `xcodebuild` on the iterative loop. Only fall back to `xcodebuild` (see the commands at the bottom of this section) when Xcode is not running or a needed tool is genuinely unavailable.

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

`xcodebuild` fallback only:

```bash
xcodebuild -scheme RadarMap -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme RadarMap -destination 'platform=iOS Simulator,name=iPhone 16' test
xcodebuild -scheme RadarMap -destination 'platform=iOS Simulator,name=iPhone 16' \
  test -only-testing:RadarMapTests/GeoMathTests/testBearingCardinalDirections
```

Tests are deliberately narrow: pure geometry and store logic (`GeoMathTests`, `RouteGeometryTests`, `SpeedLimitTests`, `TripTrackTests`, `CameraStoreTests`) — no UI or network. Note `CameraStoreTests` shares one `CameraStore` across the run (deallocating a `@MainActor` class mid-test crashes the runtime) and persists to Documents/UserDefaults, so it scrubs prior artifacts in `freshStore()`.

## Architecture

### Dependency injection
`AppEnvironment` (`App/AppEnvironment.swift`) is the composition root — a single `@MainActor @Observable` object built once in `RadarMapApp`, injected via SwiftUI `.environment(...)`, read with `@Environment(AppEnvironment.self)`. It owns every service and **wires cross-service callbacks in its `init`** (e.g. `MotionService.onDrivingStart` → start trip; `RouteService.onManeuver` → speak). To understand how a feature is triggered end-to-end, read this `init` first — the services themselves are decoupled and only know about closures.

### Concurrency model
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY` (Swift 5 language mode). Nearly everything is implicitly `@MainActor`. The pattern for heavy work: mark pure geometry helpers `nonisolated static` and run them off-main via `Task.detached` (see `RouteService.apply` computing cameras-along-route, and `CameraStore.decodeDatabase`). `CLLocationManagerDelegate` callbacks are `nonisolated` and hop to `@MainActor` via `Task { @MainActor in ... }`.

### The heart: `LocationService`
This is the most important and most complex file. It runs **two GPS modes**, selected centrally in `applyLocationMode()`:
- **Silent background** — significant-location-change + up to 20 `CLCircularRegion` geofences (iOS hard limit) around the nearest cameras; the system wakes the app on region entry → local notification. Near-zero battery.
- **Trip mode** (`startTrip`/`endTrip`) — continuous high-accuracy GPS with active alerts even when backgrounded (requires "Always" auth). Auto-started/stopped by `MotionService` (CoreMotion) when `settings.autoStartTrip`.

It also owns: the approach-alert engine with escalating thresholds and hysteresis (`runAlertEngine`), the directional filter (only warn about cameras ahead within ±70° of course — `isAhead`), the "smart radius" (warn N seconds out, not fixed meters — `effectiveAlertRadius`), pass-tracking (records speed at the traverse point of each camera, radar-style — `updatePassTracking`), and adaptive accuracy (relax GPS when far from cameras/maneuvers — `tuneAdaptiveAccuracy`). Speed-limit matching and route progress are driven from here (not the UI) so voice keeps working when backgrounded.

### `RouteService` — routing (own engine)
Apple Maps does not route inside Uzbekistan, so `calculate()` tries `MKDirections` first and falls back to the **self-hosted OSRM server**. Produces engine-agnostic `Variant`s (each with cameras-along-route count and turn-by-turn `RouteStep`s). Live progress (`updateProgress`, called per GPS tick) handles arrival detection, next-camera/next-maneuver, voice maneuver staging, and off-route reroute (with GPS-noise confirmation ticks + cooldown). All the geometry (`project`, `camerasAlong`, `traveledPrefix`) is `nonisolated static` and runs off-main.

### `CameraStore` (`CameraRepository`) — data
Merged set = bundled `Resources/cameras.json` + user-added `custom` + crowdsourced `mobile` − `hiddenIDs`. Two caches invalidated together in `dataChanged()`: a `mergedCache` list and a **grid spatial index** (0.05° ≈ 5.5 km cells) so `nearest(to:)` and `cameras(in:)` never scan all ~3300 cameras on the hot path (retile fires every ~1.5 km driven). `revision` increments on any change; UI observes it. OTA updates (`applyRemote`) validate, atomically write to `Documents/cameras_remote.json`, and swap in memory; the downloaded copy survives app updates and is preferred over the bundled DB on next launch.

### Other services
- `RemoteSyncService` — daily OTA check of the camera DB against the server version.
- `MobileCameraService` — crowdsourced mobile-radar reports; polls every 3 min in foreground only; anonymous device UUID.
- `SpeedLimitService` — matches OSM `maxspeed` for the current road (position + course), warns on overspeed with a tolerance; ~3 MB DB, indexed for microsecond per-tick matching.
- `AlertPlayer` — preloaded beep + `AVSpeechSynthesizer`; plays over silent mode and ducks other audio.
- `LiveActivityService` / `MetricsService` (MetricKit) / `NotificationService`.

### Configuration
**`Support/AppConfig.swift` is the single source of truth for all tunable constants** — alert radii, timings, map zoom/clustering thresholds, directional angles, reroute tuning, and server URLs. Change behavior here, not scattered across files. Server base is `syncBaseURL` (currently `http://45.130.148.94:8090`; OSRM at `/osrm`) — TODO before App Store: domain + HTTPS.

### UI
`RootView` gates onboarding → `MapScreen`, and drives foreground/background GPS mode from `scenePhase`. Features are organized by folder under `Features/` (Map, Search, Trip, Settings, Onboarding), each screen backed by an `@Observable` view model (e.g. `MapViewModel` does buffered annotation loading + clustering to keep panning smooth). Dark-only ("radar detector" aesthetic) — `.preferredColorScheme(.dark)`, styled via `DesignSystem/Theme.swift` + `Components.swift`.

### Widgets & sharing
`RadarMapWidgets` (Live Activity in Dynamic Island + home stats widget). Shared code lives in `Shared/`: `CameraActivityAttributes` (Live Activity contract) and `SharedDefaults` (App-Group `UserDefaults` snapshot for the home widget). **Gotcha:** App Groups are currently disabled in both `.entitlements` files (free Apple ID limitation), and `SharedDefaults.appGroup` (`group.test.RadarMap`) does not match the commented-out entitlement group (`group.uz.rasul.radarmap`) — the home widget's shared data is effectively inert until a paid account re-enables App Groups and the IDs are reconciled.

## Backend

The VPS is provisioned separately (not in this repo). It serves the camera DB and speed-limit files (nginx :8090), runs OSRM in Docker (CH algorithm, `--mmap`) on an Uzbekistan OSM graph, and a Python-stdlib + SQLite crowdsourcing API (systemd, rate-limited, TTL'd markers). Cron jobs refresh the camera DB nightly from data.egov.uz (sha256-idempotent) and the road graph + speed limits monthly.
