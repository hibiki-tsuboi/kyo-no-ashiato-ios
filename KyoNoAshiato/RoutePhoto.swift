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
    @Attribute(.externalStorage) var imageData: Data
    /// 動画の本体（圧縮済みコピー）。写真の場合は nil。
    /// 既存レコードへの追加でも安全に軽量移行できるよう、追加するのはこのオプショナル列だけにしている。
    @Attribute(.externalStorage) var videoData: Data?
    var createdDate: Date
    var caption: String?
    var route: RouteRecord?

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
    var mediaType: RouteMediaType {
        videoData == nil ? .photo : .video
    }
}
