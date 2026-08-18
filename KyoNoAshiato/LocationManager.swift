//
//  LocationManager.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import CoreLocation
import SwiftData
import Observation

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
}

extension Notification.Name {
    static let locationManagerRecordingDidChange = Notification.Name("locationManagerRecordingDidChange")
}

@Observable
final class LocationManager: NSObject {
    static let shared = LocationManager()

    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var recordingState: RecordingState = .idle
    var currentRoute: RouteRecord?
    var currentCoordinates: [CLLocationCoordinate2D] = []
    /// 記録中のルートの総距離。点の追加ごとに加算していく。
    /// 表示のたびに全点をなめると点数に比例して重くなるため、ここで持ち回す。
    var currentDistance: CLLocationDistance = 0

    /// 互換性のため残しているフラグ。出発前は false、記録中・一時停止中はいずれも true。
    /// 一時停止と記録中を区別したい場合は `recordingState` を見ること。
    var isRecording: Bool { recordingState != .idle }

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
        let shouldActivateWatch = self.modelContext == nil
        self.modelContext = modelContext
        if shouldActivateWatch {
            watchManager.activate()
        }
        recoverIncompleteRoutes()
        refreshHomeRegionMonitoring()
    }

    func recoverIncompleteRoutes() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<RouteRecord>(
            predicate: #Predicate { $0.endDate == nil }
        )
        guard let incomplete = try? modelContext.fetch(descriptor) else { return }

        // 一時停止中のまま終了されたルートを優先して引き継ぐ。複数あれば最新の startDate のものを採用。
        let pausedRoutes = incomplete
            .filter { $0.pausedAt != nil }
            .sorted { $0.startDate > $1.startDate }
        if let resumed = pausedRoutes.first {
            currentRoute = resumed
            recordingState = .paused
            currentCoordinates = resumed.coordinates
            currentDistance = Self.pathDistance(of: currentCoordinates)
            lastAcceptedLocation = nil
            // 残りの paused ルートは混乱の元なので閉じる（通常は1件しかないはずだが念のため）。
            for stray in pausedRoutes.dropFirst() {
                closeStrayRoute(stray)
            }
            // 復元した paused 状態を Watch にも反映する。コールドスタートなら activation 完了時にも
            // 同期されるが、warm start で session がすでに activated の場合の保険として明示的に送る。
            watchManager.sendStatus()
        }

        // 一時停止状態でない未完ルートは自動的に閉じる（従来挙動）。
        // closeStrayRoute が pausedAt を nil にして endDate を確定させた stray ルートを
        // 拾い直して上書きしないよう、endDate がまだ nil のものに限定する。
        for route in incomplete where route.pausedAt == nil && route.endDate == nil {
            guard route.id != currentRoute?.id else { continue }
            let lastTimestamp = route.points.map(\.timestamp).max()
            route.endDate = lastTimestamp ?? route.startDate
        }
        try? modelContext.save()
        notifyRecordingDidChange()
    }

    /// 復元時に競合した一時停止ルートを安全に閉じる。
    /// pausedAt 時点を終了点とみなして endDate を確定させる（pausedDuration はそのまま）。
    private func closeStrayRoute(_ route: RouteRecord) {
        let pausedAt = route.pausedAt
        route.pausedAt = nil
        let lastTimestamp = route.points.map(\.timestamp).max()
        route.endDate = pausedAt ?? lastTimestamp ?? route.startDate
    }

    func requestPermission() {
        clManager.requestAlwaysAuthorization()
    }

    /// 許可が未決定のときだけダイアログを出す。決定済みなら何もしない。
    func requestPermissionIfNeeded() {
        guard authorizationStatus == .notDetermined else { return }
        requestPermission()
    }

    /// 記録を開始できる許可状態か。Watch / CarPlay などリモートからの開始要求のガードに使う。
    /// 許可がないまま開始すると1点も記録されない空のあしあとが残ってしまう。
    var canRecordLocation: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .denied, .notDetermined, .restricted:
            return false
        @unknown default:
            return false
        }
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
        // 記録中（一時停止中含む）はすでに最新位置が手元にあるはずなので、そのまま使う。
        // ※ 一時停止中は startUpdatingLocation を止めているため、clManager.location は最後に取れた点。
        if recordingState != .idle, let coordinate = clManager.location?.coordinate {
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
        currentDistance = 0
        lastAcceptedLocation = nil
        recordingState = .recording
        clManager.startUpdatingLocation()
        watchManager.sendStatus()
        notifyRecordingDidChange()
    }

    /// 一時停止する。GPSの位置更新を止め、再開までの時間を `pausedDuration` に加算するために
    /// `pausedAt` を記録する。アプリが終了されても永続化されているので、起動時に状態復元できる。
    func pauseRecording() {
        guard recordingState == .recording, let route = currentRoute, let modelContext else { return }
        route.pausedAt = Date()
        try? modelContext.save()
        clManager.stopUpdatingLocation()
        recordingState = .paused
        watchManager.sendStatus()
        notifyRecordingDidChange()
    }

    /// 再開する。一時停止していた時間を `pausedDuration` に加算してからGPS再開。
    func resumeRecording() {
        guard recordingState == .paused, let route = currentRoute, let modelContext else { return }
        if let pausedAt = route.pausedAt {
            route.pausedDuration += Date().timeIntervalSince(pausedAt)
        }
        route.pausedAt = nil
        try? modelContext.save()
        // 再開後の最初の点は一時停止前の最終点から大きく動いている可能性があるので、
        // 速度ベースの不正点フィルタを誤発火させないために lastAcceptedLocation をリセットする。
        lastAcceptedLocation = nil
        recordingState = .recording
        clManager.startUpdatingLocation()
        watchManager.sendStatus()
        notifyRecordingDidChange()
    }

    func stopRecording() {
        guard let route = currentRoute, let modelContext else { return }
        // 一時停止中に到着した場合、その時点までの休憩時間を確定させる。
        if let pausedAt = route.pausedAt {
            route.pausedDuration += Date().timeIntervalSince(pausedAt)
            route.pausedAt = nil
        }
        // ポイントが1件以下の場合、スライダーを表示できるよう末尾点を複製する
        if route.points.count == 1, let only = route.points.first {
            let dup = LocationPoint(latitude: only.latitude, longitude: only.longitude, timestamp: Date())
            dup.route = route
            route.points.append(dup)
        }
        route.endDate = Date()
        try? modelContext.save()
        clManager.stopUpdatingLocation()
        recordingState = .idle
        currentRoute = nil
        lastAcceptedLocation = nil
        watchManager.sendStatus()
        notifyRecordingDidChange()
    }

    /// 座標列の総距離。復元時の初期値計算だけに使う（以降は点の追加ごとに加算する）。
    static func pathDistance(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count >= 2 else { return 0 }
        var total: CLLocationDistance = 0
        for index in 1..<coordinates.count {
            let from = CLLocation(
                latitude: coordinates[index - 1].latitude,
                longitude: coordinates[index - 1].longitude
            )
            let to = CLLocation(latitude: coordinates[index].latitude, longitude: coordinates[index].longitude)
            total += to.distance(from: from)
        }
        return total
    }

    private func notifyRecordingDidChange() {
        NotificationCenter.default.post(name: .locationManagerRecordingDidChange, object: self)
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
        // 一時停止中に遅れて配送された位置はルートに加えない。
        guard recordingState == .recording else { return }
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
            if let previous = currentCoordinates.last {
                let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                currentDistance += from.distance(from: location)
            }
            currentCoordinates.append(location.coordinate)
            lastAcceptedLocation = location
            didAddPoint = true
        }

        if didAddPoint {
            try? modelContext.save()
            watchManager.sendStatus()
            notifyRecordingDidChange()
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
