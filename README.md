# 今日のあしあと (Kyo no Ashiato)

iPhone の位置情報を使って移動ルートを記録し、旅行やお出かけの「あしあと」を地図で振り返るためのアプリです。

## 概要

- iPhone の GPS で移動ルートを記録します
- 記録したルートはマップ上に線で可視化されます
- 記録は履歴として複数件保存され、上書きされません
- 旅行後に「どこをどう移動したか」を地図で振り返れます
- 移動手段は問いません（徒歩 / 自転車 / 電車 / 車 / 飛行機 など）
- 地図はピンチイン・ピンチアウトで拡大縮小できます
- バックグラウンドでも記録継続を想定しています

ジョギングアプリやワークアウト記録のマップ機能に近い体験を、旅行の振り返り向けに提供するイメージです。

## 想定ユースケース

1. 旅行前に記録開始ボタンをタップする
2. 旅行後に記録終了ボタンをタップする
3. 記録されたルートを履歴から開き、地図で移動経路を確認する

## 主な機能

- ルート記録開始 / 停止
- バックグラウンド位置更新
- 履歴一覧表示
- 履歴詳細表示（地図、距離、時間）
- 履歴タイトル編集
- 記録中ルートのリアルタイム表示

## 画面構成

- 記録画面: 現在地と記録中ルートを表示し、記録開始 / 停止を操作
- 履歴一覧画面: 過去のあしあとを一覧表示
- 履歴詳細画面: 選択したルートを地図上で確認

## 技術スタック

- Swift 5 / SwiftUI
- SwiftData
- CoreLocation
- MapKit
- Swift Testing

## 開発環境

- Xcode（iOS Simulator または実機）
- 対象: iPhone

## ビルド・テスト

### ビルド

```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiato -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### ユニットテスト

```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoTests -destination 'platform=iOS Simulator,name=iPhone 17' test
```

### UIテスト

```bash
xcodebuild -project KyoNoAshiato.xcodeproj -scheme KyoNoAshiatoUITests -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## アイコンルール

- 拡張子: `png`
- サイズ: `1024px × 1024px`
- 形状: 正方形（角丸加工不要）

## 補足

- 位置情報の記録精度は利用環境（トンネル、地下、高速移動、電波状況など）に影響されます
- バックグラウンド記録には位置情報の権限設定（Always）が必要です
