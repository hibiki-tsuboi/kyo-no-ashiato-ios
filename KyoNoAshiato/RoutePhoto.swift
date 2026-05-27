//
//  RoutePhoto.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/05/27.
//

import Foundation
import SwiftData
import CoreLocation

/// あしあと（記録）に紐づく思い出の写真。
/// 地図上でユーザーがタップした座標に配置され、軌跡の線とは独立したレイヤーとして扱う。
@Model
final class RoutePhoto {
    var id: UUID
    /// 配置座標（地図タップで決定。軌跡の線にはスナップさせない）
    var latitude: Double
    var longitude: Double
    /// 縮小したコピーをアプリ内に保持する。元写真をカメラロールから消しても思い出は残る。
    @Attribute(.externalStorage) var imageData: Data
    var createdDate: Date
    var caption: String?
    var route: RouteRecord?

    init(latitude: Double, longitude: Double, imageData: Data, createdDate: Date = Date()) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.imageData = imageData
        self.createdDate = createdDate
        self.caption = nil
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
