# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**今日のあしあと (Kyo no Ashiato)** — An iPhone app that records GPS movement routes and lets users review their daily footprints on a map.

- Bundle ID: `jp.hibiki.KyoNoAshiato`
- Deployment target: iOS/iPadOS 26.2
- Swift 5.0, SwiftUI, SwiftData

## Build & Test Commands

```bash
# Build
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiato -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run unit tests
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoTests -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run UI tests
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Architecture

The app is in its initial scaffolding stage. The current structure uses the standard Xcode SwiftUI + SwiftData template:

- **`KyoNoAshiatoApp.swift`** — App entry point. Configures a `ModelContainer` with SwiftData and injects it into the view hierarchy.
- **`ContentView.swift`** — Root view. Currently a placeholder list view using SwiftData's `@Query`.
- **`Item.swift`** — Placeholder SwiftData `@Model`. Will be replaced with real domain models (e.g., route records, location points).

Unit tests use Swift's **Testing** framework (`import Testing`, `@Test`, `#expect()`), not XCTest.

## Key Technology Choices

- **SwiftData** for local persistence (replaces Core Data)
- **MapKit** will be used for GPS route display (not yet integrated)
- **CoreLocation** will be needed for GPS tracking (not yet integrated)


## Language rules
- Always answer in Japanese.

