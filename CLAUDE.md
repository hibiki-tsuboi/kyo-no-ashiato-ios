# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**今日のあしあと (Kyo no Ashiato)** — An iPhone app that records GPS movement routes and lets users review their daily footprints on a map.

- Bundle ID: `jp.hibiki.kyonoashiato.app` (Watch app: `jp.hibiki.kyonoashiato.app.watchkitapp`)
- Deployment target: iOS/iPadOS 26.0, watchOS 26.0
- Swift 5.0, SwiftUI, SwiftData

## Build & Test Commands

```bash
# Build
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiato -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run unit tests
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoTests -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run UI tests
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoUITests -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Architecture

A working GPS footprints app with an iOS app, an Apple Watch companion, and a CarPlay screen. The data flows: CoreLocation → `LocationManager` → SwiftData (`RouteRecord` + `LocationPoint`), reviewed later on a map.

### Entry point & navigation
- **`KyoNoAshiatoApp.swift`** — App entry point. Injects `AppModelContainer.shared` and `LocationManager.shared`. An `AppDelegate` wires the `ModelContext` into `LocationManager` at launch (which also refreshes the home geofence so a relaunched-from-terminated app can still notify) and cleans up leftover temp video files. When `scenePhase` becomes `.active`, incomplete-route recovery re-runs.
- **`AppModelContainer.swift`** — Shared `ModelContainer` singleton (schema: `RouteRecord`, `LocationPoint`, `RoutePhoto`, `RouteMedia`) used by both the SwiftUI scene and the CarPlay scene.
- **`ContentView.swift`** — Root `TabView` with two tabs: **出発** (`RecordingView`) and **あしあと** (`HistoryListView`).

### Models (SwiftData `@Model`)
- **`RouteRecord.swift`** — One recorded outing: title, start/end dates, pause bookkeeping (`pausedDuration` accumulated seconds + `pausedAt`, persisted so a paused trip survives relaunch), an optional manual `TransportMode` override (otherwise inferred from median segment speed), and cascade relationships to `points` and `photos`. Computed helpers: `coordinates`, `totalDistance`, `duration`, `movingDuration` (excludes pauses — use this for display), `isPaused`, `transportMode`, `mapRegion`.
- **`LocationPoint.swift`** — A single GPS sample (lat/lon/timestamp) belonging to a route.
- **`RoutePhoto.swift`** — A pin placed at a tapped/derived coordinate on a route's map (independent of the polyline; not snapped to it), holding memory photos/videos. Legacy pins store a single medium directly in `imageData`/`videoData`; newer pins hang one or more `RouteMedia` children off `media` (the legacy columns are kept for compatibility and seeded with the first medium). `allMedia` / `representative` unify both shapes via the `MediaItem` enum.
- **`RouteMedia.swift`** — One photo/video inside a pin. `imageData` always holds a downscaled JPEG (the photo itself, or a poster frame for videos); `videoData` is non-nil only for videos and holds a compressed copy; `mediaType` is computed from `videoData`'s presence (no dedicated column, keeping lightweight migration safe). Also defines `MediaItem`, the modern/legacy wrapper the UI works with.

### Recording
- **`LocationManager.swift`** — `@Observable` singleton wrapping `CLLocationManager`. Owns the recording state machine (`RecordingState`: idle / recording / paused via `start/pause/resume/stopRecording`), background updates, location filtering (`isValidLocation`), incomplete- and paused-route recovery, permission helpers (`canRecordLocation`, `requestPermissionIfNeeded`) used to guard remote starts from Watch/CarPlay, and the **home geofence** (`CLCircularRegion`, exit-only) that powers the "you left home" reminder. Posts `.locationManagerRecordingDidChange` (consumed by CarPlay). Holds the `ModelContext` and the `WatchConnectivityManager`.
- **`RecordingView.swift`** — Live map (`UserAnnotation` + polyline), the 出発 / 一時停止・再開 / 到着 buttons, recording status pill (elapsed time freezes while paused), the arrival summary sheet (`ArrivalSheet`, includes 休憩 time), a current-location button, and the home setup menu.
- **`HomeStore.swift`** — Persists the user's "home" coordinate in `UserDefaults` only (never sent off-device).
- **`NotificationManager.swift`** — Sends the departure reminder (10-minute cooldown). Reminders only nudge; recording is always started manually by the user.

### Review
- **`HistoryListView.swift`** — Lists completed routes (`endDate != nil`) newest-first. Rows show relative date, time span, moving duration, transport emoji, distance, and a media icon when the route has pins. Deletion works only in 編集 mode — swipe-to-delete is deliberately disabled to prevent accidental deletion.
- **`RouteDetailView.swift`** — Map with polyline, start/end markers, a time-scrubbing slider with a moving 👣 marker, media pins (thumbnail + ▶ overlay for videos + count badge for multi-media pins), title/transport-mode editing, and share-snapshot export (`MKMapSnapshotter`). Adding media has two flows: **manual** (tap the map → `PhotosPicker`; a multi-selection becomes one multi-media pin at the tapped spot) and **auto** (`MediaLocation` extracts the capture coordinate; items without GPS queue in a "位置情報なし" banner for one-by-one tap placement). `MediaCarouselView` is the full-screen viewer: pages through a pin's media, navigates across pins (map camera follows), and supports adding/deleting; videos are written to temp (`videoTempURL`) and played with AVKit. Imported videos are re-encoded via `AVAssetExportSession` with a poster frame from `AVAssetImageGenerator`.
- **`MediaLocation.swift`** — Pure helpers that extract capture coordinate and capture date from photos (EXIF) and videos (ISO 6709 / `commonMetadata`). Unit-tested.

### Apple Watch companion (`KyoNoAshiatoWatch/`)
- A remote control: shows recording status/elapsed/distance and sends start/pause/resume/stop commands. State syncs over **WatchConnectivity** (`WatchConnectivityManager` on both sides — `updateApplicationContext` for status, `sendMessage` for commands). Command replies carry the fresh status plus an optional `error` message (e.g. location permission missing) that the watch shows as a banner; receiving any valid status payload clears a stale banner.

### CarPlay (`CarPlaySceneDelegate.swift`)
- A driving-task CarPlay app (entitlement `com.apple.developer.carplay-driving-task`; the scene is declared in `KyoNoAshiato/Info.plist`). The root is a `CPInformationTemplate` (state / start time / distance / elapsed, plus 出発・一時停止/再開・到着・地図・周辺 buttons — the bottom row caps at 3, so 周辺 only appears while idle) refreshed by a 10-second timer while recording and by `.locationManagerRecordingDidChange`. Driving-task guidelines cap periodic refreshes, so data items are re-applied at most once every 10 seconds and POIs at most once every 60 seconds (recording-state changes bypass the gate since they are user-initiated, so durations show seconds but tick in 10-second jumps). The 地図 button pushes a `CPPointOfInterestTemplate` showing just two pins — the start point and the current location. Waypoint pins were dropped deliberately: the POI template is meant for places you pick to act on, and a breadcrumb trail is a review feature rather than a driving task. Starting from CarPlay is guarded by `locationManager.canRecordLocation`.
- **Nearby search** — the 周辺 button opens a `CPActionSheetTemplate` (modal, so it doesn't count toward the 2-template driving-task depth) offering 駐車場 / 給油 / EV充電; the map screen's nav bar then cycles those three and switches back to あしあと while recording. `PlaceSearchService.swift` wraps `MKLocalPointsOfInterestRequest` per category (one instance each, so caches are independent): 9 spots at most within 1.5 km, falling back to 3 km when nothing is nearby, picked by distance from the searched center but labelled with the distance from the driver. Pins carry the distance-order number (matching the card title) in a category color — parking indigo, fuel teal, EV green — and the highlighted one is drawn orange. Panning the map re-searches the new area (1.5 s debounce, and never more often than the 60-second POI cap). The map camera can't be controlled at all: `selectedIndex` only highlights, re-applying POIs doesn't reframe, and popping/pushing the template to force a reframe breaks navigation — see the CarPlay POI template limits in memory.

### Tests
- Unit tests use Swift's **Testing** framework (`import Testing`, `@Test`, `#expect()`); `MediaLocationTests` covers EXIF GPS and ISO 6709 parsing. UI tests use **XCTest**.

## Key Technology Choices

- **SwiftData** for local persistence (replaces Core Data)
- **MapKit** for live recording and route review (`Map`, `MapPolyline`, `MapReader`, `MKMapSnapshotter`)
- **CoreLocation** for GPS tracking and home geofencing (background updates, `CLCircularRegion`)
- **PhotosUI** (`PhotosPicker`) for adding memory photos and videos without requiring photo-library permission
- **AVKit / AVFoundation** for video playback (`VideoPlayer`), poster-frame extraction (`AVAssetImageGenerator`), re-encoding (`AVAssetExportSession`) imported videos to keep on-device storage in check, and capture metadata (`AVAsset` `commonMetadata`)
- **CarPlay** templates (`CPInformationTemplate`, `CPPointOfInterestTemplate`, `CPActionSheetTemplate`, `CPAlertTemplate`) for the in-car screen
- **WatchConnectivity** for iPhone ↔ Apple Watch sync
- **UserNotifications** for the departure reminder

## Language rules
- Always answer in Japanese.
