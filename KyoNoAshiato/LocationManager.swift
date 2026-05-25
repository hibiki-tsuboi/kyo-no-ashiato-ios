//
//  LocationManager.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import CoreLocation
import SwiftData
import Observation

@Observable
final class LocationManager: NSObject {
    static let shared = LocationManager()

    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var isRecording = false
    var currentRoute: RouteRecord?
    var currentCoordinates: [CLLocationCoordinate2D] = []

    @ObservationIgnored private let clManager = CLLocationManager()
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var lastAcceptedLocation: CLLocation?
    @ObservationIgnored private lazy var watchManager = WatchConnectivityManager(locationManager: self)
    @ObservationIgnored private var homeCaptureCompletion: ((CLLocationCoordinate2D?) -> Void)?

    /// 自宅ジオフェンスの識別子と半径。
    /// 半径は測位のゆらぎ（屋内/住宅街では数十m）による誤発火を避けるため100m以上にしている。
    private static let homeRegionIdentifier = "home"
    @ObservationIgnored private let homeRegionRadius: CLLocationDistance = 100

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 5
        clManager.activityType = .other
        clManager.allowsBackgroundLocationUpdates = true
        clManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = clManager.authorizationStatus
    }

    func setup(modelContext: ModelContext) {
        self.modelContext = modelContext
        watchManager.activate()
        recoverIncompleteRoutes()
        refreshHomeRegionMonitoring()
    }

    func recoverIncompleteRoutes() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<RouteRecord>(
            predicate: #Predicate { $0.endDate == nil }
        )
        guard let incomplete = try? modelContext.fetch(descriptor) else { return }
        for route in incomplete {
            guard route.id != currentRoute?.id else { continue }
            let lastTimestamp = route.points.map(\.timestamp).max()
            route.endDate = lastTimestamp ?? route.startDate
        }
        try? modelContext.save()
    }

    func requestPermission() {
        clManager.requestAlwaysAuthorization()
    }

    /// 自宅を中心としたジオフェンスの監視を最新化する。アプリが終了していても、
    /// 自宅から離れるとOSが起こして `didExitRegion` を届けてくれるため、付け忘れのリマインドに使える。
    /// 自宅未設定・常時許可なしのときは監視しない。自宅変更時にも呼ぶこと。
    func refreshHomeRegionMonitoring() {
        guard clManager.authorizationStatus == .authorizedAlways else { return }
        guard let home = HomeStore.shared.home else {
            stopHomeRegionMonitoring()
            return
        }
        // すでに同じ中心・半径で監視中なら再登録しない（保留中の離脱イベントを邪魔しないため）。
        if let existing = monitoredHomeRegion,
           existing.center.latitude == home.latitude,
           existing.center.longitude == home.longitude,
           existing.radius == homeRegionRadius {
            return
        }
        stopHomeRegionMonitoring()
        let region = CLCircularRegion(center: home, radius: homeRegionRadius, identifier: Self.homeRegionIdentifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        clManager.startMonitoring(for: region)
    }

    private var monitoredHomeRegion: CLCircularRegion? {
        clManager.monitoredRegions.first { $0.identifier == Self.homeRegionIdentifier } as? CLCircularRegion
    }

    private func stopHomeRegionMonitoring() {
        for region in clManager.monitoredRegions where region.identifier == Self.homeRegionIdentifier {
            clManager.stopMonitoring(for: region)
        }
    }

    /// 自宅設定用に現在地を1度だけ取得する。失敗時は nil を返す。
    func captureCurrentLocation(_ completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        // 記録中はすでに位置更新が流れているので、最新の位置をそのまま使う。
        if isRecording, let coordinate = clManager.location?.coordinate {
            completion(coordinate)
            return
        }
        homeCaptureCompletion = completion
        clManager.requestLocation()
    }

    func startRecording() {
        guard let modelContext else { return }
        let route = RouteRecord()
        modelContext.insert(route)
        try? modelContext.save()
        currentRoute = route
        currentCoordinates = []
        lastAcceptedLocation = nil
        isRecording = true
        clManager.startUpdatingLocation()
        watchManager.sendStatus()
    }

    func stopRecording() {
        guard let route = currentRoute, let modelContext else { return }
        // ポイントが1件以下の場合、スライダーを表示できるよう末尾点を複製する
        if route.points.count == 1, let only = route.points.first {
            let dup = LocationPoint(latitude: only.latitude, longitude: only.longitude, timestamp: Date())
            dup.route = route
            route.points.append(dup)
        }
        route.endDate = Date()
        try? modelContext.save()
        clManager.stopUpdatingLocation()
        isRecording = false
        currentRoute = nil
        lastAcceptedLocation = nil
        watchManager.sendStatus()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 自宅設定用の単発取得を最優先で処理する。
        if let completion = homeCaptureCompletion, let location = locations.last {
            homeCaptureCompletion = nil
            completion(location.coordinate)
        }

        guard let route = currentRoute, let modelContext else { return }
        var didAddPoint = false

        for location in locations {
            guard isValidLocation(location) else { continue }

            let point = LocationPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: location.timestamp
            )
            point.route = route
            route.points.append(point)
            currentCoordinates.append(location.coordinate)
            lastAcceptedLocation = location
            didAddPoint = true
        }

        if didAddPoint {
            try? modelContext.save()
            watchManager.sendStatus()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        // 常時許可が下りたタイミングで自宅ジオフェンスの監視を確実に開始しておく。
        refreshHomeRegionMonitoring()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        // 自宅ジオフェンスからの離脱だけ扱う。
        guard region.identifier == Self.homeRegionIdentifier else { return }
        // すでに記録中なら通知は不要。
        guard !isRecording else { return }
        NotificationManager.shared.sendDepartureReminder()
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        print("Region monitoring error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // 自宅設定用の取得が失敗した場合は呼び出し元に失敗を伝える。
        if let completion = homeCaptureCompletion {
            homeCaptureCompletion = nil
            completion(nil)
        }
        print("LocationManager error: \(error.localizedDescription)")
    }

    private func isValidLocation(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard location.horizontalAccuracy <= 200 else { return false }
        // バッチ配送された位置は数十秒遅れることがあるため許容幅を広げる。
        guard abs(location.timestamp.timeIntervalSinceNow) <= 180 else { return false }

        guard let last = lastAcceptedLocation else { return true }

        let timeInterval = location.timestamp.timeIntervalSince(last.timestamp)
        guard timeInterval > 0 else { return false }

        let distance = location.distance(from: last)
        let speed = distance / timeInterval
        let maxPlausibleSpeed: CLLocationSpeed = 120 // 約432km/h

        return speed <= maxPlausibleSpeed
    }
}
