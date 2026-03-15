# Repository Guidelines

## Project Structure & Module Organization
- `KyoNoAshiato/`: Main iOS app source (SwiftUI + SwiftData).
- `KyoNoAshiatoApp.swift`: App entry point and `ModelContainer` setup.
- `LocationManager.swift`: Core location tracking and route recording logic.
- `ContentView.swift`, `RecordingView.swift`, `HistoryListView.swift`, `RouteDetailView.swift`: Main UI screens.
- `KyoNoAshiatoTests/`: Unit tests using Swift Testing (`import Testing`).
- `KyoNoAshiatoUITests/`: UI test targets.
- `docs/`: Project docs and image assets.

## Build, Test, and Development Commands
- Build app:
```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiato -destination 'platform=iOS Simulator,name=iPhone 16' build
```
- Run unit tests:
```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoTests -destination 'platform=iOS Simulator,name=iPhone 16' test
```
- Run UI tests:
```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Coding Style & Naming Conventions
- Language: Swift 5, SwiftUI, SwiftData, CoreLocation.
- Indentation: 4 spaces; keep lines readable and avoid deep nesting.
- Types: `UpperCamelCase` (`LocationManager`, `RouteRecord`).
- Variables/functions: `lowerCamelCase` (`recoverIncompleteRoutes`, `currentRoute`).
- One primary type per file; file name should match the main type/view.
- Prefer small, focused SwiftUI views and keep side effects in manager/model layers.

## Testing Guidelines
- Unit tests use Swift Testing (`@Test`, `#expect(...)`), not XCTest.
- Test files should mirror source names where possible (example: `LocationManagerTests.swift`).
- Add tests for route lifecycle behavior (start, updates, stop, recovery of incomplete routes).
- Run both unit and UI tests before opening a PR.

## Commit & Pull Request Guidelines
- Follow existing history style: gitmoji prefix + concise Japanese summary.
  - Example: `:sparkles: 履歴タイトルの編集機能を追加`
- Keep commits scoped to a single concern (feature, fix, refactor, UI tweak).
- PRs should include:
  - purpose and summary of changes,
  - related issue/ticket link,
  - test results (what was run),
  - screenshots or recordings for UI changes.

## Security & Configuration Tips
- Do not commit personal data, location traces, or simulator-derived artifacts.
- Keep bundle/config updates minimal and review `Info.plist`/entitlements changes carefully.

## Language rules
- Always answer in Japanese.
