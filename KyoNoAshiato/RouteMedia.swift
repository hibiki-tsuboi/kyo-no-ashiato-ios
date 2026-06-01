//
//  RouteMedia.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/06/01.
//

import Foundation
import SwiftData

/// 1 つの `RoutePhoto`（ピン）にぶら下がる個別メディア。
/// 1 ピンに複数の写真・動画をまとめて登録できるようにするための子モデル。
/// 既存ユーザーのデータ（`RoutePhoto.imageData` 直持ち）はそのまま残し、
/// 新規追加分のみこちらに入れる二段構え（A 方針）。
@Model
final class RouteMedia {
    var id: UUID
    /// 静止画。写真ならその写真、動画ならポスターフレーム。
    @Attribute(.externalStorage) var imageData: Data
    /// 動画の本体（圧縮済みコピー）。写真の場合は nil。
    @Attribute(.externalStorage) var videoData: Data?
    /// 同一ピン内での表示順。追加順に増えていく。
    var sortOrder: Int
    var createdDate: Date
    var photo: RoutePhoto?

    init(
        imageData: Data,
        videoData: Data? = nil,
        sortOrder: Int = 0,
        createdDate: Date = Date()
    ) {
        self.id = UUID()
        self.imageData = imageData
        self.videoData = videoData
        self.sortOrder = sortOrder
        self.createdDate = createdDate
    }

    /// 写真か動画かは保存した動画データの有無から判定する（`RoutePhoto` と同じ流儀）。
    var mediaType: RouteMediaType {
        videoData == nil ? .photo : .video
    }
}

/// UI 用に「旧形式の単体メディア（`RoutePhoto` 直持ち）」と
/// 「新形式の `RouteMedia`」を同じインターフェースで扱うためのラッパ。
/// レガシーデータを表示・削除する経路を残しつつ、新規 UI 側は常に配列前提で書ける。
enum MediaItem: Identifiable {
    case modern(RouteMedia)
    case legacy(RoutePhoto)

    var id: UUID {
        switch self {
        case .modern(let m): return m.id
        case .legacy(let p): return p.id
        }
    }

    var imageData: Data {
        switch self {
        case .modern(let m): return m.imageData
        case .legacy(let p): return p.imageData
        }
    }

    var videoData: Data? {
        switch self {
        case .modern(let m): return m.videoData
        case .legacy(let p): return p.videoData
        }
    }

    var mediaType: RouteMediaType {
        videoData == nil ? .photo : .video
    }
}
