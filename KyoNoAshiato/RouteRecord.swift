//
//  RouteRecord.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import Foundation
import SwiftData
import CoreLocation
import MapKit

@Model
final class RouteRecord {
    var id: UUID
    var title: String
    var startDate: Date
    var endDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \LocationPoint.route)
    var points: [LocationPoint]

    init(startDate: Date = Date()) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = nil
        self.points = []
        self.title = Self.generateTitle(from: startDate)
    }

    private static func generateTitle(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日のあしあと"
        return formatter.string(from: date)
    }

    var coordinates: [CLLocationCoordinate2D] {
        points
            .sorted { $0.timestamp < $1.timestamp }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var duration: TimeInterval? {
        guard let endDate else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    var mapRegion: MKCoordinateRegion? {
        let coords = coordinates
        guard !coords.isEmpty else { return nil }

        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }

        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
