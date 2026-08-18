//
//  ParkingSearchService.swift
//  KyoNoAshiato
//
//  Created by Claude on 2026/08/18.
//

import CoreLocation
import MapKit

/// CarPlayの駐車場検索。現在地周辺の駐車場をMapKitから探す。
/// driving taskアプリのガイドラインではPOIの更新は60秒に1回までなので、
/// 直前の検索から60秒以内はネットワーク検索をせずキャッシュを返す。
@MainActor
final class ParkingSearchService {
    struct Spot {
        let mapItem: MKMapItem
        let name: String
        let address: String?
        let coordinate: CLLocationCoordinate2D
        let distance: CLLocationDistance

        fileprivate func measured(from origin: CLLocation) -> Spot {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return Spot(
                mapItem: mapItem,
                name: name,
                address: address,
                coordinate: coordinate,
                distance: origin.distance(from: location)
            )
        }
    }

    /// CPPointOfInterestTemplateが表示できるPOIの上限に合わせる。
    static let maxSpotCount = 12

    private static let searchRadius: CLLocationDistance = 3000
    private static let minimumSearchInterval: TimeInterval = 60

    private(set) var spots: [Spot] = []

    private var search: MKLocalSearch?
    private var lastSearchDate: Date?

    /// 現在地周辺の駐車場を近い順に返す。完了ハンドラはメインアクター上で呼ばれる。
    func searchSpots(
        around coordinate: CLLocationCoordinate2D,
        completion: @escaping (Result<[Spot], Error>) -> Void
    ) {
        if let cached = cachedSpots(around: coordinate) {
            spots = cached
            completion(.success(cached))
            return
        }

        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: Self.searchRadius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.parking])

        search?.cancel()
        let search = MKLocalSearch(request: request)
        self.search = search

        search.start { [weak self] response, error in
            guard let self else { return }
            self.search = nil

            if let error {
                completion(.failure(error))
                return
            }

            let found = Self.makeSpots(from: response?.mapItems ?? [], around: coordinate)
            self.spots = found
            self.lastSearchDate = Date()
            completion(.success(found))
        }
    }

    /// 直前の検索から60秒以内なら再検索せず、距離だけ現在地基準で計算し直したキャッシュを使う。
    private func cachedSpots(around coordinate: CLLocationCoordinate2D) -> [Spot]? {
        guard !spots.isEmpty, let lastSearchDate else { return nil }
        guard Date().timeIntervalSince(lastSearchDate) < Self.minimumSearchInterval else { return nil }
        return Self.sortedByDistance(spots, around: coordinate)
    }

    private static func makeSpots(
        from mapItems: [MKMapItem],
        around coordinate: CLLocationCoordinate2D
    ) -> [Spot] {
        let spots = mapItems.map { mapItem in
            Spot(
                mapItem: mapItem,
                name: mapItem.name ?? "駐車場",
                address: mapItem.address?.shortAddress ?? mapItem.address?.fullAddress,
                coordinate: mapItem.location.coordinate,
                distance: 0
            )
        }
        return Array(sortedByDistance(spots, around: coordinate).prefix(maxSpotCount))
    }

    private static func sortedByDistance(
        _ spots: [Spot],
        around coordinate: CLLocationCoordinate2D
    ) -> [Spot] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return spots
            .map { $0.measured(from: origin) }
            .sorted { $0.distance < $1.distance }
    }
}
