//
//  CarPlaySceneDelegate.swift
//  KyoNoAshiato
//
//  Created by Codex on 2026/06/29.
//

import CarPlay
import CoreLocation
import MapKit
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var informationTemplate: CPInformationTemplate?
    private var pointOfInterestTemplate: CPPointOfInterestTemplate?
    private var recordingObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var informationActionConfiguration: InformationActionConfiguration?
    private var informationItemContents: [InformationItemContent]?
    private var pinImageCache: [PinImageKey: UIImage] = [:]
    private weak var templateApplicationScene: CPTemplateApplicationScene?
    private var mapMode: MapMode = .footprints
    private var isSearchingParking = false
    private let parkingSearch = ParkingSearchService()
    private let locationManager = LocationManager.shared
    /// 地図をパンしたときの再検索用。パン中は何度も通知が来るので、少し待ってから1回だけ探す。
    private var parkingRegionSearchTimer: Timer?
    private var pendingParkingRegionCenter: CLLocationCoordinate2D?
    /// 最後に駐車場を探した中心。ここからあまり動いていないパンでは探し直さない。
    private var lastParkingSearchCenter: CLLocationCoordinate2D?
    /// 最後にPOIを差し替えた時刻。POIの定期更新を60秒に1回までに抑えるために見る。
    private var lastPointOfInterestUpdateDate: Date?
    /// 最後に情報項目を差し替えた時刻。データの定期更新を10秒に1回までに抑えるために見る。
    private var lastInformationUpdateDate: Date?
    /// POIを入れ替えた直後のカメラ移動をパン操作と誤認しないための無視期間。
    private var ignoresMapRegionChangesUntil: Date?

    /// パンが止まったと判断するまでの待ち時間。
    private static let parkingRegionSearchDelay: TimeInterval = 1.5
    /// driving taskアプリのガイドラインに合わせた、POI差し替えの最短間隔。
    private static let pointOfInterestUpdateInterval: TimeInterval = 60
    /// 同じガイドラインの、データ項目の定期更新の最短間隔。
    private static let informationUpdateInterval: TimeInterval = 10
    /// これ以上中心が動いたら別の場所を見ているとみなす。検索半径(3km)の一部だけ動いても
    /// 同じ駐車場が並ぶだけなので、無駄な差し替えを避ける。
    private static let parkingRegionShiftThreshold: CLLocationDistance = 800
    /// POI差し替えに伴うカメラ移動を無視する時間。
    private static let mapRegionSettleDuration: TimeInterval = 2

    private struct InformationActionConfiguration: Equatable {
        let recordingState: RecordingState
        let hasMapContent: Bool
    }

    private struct InformationItemContent: Equatable {
        let title: String
        let detail: String
    }

    private struct PinImageKey: Hashable {
        let pinKind: MapPinKind
        let selected: Bool
        let userInterfaceStyle: UIUserInterfaceStyle
    }

    /// 地図画面(POIテンプレート)に何を出しているか。ナビバーのボタンで切り替える。
    private enum MapMode {
        case footprints
        case parking
    }

    private enum MapPinKind: Hashable {
        case start
        case waypoint
        case current
        /// 駐車場は詳細カードと対応が取れるよう、距離順の番号をピンに描く。
        case parking(number: Int)
    }

    private struct MapPoint {
        let coordinate: CLLocationCoordinate2D
        let title: String
        let subtitle: String?
        let summary: String?
        let isCurrent: Bool
        let pinKind: MapPinKind
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        connect(interfaceController, scene: templateApplicationScene)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        connect(interfaceController, scene: templateApplicationScene)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        disconnect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        disconnect()
    }

    private func connect(_ interfaceController: CPInterfaceController, scene: CPTemplateApplicationScene) {
        self.interfaceController = interfaceController
        // 駐車場の「案内」で地図アプリをCarPlay画面側に開くためにsceneを持っておく。
        self.templateApplicationScene = scene
        observeRecordingChanges()
        reloadTemplate(animated: false, force: true)
        updateRefreshTimer()
    }

    private func disconnect() {
        stopRefreshTimer()
        cancelParkingRegionSearch()
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
        recordingObserver = nil
        informationTemplate = nil
        pointOfInterestTemplate = nil
        informationActionConfiguration = nil
        interfaceController = nil
        templateApplicationScene = nil
        mapMode = .footprints
        isSearchingParking = false
        lastParkingSearchCenter = nil
        lastPointOfInterestUpdateDate = nil
        lastInformationUpdateDate = nil
        ignoresMapRegionChangesUntil = nil
        informationItemContents = nil
        pinImageCache = [:]
    }

    private func observeRecordingChanges() {
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
        recordingObserver = NotificationCenter.default.addObserver(
            forName: .locationManagerRecordingDidChange,
            object: locationManager,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.refreshCarPlayUI()
            }
        }
    }

    private func refreshCarPlayUI(updatesMap: Bool = true) {
        guard let informationTemplate else {
            reloadTemplate(animated: false, force: true)
            return
        }

        configureInformationTemplate(informationTemplate)

        // 閉じられた地図画面は作り直さない。表示されていないのにピン画像の描画まで走ってしまう。
        if let pointOfInterestTemplate, interfaceController?.topTemplate === pointOfInterestTemplate {
            // 駐車場表示中はPOIを差し替えない。あしあとの更新で駐車場一覧が消えるのを防ぐため。
            // あしあと表示中も、POIの定期更新は60秒に1回までに抑える（ガイドライン）。
            // 位置は毎秒何度も届くので、ここを素通しにすると制限を大きく超えてしまう。
            // タイトルとボタンだけは更新して、あしあとが出来たらトグルが現れるようにする。
            if updatesMap, mapMode == .footprints, allowsPeriodicPointOfInterestUpdate {
                configurePointOfInterestTemplate(pointOfInterestTemplate)
            } else {
                updateMapTemplateChrome(pointOfInterestTemplate)
            }
        }

        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        if locationManager.recordingState != .idle {
            startRefreshTimer()
        } else {
            stopRefreshTimer()
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        // ガイドラインの「データ項目の更新は10秒に1回まで」に合わせた間隔。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.informationUpdateInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshCarPlayUI(updatesMap: false)
            }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func reloadTemplate(animated: Bool, force: Bool = false) {
        guard let interfaceController else { return }

        let template = informationTemplate ?? makeInformationTemplate()
        configureInformationTemplate(template)
        informationTemplate = template
        guard force || interfaceController.rootTemplate !== template else { return }
        interfaceController.setRootTemplate(template, animated: animated) { success, error in
            if !success, let error {
                print("CarPlay root template error: \(error.localizedDescription)")
            }
        }
    }

    private func configureInformationTemplate(_ template: CPInformationTemplate) {
        // 記録状態が変わったのはユーザーの操作起因なので、ボタンは待たせずに差し替える。
        let actionConfiguration = makeInformationActionConfiguration()
        let isStateChange = actionConfiguration != informationActionConfiguration
        if isStateChange {
            template.actions = makeActions(for: actionConfiguration)
            informationActionConfiguration = actionConfiguration
        }

        // ガイドラインではデータ項目の定期更新は10秒に1回まで。状態が変わったときだけ即時に出す。
        guard isStateChange || allowsPeriodicInformationUpdate else { return }

        // 同じ内容を入れ直すとCarPlay側が画面を組み直してしまい、その瞬間のタップが
        // 取りこぼされる。表示文字列が変わったときだけ差し替える。
        let itemContents = makeInformationItemContents()
        if itemContents != informationItemContents {
            template.items = itemContents.map { CPInformationItem(title: $0.title, detail: $0.detail) }
            informationItemContents = itemContents
            lastInformationUpdateDate = Date()
        }
    }

    private var allowsPeriodicInformationUpdate: Bool {
        guard let lastInformationUpdateDate else { return true }
        return Date().timeIntervalSince(lastInformationUpdateDate) >= Self.informationUpdateInterval
    }

    private var allowsPeriodicPointOfInterestUpdate: Bool {
        guard let lastPointOfInterestUpdateDate else { return true }
        return Date().timeIntervalSince(lastPointOfInterestUpdateDate) >= Self.pointOfInterestUpdateInterval
    }

    /// 地図(POI)画面を開く。どのモードで開くかは入口ごとに指定する。
    /// 「地図」ボタンは常にあしあと、「駐車場」ボタンは駐車場から開く。
    private func openMapTemplate(mode: MapMode) {
        guard let interfaceController else { return }
        mapMode = mode
        let content = makePointOfInterestContent()
        guard !content.points.isEmpty else {
            presentAlert("位置情報を取得中です", shortTitle: "位置情報を取得中")
            return
        }

        let template = pointOfInterestTemplate ?? makePointOfInterestTemplate()
        configurePointOfInterestTemplate(template)
        pointOfInterestTemplate = template

        if let topTemplate = interfaceController.topTemplate, topTemplate === template {
            return
        }

        interfaceController.pushTemplate(template, animated: true) { success, error in
            if !success, let error {
                print("CarPlay map push error: \(error.localizedDescription)")
            }
        }
    }

    private func makePointOfInterestTemplate() -> CPPointOfInterestTemplate {
        let content = makePointOfInterestContent()
        let template = CPPointOfInterestTemplate(
            title: mapTemplateTitle,
            pointsOfInterest: content.points,
            selectedIndex: content.selectedIndex
        )
        template.pointOfInterestDelegate = self
        return template
    }

    /// `preservesMapRegion` が true のときは選択を付けずに差し替える。パンで探し直したときに、
    /// カメラが選択中のPOIへ飛んでユーザーが見ていた場所から離れてしまうのを防ぐため。
    private func configurePointOfInterestTemplate(
        _ template: CPPointOfInterestTemplate,
        preservesMapRegion: Bool = false
    ) {
        var content = makePointOfInterestContent()
        if preservesMapRegion {
            content.selectedIndex = NSNotFound
        }
        updateMapTemplateChrome(template)
        lastPointOfInterestUpdateDate = Date()
        // 差し替えに伴うカメラ移動はパン操作として扱わない。
        ignoresMapRegionChangesUntil = Date().addingTimeInterval(Self.mapRegionSettleDuration)
        template.setPointsOfInterest(content.points, selectedIndex: content.selectedIndex)
    }

    /// タイトルとナビバーのボタンだけを最新化する。POIの差し替えを伴わないので検索中の表示更新に使う。
    private func updateMapTemplateChrome(_ template: CPPointOfInterestTemplate) {
        template.title = mapTemplateTitle
        // パン操作中の「完了」など、CarPlay標準の地図UIを優先して見せるため先頭側は空けておく。
        template.leadingNavigationBarButtons = []
        template.trailingNavigationBarButtons = [makeMapModeBarButton()].compactMap { $0 }
    }

    private var mapTemplateTitle: String {
        if isSearchingParking {
            return "駐車場を検索中…"
        }
        switch mapMode {
        case .footprints:
            return "地図"
        case .parking:
            return "駐車場"
        }
    }

    /// あしあと表示と駐車場表示を同じテンプレート内で切り替えるボタン。
    /// driving taskアプリの階層上限(ルート込み2枚)に収めるため、画面を積まずに内容を差し替える。
    /// 出発前など、切り替え先に見せるものが無いときはボタン自体を出さない。
    private func makeMapModeBarButton() -> CPBarButton? {
        let button: CPBarButton
        switch mapMode {
        case .footprints:
            button = CPBarButton(title: "駐車場") { [weak self] _ in
                Task { @MainActor in
                    self?.showParkingSpots()
                }
            }
        case .parking:
            // あしあと画面は記録中(一時停止含む)だけ。情報画面の「地図」ボタンと同じ条件に揃える。
            guard locationManager.recordingState != .idle, hasMapContent else { return nil }
            button = CPBarButton(title: "あしあと") { [weak self] _ in
                Task { @MainActor in
                    self?.showFootprints()
                }
            }
        }
        button.isEnabled = !isSearchingParking
        return button
    }

    private func makePointOfInterestContent() -> (points: [CPPointOfInterest], selectedIndex: Int) {
        if mapMode == .parking {
            return makeParkingPointOfInterestContent()
        }

        let mapPoints = makeMapPoints()
        let points = mapPoints.map { point in
            makePointOfInterest(
                coordinate: point.coordinate,
                title: point.title,
                subtitle: point.subtitle,
                summary: point.summary,
                pinKind: point.pinKind
            )
        }
        let selectedIndex = mapPoints.firstIndex { $0.isCurrent } ?? NSNotFound
        return (points, selectedIndex)
    }

    private func makeParkingPointOfInterestContent() -> (points: [CPPointOfInterest], selectedIndex: Int) {
        let points = parkingSearch.spots.enumerated().map { index, spot in
            makeParkingPointOfInterest(for: spot, number: index + 1)
        }
        // 一番近い駐車場の詳細カードを開いた状態で見せる。
        return (points, points.isEmpty ? NSNotFound : 0)
    }

    /// 番号はピンに描く数字と揃える。同じ番号を見出しにも出すことで、
    /// Pが複数並んでいてもカードがどのピンの話なのか分かるようにする。
    private func makeParkingPointOfInterest(
        for spot: ParkingSearchService.Spot,
        number: Int
    ) -> CPPointOfInterest {
        let distanceText = formatDistance(spot.distance)
        let numberedName = "\(number). \(spot.name)"
        let pointOfInterest = CPPointOfInterest(
            location: spot.mapItem,
            title: numberedName,
            subtitle: distanceText,
            summary: spot.address,
            detailTitle: numberedName,
            detailSubtitle: distanceText,
            detailSummary: spot.address,
            pinImage: makePinImage(for: .parking(number: number), selected: false),
            selectedPinImage: makePinImage(for: .parking(number: number), selected: true)
        )
        pointOfInterest.primaryButton = CPTextButton(title: "案内", textStyle: .confirm) { [weak self] _ in
            Task { @MainActor in
                self?.startNavigation(to: spot)
            }
        }
        return pointOfInterest
    }

    /// 地図画面を開いたまま駐車場表示に切り替える。
    /// 検索中はあしあとの表示を残したまま、タイトルとボタンだけで状態を伝える。
    private func showParkingSpots() {
        searchParking { [weak self] in
            guard let self, let pointOfInterestTemplate = self.pointOfInterestTemplate else { return }
            self.mapMode = .parking
            self.configurePointOfInterestTemplate(pointOfInterestTemplate)
        }
    }

    /// 情報画面から駐車場を直接開く。あしあとの地図がまだ無い待機中でも使えるように、
    /// 検索が終わってから地図(POI)画面を積む。
    private func openParkingTemplate() {
        searchParking { [weak self] in
            self?.openMapTemplate(mode: .parking)
        }
    }

    /// 現在地を取り直してから駐車場を検索する。見つかったときだけ completion を呼ぶ。
    /// `center` を渡すとその周辺を探す（地図をパンしたときの再検索用）。距離と番号は
    /// どちらの場合も運転者の現在地から測る。`silently` はパン起因の検索で使い、
    /// 失敗しても運転中にアラートを出さないためのもの。
    private func searchParking(
        around center: CLLocationCoordinate2D? = nil,
        silently: Bool = false,
        completion: @escaping () -> Void
    ) {
        guard !isSearchingParking else { return }
        guard locationManager.canRecordLocation else {
            guard !silently else { return }
            // ガイドラインにより、CarPlayの文言でiPhoneの操作を促してはいけない。
            // 状態だけ伝えて、許可の要求は黙って出す（安全なときに気づいてもらう）。
            locationManager.requestPermissionIfNeeded()
            presentAlert(
                "位置情報が許可されていないため駐車場を検索できません",
                shortTitle: "位置情報が未許可です"
            )
            return
        }

        isSearchingParking = true
        if let pointOfInterestTemplate {
            updateMapTemplateChrome(pointOfInterestTemplate)
        }

        locationManager.captureCurrentLocation { coordinate in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let coordinate else {
                    // 現在地が取れないと距離も番号も出せないので、パン起因なら黙って諦める。
                    self.failParkingSearch(
                        message: "現在地を取得できませんでした",
                        shortMessage: "現在地が不明です",
                        silently: silently
                    )
                    return
                }
                let searchCenter = center ?? coordinate
                self.parkingSearch.searchSpots(around: searchCenter, measuringFrom: coordinate) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let spots) where spots.isEmpty:
                        self.failParkingSearch(
                            message: center == nil ? "近くに駐車場が見つかりませんでした" : "この辺りに駐車場が見つかりませんでした",
                            shortMessage: "駐車場なし",
                            silently: silently
                        )
                    case .success:
                        self.isSearchingParking = false
                        self.lastParkingSearchCenter = searchCenter
                        completion()
                    case .failure(let error):
                        print("CarPlay parking search error: \(error.localizedDescription)")
                        self.failParkingSearch(
                            message: "駐車場を検索できませんでした",
                            shortMessage: "検索できません",
                            silently: silently
                        )
                    }
                }
            }
        }
    }

    /// 地図をパンされたときの再検索。見ている場所が変わったぶんだけPOIを差し替える。
    private func handleParkingMapRegionChange(_ region: MKCoordinateRegion) {
        guard mapMode == .parking, !isSearchingParking else { return }
        // 自分でPOIを入れ替えた直後のカメラ移動は、ユーザーのパンではないので無視する。
        if let ignoresMapRegionChangesUntil, Date() < ignoresMapRegionChangesUntil { return }
        let center = region.center
        if let lastParkingSearchCenter,
           Self.distance(from: lastParkingSearchCenter, to: center) < Self.parkingRegionShiftThreshold {
            return
        }
        // すでに出している駐車場の近くを見ているだけなら、探し直しても同じ顔ぶれになる。
        // カードやピンを選んでカメラが寄った場合もここで弾ける。
        let isNearShownSpot = parkingSearch.spots.contains { spot in
            Self.distance(from: spot.coordinate, to: center) < Self.parkingRegionShiftThreshold
        }
        if isNearShownSpot { return }
        pendingParkingRegionCenter = center
        scheduleParkingRegionSearch()
    }

    /// パン中は通知が連続で来るので、止まってから探す。前回の差し替えから60秒経つまでは待つ。
    private func scheduleParkingRegionSearch() {
        var delay = Self.parkingRegionSearchDelay
        if let lastPointOfInterestUpdateDate {
            let elapsed = Date().timeIntervalSince(lastPointOfInterestUpdateDate)
            delay = max(delay, Self.pointOfInterestUpdateInterval - elapsed)
        }

        parkingRegionSearchTimer?.invalidate()
        parkingRegionSearchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.runPendingParkingRegionSearch()
            }
        }
    }

    private func cancelParkingRegionSearch() {
        parkingRegionSearchTimer?.invalidate()
        parkingRegionSearchTimer = nil
        pendingParkingRegionCenter = nil
    }

    private func runPendingParkingRegionSearch() {
        parkingRegionSearchTimer = nil
        guard mapMode == .parking, let center = pendingParkingRegionCenter else { return }
        pendingParkingRegionCenter = nil
        // 待っている間に地図画面が閉じられていたら、見えないPOIを作り直すだけなのでやめる。
        guard let pointOfInterestTemplate,
              interfaceController?.topTemplate === pointOfInterestTemplate else { return }

        searchParking(around: center, silently: true) { [weak self] in
            guard let self,
                  self.mapMode == .parking,
                  let pointOfInterestTemplate = self.pointOfInterestTemplate else { return }
            // 番号は付け直しになるが、選択を付けずに差し替えてユーザーが見ている場所は動かさない。
            self.configurePointOfInterestTemplate(pointOfInterestTemplate, preservesMapRegion: true)
        }
    }

    private static func distance(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
    }

    private func showFootprints() {
        cancelParkingRegionSearch()
        mapMode = .footprints
        guard let pointOfInterestTemplate else { return }
        configurePointOfInterestTemplate(pointOfInterestTemplate)
    }

    /// 検索に失敗したときの後始末。表示は元に戻してから理由を伝える。
    /// パン起因(`silently`)のときは今見ている一覧を壊さないよう、タイトルとボタンだけ戻す。
    private func failParkingSearch(message: String, shortMessage: String? = nil, silently: Bool = false) {
        isSearchingParking = false
        guard !silently else {
            if let pointOfInterestTemplate {
                updateMapTemplateChrome(pointOfInterestTemplate)
            }
            return
        }
        if let pointOfInterestTemplate {
            configurePointOfInterestTemplate(pointOfInterestTemplate)
        }
        presentAlert(message, shortTitle: shortMessage)
    }

    /// 選んだ駐車場までの案内を地図アプリに渡す。
    /// 起動はCarPlay画面側で開くようscene経由で行う（CarPlay Developer Guideの推奨手順）。
    /// 駐車場一覧は畳まずに残す。満車で戻ってきたときに別の駐車場をすぐ選び直せるようにするため。
    private func startNavigation(to spot: ParkingSearchService.Spot) {
        guard let url = makeDirectionsURL(for: spot.coordinate) else { return }
        guard let scene = templateApplicationScene else {
            presentAlert("地図アプリを開けませんでした", shortTitle: "地図を開けません")
            return
        }

        scene.open(url, options: nil) { [weak self] success in
            Task { @MainActor in
                guard !success else { return }
                self?.presentAlert("地図アプリを開けませんでした", shortTitle: "地図を開けません")
            }
        }
    }

    private func makeDirectionsURL(for coordinate: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        components.queryItems = [
            URLQueryItem(
                name: "daddr",
                value: String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
            ),
            // 車での経路案内を指定する。
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        return components.url
    }

    private func makeMapPoints() -> [MapPoint] {
        if let route = locationManager.currentRoute {
            let sortedPoints = route.points.sorted { $0.timestamp < $1.timestamp }
            guard let first = sortedPoints.first else { return [] }

            guard sortedPoints.count >= 2, let latest = sortedPoints.last else {
                return [
                    MapPoint(
                        coordinate: coordinate(for: first),
                        title: "現在地",
                        subtitle: stateText,
                        summary: nil,
                        isCurrent: true,
                        pinKind: .current
                    )
                ]
            }

            let start = MapPoint(
                coordinate: coordinate(for: first),
                title: "出発地点",
                subtitle: formatTime(route.startDate),
                summary: nil,
                isCurrent: false,
                pinKind: .start
            )
            let current = MapPoint(
                coordinate: coordinate(for: latest),
                title: "現在地",
                subtitle: stateText,
                summary: nil,
                isCurrent: true,
                pinKind: .current
            )

            if isSameCoordinate(start.coordinate, current.coordinate) {
                return [current]
            }
            let waypoints = makeWaypointMapPoints(
                from: sortedPoints,
                startCoordinate: start.coordinate,
                currentCoordinate: current.coordinate
            )
            return [start] + waypoints + [current]
        }

        if let latest = locationManager.currentCoordinates.last {
            return [
                MapPoint(
                    coordinate: latest,
                    title: "現在地",
                    subtitle: nil,
                    summary: nil,
                    isCurrent: true,
                    pinKind: .current
                )
            ]
        }

        return []
    }

    /// 途中経路を距離ベースで間引いて経由地点ピンを作る。
    /// CPPointOfInterestTemplateはPOIを最大12個までしか表示できないため、
    /// 出発地点・現在地の2枠を除いた最大10点に均等配分する。
    private func makeWaypointMapPoints(
        from sortedPoints: [LocationPoint],
        startCoordinate: CLLocationCoordinate2D,
        currentCoordinate: CLLocationCoordinate2D,
        maxCount: Int = 10
    ) -> [MapPoint] {
        guard sortedPoints.count > 2, maxCount > 0 else { return [] }

        var cumulativeDistances: [CLLocationDistance] = [0]
        cumulativeDistances.reserveCapacity(sortedPoints.count)
        var previousLocation = CLLocation(
            latitude: sortedPoints[0].latitude,
            longitude: sortedPoints[0].longitude
        )
        for point in sortedPoints.dropFirst() {
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            cumulativeDistances.append(cumulativeDistances.last! + location.distance(from: previousLocation))
            previousLocation = location
        }
        guard let totalDistance = cumulativeDistances.last, totalDistance > 0 else { return [] }

        var waypoints: [MapPoint] = []
        var usedIndices = Set<Int>()
        for step in 1...maxCount {
            let targetDistance = totalDistance * Double(step) / Double(maxCount + 1)
            var bestIndex = 1
            var bestDifference = CLLocationDistance.greatestFiniteMagnitude
            for index in 1..<(sortedPoints.count - 1) {
                let difference = abs(cumulativeDistances[index] - targetDistance)
                if difference < bestDifference {
                    bestDifference = difference
                    bestIndex = index
                }
            }
            guard !usedIndices.contains(bestIndex) else { continue }

            let point = sortedPoints[bestIndex]
            let waypointCoordinate = coordinate(for: point)
            // 出発地点・現在地・既存の経由地点と重なる点は間引く(停止中の重複サンプル対策)。
            if isSameCoordinate(waypointCoordinate, startCoordinate)
                || isSameCoordinate(waypointCoordinate, currentCoordinate)
                || waypoints.contains(where: { isSameCoordinate(waypointCoordinate, $0.coordinate) }) {
                continue
            }

            usedIndices.insert(bestIndex)
            waypoints.append(
                MapPoint(
                    coordinate: waypointCoordinate,
                    title: "経由地点",
                    subtitle: formatTime(point.timestamp),
                    summary: nil,
                    isCurrent: false,
                    pinKind: .waypoint
                )
            )
        }
        return waypoints
    }

    private func isSameCoordinate(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000001 && abs(lhs.longitude - rhs.longitude) < 0.000001
    }

    private func coordinate(for point: LocationPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func makePointOfInterest(
        coordinate: CLLocationCoordinate2D,
        title: String,
        subtitle: String?,
        summary: String?,
        pinKind: MapPinKind
    ) -> CPPointOfInterest {
        // iOS 26でMKPlacemark経由の初期化は非推奨。住所は使わないので座標だけ渡す。
        let mapItem = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil
        )
        return CPPointOfInterest(
            location: mapItem,
            title: title,
            subtitle: subtitle,
            summary: summary,
            detailTitle: title,
            detailSubtitle: subtitle,
            detailSummary: summary,
            pinImage: makePinImage(for: pinKind, selected: false),
            selectedPinImage: makePinImage(for: pinKind, selected: true)
        )
    }

    private func makePinImage(for pinKind: MapPinKind, selected: Bool) -> UIImage? {
        let key = PinImageKey(
            pinKind: pinKind,
            selected: selected,
            userInterfaceStyle: interfaceController?.carTraitCollection.userInterfaceStyle ?? .unspecified
        )
        if let cached = pinImageCache[key] {
            return cached
        }
        let image = drawPinImage(for: pinKind, selected: selected)
        if let image {
            pinImageCache[key] = image
        }
        return image
    }

    private func drawPinImage(for pinKind: MapPinKind, selected: Bool) -> UIImage? {
        switch pinKind {
        case .start:
            return nil
        case .current:
            return makeDotPinImage(
                fillColor: .systemBlue,
                diameterRatio: selected ? 0.62 : 0.52,
                hasHalo: selected,
                selected: selected
            )
        case .waypoint:
            return makeFootprintPinImage(selected: selected)
        case .parking(let number):
            return makeParkingPinImage(number: number, selected: selected)
        }
    }

    /// 駐車場ピン。昼夜どちらの地図でも沈まないよう、白縁付きの塗りに白の数字を載せる。
    /// 数字は詳細カードの見出しと同じ距離順の番号。選択中のピンだけは色を変えて大きく描き、
    /// Pが密集していても「いま見ているカードのピンはどれか」が一目で分かるようにする。
    private func makeParkingPinImage(number: Int, selected: Bool) -> UIImage {
        let size = selected ? CPPointOfInterest.selectedPinImageSize : CPPointOfInterest.pinImageSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let base = min(size.width, size.height)
            // 数字を大きく取りたいので枠いっぱいに描く。選択中はリング分だけ内側に寄せる。
            let side = base * (selected ? 0.8 : 0.74)
            let rect = CGRect(
                x: (size.width - side) / 2,
                y: (size.height - side) / 2,
                width: side,
                height: side
            )
            let cornerRadius = side * 0.28

            if selected {
                // 選択中は淡いリングを後ろに敷いて、まわりの未選択ピンから浮かせる。
                UIColor.systemOrange.withAlphaComponent(0.28).setFill()
                let haloSide = base * 0.98
                let haloRect = CGRect(
                    x: (size.width - haloSide) / 2,
                    y: (size.height - haloSide) / 2,
                    width: haloSide,
                    height: haloSide
                )
                UIBezierPath(roundedRect: haloRect, cornerRadius: haloSide * 0.28).fill()
            }

            let fillColor: UIColor = selected ? .systemOrange : .systemIndigo
            fillColor.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).fill()

            let lineWidth = max(2, side * 0.1)
            let strokePath = UIBezierPath(
                roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                cornerRadius: cornerRadius
            )
            UIColor.white.setStroke()
            strokePath.lineWidth = lineWidth
            strokePath.stroke()

            let text = "\(number)" as NSString
            // 2桁でも縁に食い込まないよう、桁数で文字サイズを落とす。
            let fontRatio: CGFloat = text.length > 1 ? 0.46 : 0.62
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: side * fontRatio, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                in: CGRect(
                    x: rect.midX - textSize.width / 2,
                    y: rect.midY - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                ),
                withAttributes: attributes
            )
        }
    }

    private func makeFootprintPinImage(selected: Bool) -> UIImage {
        let size = selected ? CPPointOfInterest.selectedPinImageSize : CPPointOfInterest.pinImageSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let fontSize = min(size.width, size.height) * (selected ? 0.72 : 0.58)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize)
            ]
            let text = "👣" as NSString
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
            // 絵文字は黒いシルエットで地図上では重すぎるため、
            // アルファだけ残して昼夜どちらの地図でも見える明るめのグレーに置き換える。
            UIColor(white: 0.78, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size), blendMode: .sourceIn)
        }
    }

    private func makeDotPinImage(
        fillColor: UIColor,
        diameterRatio: CGFloat,
        hasHalo: Bool,
        selected: Bool
    ) -> UIImage {
        let size = selected ? CPPointOfInterest.selectedPinImageSize : CPPointOfInterest.pinImageSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let diameter = min(size.width, size.height) * diameterRatio
            let circleRect = CGRect(
                x: (size.width - diameter) / 2,
                y: (size.height - diameter) / 2,
                width: diameter,
                height: diameter
            )

            if hasHalo {
                fillColor.withAlphaComponent(0.22).setFill()
                let haloDiameter = min(size.width, size.height) * 0.9
                let haloRect = CGRect(
                    x: (size.width - haloDiameter) / 2,
                    y: (size.height - haloDiameter) / 2,
                    width: haloDiameter,
                    height: haloDiameter
                )
                UIBezierPath(ovalIn: haloRect).fill()
            }

            fillColor.setFill()
            UIBezierPath(ovalIn: circleRect).fill()

            UIColor.white.setStroke()
            let lineWidth = max(2, diameter * 0.1)
            let strokeRect = circleRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = UIBezierPath(ovalIn: strokeRect)
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    private func makeInformationTemplate() -> CPInformationTemplate {
        CPInformationTemplate(
            title: "今日のあしあと",
            layout: .twoColumn,
            items: makeInformationItems(),
            actions: makeActions()
        )
    }

    private func makeInformationItems() -> [CPInformationItem] {
        makeInformationItemContents().map { CPInformationItem(title: $0.title, detail: $0.detail) }
    }

    private func makeInformationItemContents() -> [InformationItemContent] {
        let route = locationManager.currentRoute
        // 距離は LocationManager が加算しながら持っているものを使う。
        // route.totalDistance は毎回全点をなめるため、毎秒の更新には重すぎる。
        let distance = route.map { _ in formatDistance(locationManager.currentDistance) } ?? "-"
        let startTime = route.map { formatTime($0.startDate) } ?? "-"
        let elapsed = route.map { formatDuration(activeDuration(for: $0)) } ?? "-"
        let paused = route.map { formatDuration(pausedDuration(for: $0)) } ?? "-"

        return [
            InformationItemContent(title: "状態", detail: stateText),
            InformationItemContent(title: "開始", detail: startTime),
            InformationItemContent(title: "距離", detail: distance),
            InformationItemContent(title: "休憩時間", detail: paused),
            InformationItemContent(title: "移動時間", detail: elapsed),
        ]
    }

    private func makeInformationActionConfiguration() -> InformationActionConfiguration {
        InformationActionConfiguration(
            recordingState: locationManager.recordingState,
            hasMapContent: hasMapContent
        )
    }

    private func makeActions() -> [CPTextButton] {
        makeActions(for: makeInformationActionConfiguration())
    }

    private func makeActions(for configuration: InformationActionConfiguration) -> [CPTextButton] {
        switch configuration.recordingState {
        case .idle:
            return [
                CPTextButton(title: "出発", textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in
                        self?.startRecordingFromCarPlay()
                    }
                },
                makeParkingTextButton(),
            ]
        case .recording:
            var actions = [
                CPTextButton(title: "一時停止", textStyle: .normal) { [weak self] _ in
                    Task { @MainActor in
                        self?.locationManager.pauseRecording()
                        self?.refreshCarPlayUI()
                    }
                },
                CPTextButton(title: "到着", textStyle: .cancel) { [weak self] _ in
                    Task { @MainActor in
                        self?.confirmStopRecordingFromCarPlay()
                    }
                },
            ]
            if configuration.hasMapContent {
                actions.append(makeMapTextButton())
            }
            return actions
        case .paused:
            var actions = [
                CPTextButton(title: "再開", textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in
                        self?.locationManager.resumeRecording()
                        self?.refreshCarPlayUI()
                    }
                },
                CPTextButton(title: "到着", textStyle: .cancel) { [weak self] _ in
                    Task { @MainActor in
                        self?.confirmStopRecordingFromCarPlay()
                    }
                },
            ]
            if configuration.hasMapContent {
                actions.append(makeMapTextButton())
            }
            return actions
        }
    }

    /// 記録中は情報画面のボタンが上限(3個)に達するため、待機中だけ置く駐車場への入口。
    private func makeParkingTextButton() -> CPTextButton {
        CPTextButton(title: "駐車場", textStyle: .normal) { [weak self] _ in
            Task { @MainActor in
                self?.openParkingTemplate()
            }
        }
    }

    private func makeMapTextButton() -> CPTextButton {
        CPTextButton(title: "地図", textStyle: .normal) { [weak self] _ in
            Task { @MainActor in
                self?.openMapTemplate(mode: .footprints)
            }
        }
    }

    /// 地図に出せるものがあるか。毎秒のボタン更新から呼ばれるので、
    /// makeMapPoints() のような点数に比例する処理はここでは使わない。
    private var hasMapContent: Bool {
        !locationManager.currentCoordinates.isEmpty
    }

    private func startRecordingFromCarPlay() {
        guard locationManager.canRecordLocation else {
            locationManager.requestPermissionIfNeeded()
            presentAlert(
                "位置情報が許可されていないため記録を開始できません",
                shortTitle: "位置情報が未許可です"
            )
            return
        }

        locationManager.startRecording()
        refreshCarPlayUI()
    }

    private func stopRecordingFromCarPlay() {
        guard locationManager.currentRoute != nil else {
            refreshCarPlayUI()
            return
        }
        locationManager.stopRecording()
        refreshCarPlayUI()
        presentAlert("あしあとを記録しました", shortTitle: "記録しました", returnsToRootAfterDismiss: true)
    }

    private func confirmStopRecordingFromCarPlay() {
        guard locationManager.currentRoute != nil else {
            refreshCarPlayUI()
            return
        }
        guard let interfaceController else { return }
        let cancel = CPAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate()
            }
        }
        let arrive = CPAlertAction(title: "到着する", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate {
                    self?.stopRecordingFromCarPlay()
                }
            }
        }
        // 記録を確定させる確認なので、ガイドラインが確認用途に挙げているaction sheetを使う。
        let confirmation = CPActionSheetTemplate(
            title: "到着",
            message: "あしあとの記録を終了しますか？",
            actions: [cancel, arrive]
        )
        interfaceController.presentTemplate(confirmation, animated: true) { success, error in
            if !success, let error {
                print("CarPlay confirmation error: \(error.localizedDescription)")
            }
        }
    }

    private var stateText: String {
        switch locationManager.recordingState {
        case .idle:
            return "待機中"
        case .recording:
            return "あしあと中"
        case .paused:
            return "一時停止中"
        }
    }

    private func activeDuration(for route: RouteRecord) -> TimeInterval {
        var duration = Date().timeIntervalSince(route.startDate) - route.pausedDuration
        if let pausedAt = route.pausedAt {
            duration -= Date().timeIntervalSince(pausedAt)
        }
        return max(0, duration)
    }

    private func pausedDuration(for route: RouteRecord) -> TimeInterval {
        var duration = route.pausedDuration
        if let pausedAt = route.pausedAt {
            duration += Date().timeIntervalSince(pausedAt)
        }
        return max(0, duration)
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }

    /// 10秒に1回しか更新できないので、秒は出さずに分単位で見せる。
    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval.rounded()) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)時間 \(minutes)分"
        }
        if totalMinutes > 0 {
            return "\(minutes)分"
        }
        return "1分未満"
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// `shortTitle` は画面の狭い車向けの短い言い回し。CarPlayは入る中で一番長いものを選ぶので、
    /// 長い順に渡す（ヘッダの指定は "ordered longest to shortest"）。
    private func presentAlert(
        _ title: String,
        shortTitle: String? = nil,
        returnsToRootAfterDismiss: Bool = false
    ) {
        guard let interfaceController else { return }
        let close = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate {
                    guard returnsToRootAfterDismiss else { return }
                    self?.interfaceController?.popToRootTemplate(animated: true) { success, error in
                        if !success, let error {
                            print("CarPlay pop to root error: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        let alert = CPAlertTemplate(
            titleVariants: [title, shortTitle].compactMap { $0 },
            actions: [close]
        )
        interfaceController.presentTemplate(alert, animated: true) { success, error in
            if !success, let error {
                print("CarPlay alert error: \(error.localizedDescription)")
            }
        }
    }

    private func dismissPresentedTemplate(completion: (() -> Void)? = nil) {
        interfaceController?.dismissTemplate(animated: true) { success, error in
            if !success, let error {
                print("CarPlay alert dismiss error: \(error.localizedDescription)")
            }
            completion?()
        }
    }
}

extension CarPlaySceneDelegate: CPPointOfInterestTemplateDelegate {
    func pointOfInterestTemplate(
        _ pointOfInterestTemplate: CPPointOfInterestTemplate,
        didChangeMapRegion region: MKCoordinateRegion
    ) {
        handleParkingMapRegionChange(region)
    }

    /// 詳細パネルを開いたら、パンで予約していた差し替えは取り下げる。
    /// 差し替えると選択が外れてパネルが閉じてしまい、読んでいる途中で消えるのを防ぐため。
    func pointOfInterestTemplate(
        _ pointOfInterestTemplate: CPPointOfInterestTemplate,
        didSelectPointOfInterest pointOfInterest: CPPointOfInterest
    ) {
        cancelParkingRegionSearch()
    }
}
