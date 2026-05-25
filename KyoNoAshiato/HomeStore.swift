//
//  HomeStore.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/05/25.
//

import Foundation
import CoreLocation

/// 「自宅」の位置を保持するストア。自宅から離れたときだけリマインドを出すために使う。
/// 位置は端末内の UserDefaults にのみ保存し、外部へは送信しない。
final class HomeStore {
    static let shared = HomeStore()

    private let latitudeKey = "homeLatitude"
    private let longitudeKey = "homeLongitude"

    private init() {}

    /// 自宅が設定済みか。
    var isConfigured: Bool {
        UserDefaults.standard.object(forKey: latitudeKey) != nil
    }

    /// 設定済みの自宅座標。未設定なら nil。
    var home: CLLocationCoordinate2D? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: latitudeKey) != nil else { return nil }
        let coordinate = CLLocationCoordinate2D(
            latitude: defaults.double(forKey: latitudeKey),
            longitude: defaults.double(forKey: longitudeKey)
        )
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    func setHome(_ coordinate: CLLocationCoordinate2D) {
        let defaults = UserDefaults.standard
        defaults.set(coordinate.latitude, forKey: latitudeKey)
        defaults.set(coordinate.longitude, forKey: longitudeKey)
    }

    func clearHome() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: latitudeKey)
        defaults.removeObject(forKey: longitudeKey)
    }
}
