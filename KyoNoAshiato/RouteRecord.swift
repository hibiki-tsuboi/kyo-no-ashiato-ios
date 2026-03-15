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

enum TransportMode {
    case walking   // 0〜7 km/h
    case cycling   // 7〜25 km/h
    case driving   // 25〜100 km/h
    case transit   // 100〜400 km/h
    case flying    // 400 km/h〜

    var emoji: String {
        switch self {
        case .walking: return "🚶"
        case .cycling: return "🚲"
        case .driving: return "🚗"
        case .transit: return "🚄"
        case .flying:  return "✈️"
        }
    }

    var label: String {
        switch self {
        case .walking: return "徒歩"
        case .cycling: return "自転車"
        case .driving: return "車・バス"
        case .transit: return "電車・新幹線"
        case .flying:  return "飛行機"
        }
    }
}

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

    var totalDistance: CLLocationDistance {
        let coords = coordinates
        guard coords.count >= 2 else { return 0 }
        return zip(coords, coords.dropFirst()).reduce(0) { sum, pair in
            let from = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let to = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return sum + from.distance(from: to)
        }
    }

    var duration: TimeInterval? {
        guard let endDate else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    var transportMode: TransportMode {
        let chronological = points.sorted { $0.timestamp < $1.timestamp }
        guard chronological.count >= 2 else { return .walking }

        let speeds: [Double] = zip(chronological, chronological.dropFirst()).compactMap { a, b in
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0 else { return nil }
            let from = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let to = CLLocation(latitude: b.latitude, longitude: b.longitude)
            return (from.distance(from: to) / 1000) / (dt / 3600)
        }
        guard !speeds.isEmpty else { return .walking }

        let sorted95 = speeds.sorted()
        let index = Int(Double(sorted95.count) * 0.95)
        let speedKmh = sorted95[min(index, sorted95.count - 1)]

        switch speedKmh {
        case ..<7:     return .walking
        case 7..<25:   return .cycling
        case 25..<100: return .driving
        case 100..<400: return .transit
        default:       return .flying
        }
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
