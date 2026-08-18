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

    private enum MapPinKind {
        case start
        case waypoint
        case current
        case parking
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
            // 駐車場表示中はPOIを差し替えない。あしあとの更新で駐車場一覧が消えるのを防ぎつつ、
            // POIの更新を60秒に1回までに抑えるガイドラインにも合わせる。
            // タイトルとボタンだけは更新して、あしあとが出来たらトグルが現れるようにする。
            if updatesMap, mapMode == .footprints {
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
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
        // 同じ内容を入れ直すとCarPlay側が画面を組み直してしまい、その瞬間のタップが
        // 取りこぼされる。表示文字列が変わったときだけ差し替える。
        let itemContents = makeInformationItemContents()
        if itemContents != informationItemContents {
            template.items = itemContents.map { CPInformationItem(title: $0.title, detail: $0.detail) }
            informationItemContents = itemContents
        }
        let actionConfiguration = makeInformationActionConfiguration()
        if actionConfiguration != informationActionConfiguration {
            template.actions = makeActions(for: actionConfiguration)
            informationActionConfiguration = actionConfiguration
        }
    }

    /// 地図(POI)画面を開く。どのモードで開くかは入口ごとに指定する。
    /// 「地図」ボタンは常にあしあと、「駐車場」ボタンは駐車場から開く。
    private func openMapTemplate(mode: MapMode) {
        guard let interfaceController else { return }
        mapMode = mode
        let content = makePointOfInterestContent()
        guard !content.points.isEmpty else {
            presentAlert("位置情報を取得中です")
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

    private func configurePointOfInterestTemplate(_ template: CPPointOfInterestTemplate) {
        let content = makePointOfInterestContent()
        updateMapTemplateChrome(template)
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
        let points = parkingSearch.spots.map { makeParkingPointOfInterest(for: $0) }
        // 一番近い駐車場の詳細カードを開いた状態で見せる。
        return (points, points.isEmpty ? NSNotFound : 0)
    }

    private func makeParkingPointOfInterest(for spot: ParkingSearchService.Spot) -> CPPointOfInterest {
        let distanceText = formatDistance(spot.distance)
        let pointOfInterest = CPPointOfInterest(
            location: spot.mapItem,
            title: spot.name,
            subtitle: distanceText,
            summary: spot.address,
            detailTitle: spot.name,
            detailSubtitle: distanceText,
            detailSummary: spot.address,
            pinImage: makePinImage(for: .parking, selected: false),
            selectedPinImage: makePinImage(for: .parking, selected: true)
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
    private func searchParking(completion: @escaping () -> Void) {
        guard !isSearchingParking else { return }
        guard locationManager.canRecordLocation else {
            locationManager.requestPermissionIfNeeded()
            presentAlert("iPhoneで位置情報を許可してください")
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
                    self.failParkingSearch(message: "現在地を取得できませんでした")
                    return
                }
                self.parkingSearch.searchSpots(around: coordinate) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let spots) where spots.isEmpty:
                        self.failParkingSearch(message: "近くに駐車場が見つかりませんでした")
                    case .success:
                        self.isSearchingParking = false
                        completion()
                    case .failure(let error):
                        print("CarPlay parking search error: \(error.localizedDescription)")
                        self.failParkingSearch(message: "駐車場を検索できませんでした")
                    }
                }
            }
        }
    }

    private func showFootprints() {
        mapMode = .footprints
        guard let pointOfInterestTemplate else { return }
        configurePointOfInterestTemplate(pointOfInterestTemplate)
    }

    /// 検索に失敗したときの後始末。表示は元に戻してから理由を伝える。
    private func failParkingSearch(message: String) {
        isSearchingParking = false
        if let pointOfInterestTemplate {
            configurePointOfInterestTemplate(pointOfInterestTemplate)
        }
        presentAlert(message)
    }

    /// 選んだ駐車場までの案内を地図アプリに渡す。
    /// 起動はCarPlay画面側で開くようscene経由で行う（CarPlay Developer Guideの推奨手順）。
    /// 駐車場一覧は畳まずに残す。満車で戻ってきたときに別の駐車場をすぐ選び直せるようにするため。
    private func startNavigation(to spot: ParkingSearchService.Spot) {
        guard let url = makeDirectionsURL(for: spot.coordinate) else { return }
        guard let scene = templateApplicationScene else {
            presentAlert("地図アプリを開けませんでした")
            return
        }

        scene.open(url, options: nil) { [weak self] success in
            Task { @MainActor in
                guard !success else { return }
                self?.presentAlert("地図アプリを開けませんでした")
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
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
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
        case .parking:
            return makeParkingPinImage(selected: selected)
        }
    }

    /// 駐車場ピン。昼夜どちらの地図でも沈まないよう、白縁付きの塗りに白の「P」を載せる。
    private func makeParkingPinImage(selected: Bool) -> UIImage {
        let size = selected ? CPPointOfInterest.selectedPinImageSize : CPPointOfInterest.pinImageSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let side = min(size.width, size.height) * (selected ? 0.84 : 0.72)
            let rect = CGRect(
                x: (size.width - side) / 2,
                y: (size.height - side) / 2,
                width: side,
                height: side
            )
            let cornerRadius = side * 0.28
            UIColor.systemIndigo.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).fill()

            let lineWidth = max(2, side * 0.1)
            let strokePath = UIBezierPath(
                roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                cornerRadius: cornerRadius
            )
            UIColor.white.setStroke()
            strokePath.lineWidth = lineWidth
            strokePath.stroke()

            let text = "P" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.6, weight: .bold),
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
            presentAlert("iPhoneで位置情報を許可してください")
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
        presentAlert("あしあとを記録しました", returnsToRootAfterDismiss: true)
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
        let alert = CPAlertTemplate(titleVariants: ["到着してよいですか？"], actions: [cancel, arrive])
        interfaceController.presentTemplate(alert, animated: true) { success, error in
            if !success, let error {
                print("CarPlay confirmation alert error: \(error.localizedDescription)")
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

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)時間 \(minutes)分"
        }
        if minutes > 0 {
            return "\(minutes)分 \(seconds)秒"
        }
        return "\(seconds)秒"
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func presentAlert(_ title: String, returnsToRootAfterDismiss: Bool = false) {
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
        let alert = CPAlertTemplate(titleVariants: [title], actions: [close])
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
    }
}
