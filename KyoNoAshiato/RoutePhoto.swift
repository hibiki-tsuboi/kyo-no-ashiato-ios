//
//  RoutePhoto.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/05/27.
//

import Foundation
import SwiftData
import CoreLocation

/// 思い出メディアの種別。
enum RouteMediaType: String, Codable {
    case photo
    case video
}

/// あしあと（記録）に紐づく思い出の写真・動画。
/// 地図上でユーザーがタップした座標に配置され、軌跡の線とは独立したレイヤーとして扱う。
@Model
final class RoutePhoto {
    var id: UUID
    /// 配置座標（地図タップで決定。軌跡の線にはスナップさせない）
    var latitude: Double
    var longitude: Double
    /// 静止画。写真ならその写真、動画ならポスターフレーム。ピンのサムネイル表示に使う。
    /// 縮小したコピーをアプリ内に保持する。元データをカメラロールから消しても思い出は残る。
    /// 旧バージョン（1 ピン = 1 メディア）時代のデータがここに残る。新規追加分は `media` 側へ。
    @Attribute(.externalStorage) var imageData: Data
    /// 動画の本体（圧縮済みコピー）。写真の場合は nil。
    /// 既存レコードへの追加でも安全に軽量移行できるよう、追加するのはこのオプショナル列だけにしている。
    @Attribute(.externalStorage) var videoData: Data?
    var createdDate: Date
    var caption: String?
    var route: RouteRecord?
    /// 1 ピン複数メディア対応で追加した子コレクション。新規ピンはこちらに 1 件以上が入り、
    /// 旧データ（`media` が空）では従来の `imageData` / `videoData` を 1 件目として扱う。
    @Relationship(deleteRule: .cascade, inverse: \RouteMedia.photo)
    var media: [RouteMedia] = []

    init(
        latitude: Double,
        longitude: Double,
        imageData: Data,
        videoData: Data? = nil,
        createdDate: Date = Date()
    ) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.imageData = imageData
        self.videoData = videoData
        self.createdDate = createdDate
        self.caption = nil
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 写真か動画かは保存した動画データの有無から判定する（専用の列は持たない）。
    /// このピン自身の代表種別。`media` が入っているピンではサムネ用途。
    var mediaType: RouteMediaType {
        videoData == nil ? .photo : .video
    }

    /// 表示用にこのピンが束ねる全メディア。
    /// 新形式（`media` が 1 件以上）は `sortOrder` 順、旧形式は本体を 1 件目として返す。
    var allMedia: [MediaItem] {
        if media.isEmpty {
            return [.legacy(self)]
        }
        return media
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(MediaItem.modern)
    }

    /// サムネ／代表種別の判定に使う先頭メディア。
    var representative: MediaItem {
        allMedia.first ?? .legacy(self)
    }
}
