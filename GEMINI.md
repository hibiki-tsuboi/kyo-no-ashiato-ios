# 今日のあしあと (Kyo no Ashiato) - Project Context

このファイルは、Gemini CLIがプロジェクトの構造、技術スタック、および開発慣習を理解するための指示コンテキストを提供します。

## プロジェクト概要

「今日のあしあと」は、iPhoneのGPSを利用して移動ルートを記録し、1日の移動履歴（あしあと）を地図上で振り返ることができるiOSアプリです。

### 主な機能
- **ルート記録**: バックグラウンドでのリアルタイムGPS位置情報の取得と保存。
- **履歴閲覧**: 過去に記録したルートのリスト表示、詳細（地図、距離、時間）の確認。
- **地図表示**: MapKitを使用した現在地および記録中ルートの可視化。

## 技術スタック
- **言語**: Swift 5.0+ (Swift 6対応)
- **UIフレームワーク**: SwiftUI
- **データ永続化**: SwiftData
- **位置情報**: CoreLocation (Background Location Updates対応)
- **地図**: MapKit
- **テスト**: Swift Testing (Standard Swift `Testing` framework)

## プロジェクト構造

```text
KyoNoAshiato/
├── KyoNoAshiatoApp.swift     # アプリの進入口、ModelContainerとLocationManagerのセットアップ
├── ContentView.swift          # メインタブインターフェース（記録・履歴）
├── LocationManager.swift      # GPS制御、記録ロジック、SwiftDataへの保存
├── RouteRecord.swift          # ルート全体を管理するデータモデル (@Model)
├── LocationPoint.swift        # 個々のGPS座標を保持するデータモデル (@Model)
├── RecordingView.swift        # 記録画面（地図 + 録画ボタン）
├── HistoryListView.swift      # 履歴一覧画面
└── RouteDetailView.swift      # 特定のルートの詳細表示画面
```

## 開発・実行コマンド

### ビルド
```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiato -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### テスト実行
ユニットテスト（Swift Testingを使用）:
```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoTests -destination 'platform=iOS Simulator,name=iPhone 16' test
```

UIテスト:
```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## 開発規約・ガイドライン

- **言語**: ユーザーとの対話、コード内のコメント、ドキュメントは日本語で行います。
- **アーキテクチャ**:
    - `LocationManager` は `@Observable` を使用したシングルトン的な役割を果たし、Environment経由で各ビューからアクセスします。
    - データモデルは SwiftData (`@Model`) を使用し、リレーションシップ（`RouteRecord` 1 vs n `LocationPoint`）を活用します。
- **UI**:
    - モダンな SwiftUI (iOS 17+ の API) を優先的に使用します。
    - ダークモード/ライトモードの考慮（現在は `preferredColorScheme(.light)` が設定されている箇所があります）。
- **位置情報**:
    - バックグラウンド更新が有効になっているため、`Info.plist` の権限設定と `LocationManager` の `allowsBackgroundLocationUpdates` 設定が重要です。
- **エラーハンドリング**:
    - SwiftData の保存や位置情報権限の拒否に対して、適切なユーザーフィードバック（Alertなど）を提供します。

## 今後の課題 (TODO)
- MapKit を使用したルート詳細画面の実装（`RouteDetailView.swift`）。
- バッテリー消費の最適化（`distanceFilter` の調整など）。
- 記録データのiCloud同期（将来的な拡張）。

## Language rules
- Always answer in Japanese.
