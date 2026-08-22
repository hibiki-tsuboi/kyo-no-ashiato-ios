//
//  ParkingSearchService.swift
//  KyoNoAshiato
//
//  Created by Claude on 2026/08/18.
//

import CoreLocation
import MapKit

/// CarPlayの駐車場検索。指定した地点の周辺の駐車場をMapKitから探す。
/// driving taskアプリのガイドラインではPOIの更新は60秒に1回までなので、
/// 同じあたりを立て続けに探したときはネットワーク検索をせずキャッシュを返す。
@MainActor
final class ParkingSearchService {
    struct Spot {
        let mapItem: MKMapItem
        let name: String
        let address: String?
        let coordinate: CLLocationCoordinate2D
        /// 運転者の現在地からの距離。表示に使う値で、並び順の基準とは別。
        let distance: CLLocationDistance

        fileprivate func measured(from origin: CLLocation) -> Spot {
            Spot(
                mapItem: mapItem,
                name: name,
                address: address,
                coordinate: coordinate,
                distance: origin.distance(from: location)
            )
        }

        fileprivate var location: CLLocation {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    /// テンプレートの上限は12個だが、番号を1桁に収めて運転中でも読めるように9件までにする。
    /// ガイドラインも「most relevant or nearby」に絞ることを勧めている。
    static let maxSpotCount = 9

    /// まずは近場だけを探す。ピンが狭い範囲に収まるほど地図が寄って見分けやすくなる。
    private static let searchRadius: CLLocationDistance = 1500
    /// 近場に1件も無かったときだけ広げる。駐車場が少ない場所で空振りしないため。
    private static let fallbackSearchRadius: CLLocationDistance = 3000
    private static let minimumSearchInterval: TimeInterval = 60
    /// このくらいしか中心が動いていなければ、同じ場所を探しているものとしてキャッシュを使う。
    private static let cacheReuseDistance: CLLocationDistance = 300

    private(set) var spots: [Spot] = []

    private var search: MKLocalSearch?
    private var lastSearchDate: Date?
    private var lastSearchCenter: CLLocationCoordinate2D?

    /// `center` の周辺の駐車場を、`center` に近い順に返す。完了ハンドラはメインアクター上で呼ばれる。
    /// `origin` を渡すと距離を測る場所だけを別にできる。地図をパンして別の場所を探すときも、
    /// 表示する距離は運転者の現在地からにしたいため。
    func searchSpots(
        around center: CLLocationCoordinate2D,
        measuringFrom origin: CLLocationCoordinate2D? = nil,
        completion: @escaping (Result<[Spot], Error>) -> Void
    ) {
        let origin = origin ?? center

        if let cached = cachedSpots(around: center, measuringFrom: origin) {
            spots = cached
            completion(.success(cached))
            return
        }

        startSearch(around: center, measuringFrom: origin, radius: Self.searchRadius) { [weak self] result in
            guard let self else { return }
            // 近場に1件も無いときだけ範囲を広げて探し直す。
            if case .success(let found) = result, found.isEmpty {
                self.startSearch(
                    around: center,
                    measuringFrom: origin,
                    radius: Self.fallbackSearchRadius,
                    completion: completion
                )
                return
            }
            completion(result)
        }
    }

    private func startSearch(
        around center: CLLocationCoordinate2D,
        measuringFrom origin: CLLocationCoordinate2D,
        radius: CLLocationDistance,
        completion: @escaping (Result<[Spot], Error>) -> Void
    ) {
        let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
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

            let found = Self.makeSpots(
                from: response?.mapItems ?? [],
                around: center,
                measuringFrom: origin
            )
            self.spots = found
            self.lastSearchDate = Date()
            self.lastSearchCenter = center
            completion(.success(found))
        }
    }

    /// 直前の検索から60秒以内で、探す場所もほとんど動いていないなら再検索しない。
    /// 並び順（＝ピンの番号）は変えず、表示する距離だけ現在地基準で計算し直す。
    private func cachedSpots(
        around center: CLLocationCoordinate2D,
        measuringFrom origin: CLLocationCoordinate2D
    ) -> [Spot]? {
        guard !spots.isEmpty, let lastSearchDate, let lastSearchCenter else { return nil }
        guard Date().timeIntervalSince(lastSearchDate) < Self.minimumSearchInterval else { return nil }
        guard Self.distance(from: lastSearchCenter, to: center) < Self.cacheReuseDistance else { return nil }
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return spots.map { $0.measured(from: originLocation) }
    }

    private static func makeSpots(
        from mapItems: [MKMapItem],
        around center: CLLocationCoordinate2D,
        measuringFrom origin: CLLocationCoordinate2D
    ) -> [Spot] {
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let spots = mapItems.map { mapItem in
            Spot(
                mapItem: mapItem,
                name: mapItem.name ?? "駐車場",
                address: mapItem.address?.shortAddress ?? mapItem.address?.fullAddress,
                coordinate: mapItem.location.coordinate,
                distance: 0
            )
            .measured(from: originLocation)
        }
        // 探した場所に近い順に絞る。現在地基準で絞ると、パンした先の中心付近が落ちてしまう。
        return Array(
            spots
                .sorted { centerLocation.distance(from: $0.location) < centerLocation.distance(from: $1.location) }
                .prefix(maxSpotCount)
        )
    }

    private static func distance(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
    }
}
