//
//  LocationPoint.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import Foundation
import SwiftData

@Model
final class LocationPoint {
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var route: RouteRecord?

    init(latitude: Double, longitude: Double, timestamp: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}
