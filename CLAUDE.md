# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**今日のあしあと (Kyo no Ashiato)** — An iPhone app that records GPS movement routes and lets users review their daily footprints on a map.

- Bundle ID: `jp.hibiki.kyonoashiato.app` (Watch app: `jp.hibiki.kyonoashiato.app.watchkitapp`)
- Deployment target: iOS/iPadOS 26.2
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

A working GPS footprints app with an iOS app and an Apple Watch companion. The data flows: CoreLocation → `LocationManager` → SwiftData (`RouteRecord` + `LocationPoint`), reviewed later on a map.

### Entry point & navigation
- **`KyoNoAshiatoApp.swift`** — App entry point. Builds the `ModelContainer` (schema: `RouteRecord`, `LocationPoint`, `RoutePhoto`) and injects it. An `AppDelegate` refreshes the home geofence on launch so a relaunched-from-terminated app can still notify.
- **`ContentView.swift`** — Root `TabView` with two tabs: **出発** (`RecordingView`) and **あしあと** (`HistoryListView`).

### Models (SwiftData `@Model`)
- **`RouteRecord.swift`** — One recorded outing: title, start/end dates, an optional manual `TransportMode` override (otherwise inferred from speed), and cascade relationships to `points` and `photos`. Computed helpers: `coordinates`, `totalDistance`, `duration`, `transportMode`, `mapRegion`.
- **`LocationPoint.swift`** — A single GPS sample (lat/lon/timestamp) belonging to a route.
- **`RoutePhoto.swift`** — A memory photo or video placed at a tapped coordinate on a route's map (independent of the polyline; not snapped to it). `imageData` always holds a downscaled JPEG (the photo itself, or a poster frame for videos); `videoData` is non-nil only for videos and holds a compressed copy. `mediaType` is computed from `videoData`'s presence so the schema only ever needed one new optional column added (lightweight migration stays safe).

### Recording
- **`LocationManager.swift`** — `@Observable` singleton wrapping `CLLocationManager`. Owns recording lifecycle (`start/stopRecording`), background updates, location filtering (`isValidLocation`), incomplete-route recovery, and the **home geofence** (`CLCircularRegion`, exit-only) that powers the "you left home" reminder. Holds the `ModelContext` and the `WatchConnectivityManager`.
- **`RecordingView.swift`** — Live map (`UserAnnotation` + polyline), the 出発/到着 button, recording status, the arrival summary sheet (`ArrivalSheet`), and the home setup menu.
- **`HomeStore.swift`** — Persists the user's "home" coordinate in `UserDefaults` only (never sent off-device).
- **`NotificationManager.swift`** — Sends the departure reminder (with cooldown). Reminders only nudge; recording is always started manually by the user.

### Review
- **`HistoryListView.swift`** — Lists completed routes (`endDate != nil`) newest-first; row + swipe-to-delete.
- **`RouteDetailView.swift`** — Map with polyline, start/end markers, a time-scrubbing slider with a moving 👣 marker, photo/video pins (video pins show a ▶ overlay; tap opens `MediaViewerView` which renders either an image or an `AVKit` `VideoPlayer`), tap-to-place media adding (`MapReader` + `PhotosPicker` matching both images and videos; videos are re-encoded via `AVAssetExportSession` and a poster frame is generated via `AVAssetImageGenerator`), title/transport-mode editing, and share-snapshot export (`MKMapSnapshotter`).

### Apple Watch companion (`KyoNoAshiatoWatch/`)
- A remote control: shows recording status/elapsed/distance and sends start/stop commands. State syncs over **WatchConnectivity** (`WatchConnectivityManager` on both sides — `updateApplicationContext` for status, messages for commands).

### Tests
- Unit tests use Swift's **Testing** framework (`import Testing`, `@Test`, `#expect()`); UI tests use **XCTest**.

## Key Technology Choices

- **SwiftData** for local persistence (replaces Core Data)
- **MapKit** for live recording and route review (`Map`, `MapPolyline`, `MapReader`, `MKMapSnapshotter`)
- **CoreLocation** for GPS tracking and home geofencing (background updates, `CLCircularRegion`)
- **PhotosUI** (`PhotosPicker`) for adding memory photos and videos without requiring photo-library permission
- **AVKit / AVFoundation** for video playback (`VideoPlayer`), poster-frame extraction (`AVAssetImageGenerator`), and re-encoding (`AVAssetExportSession`) imported videos to keep on-device storage in check
- **WatchConnectivity** for iPhone ↔ Apple Watch sync
- **UserNotifications** for the departure reminder

## Language rules
- Always answer in Japanese.
