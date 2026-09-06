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
    /// 地図画面に出している場所のカテゴリ。あしあとの表示はやめたので常にどれかを指す。
    private var placeCategory: PlaceSearchService.Category = .parking
    private var isSearchingPlaces = false
    /// 検索中のカテゴリ。タイトルに「駐車場を検索中…」と出すために持つ。
    private var searchingCategory: PlaceSearchService.Category?
    /// カテゴリごとに1つ持つ。キャッシュ（60秒・中心300m）もカテゴリ単位で独立させる。
    private let placeSearches: [PlaceSearchService.Category: PlaceSearchService] = [
        .parking: PlaceSearchService(category: .parking),
        .fuel: PlaceSearchService(category: .fuel),
        .evCharger: PlaceSearchService(category: .evCharger),
    ]
    private let locationManager = LocationManager.shared
    /// 地図をパンしたときの再検索用。パン中は何度も通知が来るので、少し待ってから1回だけ探す。
    private var regionSearchTimer: Timer?
    private var pendingRegionCenter: CLLocationCoordinate2D?
    /// 最後に駐車場を探した中心。ここからあまり動いていないパンでは探し直さない。
    private var lastPlaceSearchCenter: CLLocationCoordinate2D?
    /// 最後にPOIを差し替えた時刻。POIの定期更新を60秒に1回までに抑えるために見る。
    private var lastPointOfInterestUpdateDate: Date?
    /// 最後に情報項目を差し替えた時刻。データの定期更新を10秒に1回までに抑えるために見る。
    private var lastInformationUpdateDate: Date?
    /// 地図画面のタイトルとボタンの現在の内容。変化が無いのに入れ直さないために持つ。
    private var mapChromeState: MapChromeState?
    /// 選択の反映でループしないように、直前に反映した時刻を持つ。
    private var lastSelectionReapplyDate: Date?
    /// リストで実際に選ばれたかどうか。開いた直後はテンプレート側の選択を付けない。
    /// 選択を付けるとリストがその項目まで自動でスクロールし、先頭から始まらないため。
    private var isPlaceSelected = false
    /// 強調表示する駐車場の番号(0始まり)。nil は強調なし。
    /// テンプレートは選択に応じてピン画像を描き分けてくれないので、こちらで持って
    /// 強調したいピンには最初から選択時の画像を渡す。
    private var highlightedPlaceIndex: Int?
    /// POIを入れ替えた直後のカメラ移動をパン操作と誤認しないための無視期間。
    private var ignoresMapRegionChangesUntil: Date?

    /// パンが止まったと判断するまでの待ち時間。
    private static let regionSearchDelay: TimeInterval = 1.5
    /// driving taskアプリのガイドラインに合わせた、POI差し替えの最短間隔。
    private static let pointOfInterestUpdateInterval: TimeInterval = 60
    /// 同じガイドラインの、データ項目の定期更新の最短間隔。
    private static let informationUpdateInterval: TimeInterval = 10
    /// これ以上中心が動いたら別の場所を見ているとみなす。検索半径(3km)の一部だけ動いても
    /// 同じ駐車場が並ぶだけなので、無駄な差し替えを避ける。
    private static let regionShiftThreshold: CLLocationDistance = 800
    /// POI差し替えに伴うカメラ移動を無視する時間。
    private static let mapRegionSettleDuration: TimeInterval = 2

    private struct InformationActionConfiguration: Equatable {
        let recordingState: RecordingState
    }

    private struct InformationItemContent: Equatable {
        let title: String
        let detail: String
    }

    /// 地図画面のナビバーの見た目。同じならCarPlayに入れ直さない。
    private struct MapChromeState: Equatable {
        let title: String
        let trailingTitles: [String]
        let isEnabled: Bool
    }

    private struct PinImageKey: Hashable {
        let number: Int
        let category: PlaceSearchService.Category
        let selected: Bool
        let userInterfaceStyle: UIUserInterfaceStyle
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
        cancelRegionSearch()
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
        recordingObserver = nil
        informationTemplate = nil
        pointOfInterestTemplate = nil
        informationActionConfiguration = nil
        interfaceController = nil
        templateApplicationScene = nil
        placeCategory = .parking
        isSearchingPlaces = false
        searchingCategory = nil
        lastPlaceSearchCenter = nil
        lastPointOfInterestUpdateDate = nil
        lastInformationUpdateDate = nil
        mapChromeState = nil
        lastSelectionReapplyDate = nil
        highlightedPlaceIndex = nil
        isPlaceSelected = false
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
            // 地図画面は周辺検索の結果だけなので、位置更新でPOIを作り直す必要はない。
            // 検索中かどうかのタイトル表示だけ最新にする。
            updateMapTemplateChrome(pointOfInterestTemplate)
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

    /// 今表示しているカテゴリの検索サービス。
    private var activeSearch: PlaceSearchService? {
        placeSearches[placeCategory]
    }

    private var activeSpots: [PlaceSearchService.Spot] {
        activeSearch?.spots ?? []
    }

    private var allowsPeriodicPointOfInterestUpdate: Bool {
        guard let lastPointOfInterestUpdateDate else { return true }
        return Date().timeIntervalSince(lastPointOfInterestUpdateDate) >= Self.pointOfInterestUpdateInterval
    }

    /// 地図(POI)画面を開く。どのカテゴリで開くかは入口ごとに指定する。
    private func openMapTemplate(category: PlaceSearchService.Category) {
        guard let interfaceController else { return }
        placeCategory = category

        // 検索結果が0件でも開き、ナビバーから別のカテゴリを検索できるようにする。
        // 作り立てのテンプレートは生成時にPOIを受け取っているので入れ直さない。
        // 入れ直すとリストのスクロール位置が中途半端な所から始まってしまう。
        let template: CPPointOfInterestTemplate
        if let existing = pointOfInterestTemplate {
            template = existing
            configurePointOfInterestTemplate(existing)
        } else {
            template = makePointOfInterestTemplate()
        }
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
        mapChromeState = nil
        let template = CPPointOfInterestTemplate(
            title: mapTemplateTitle,
            pointsOfInterest: content.points,
            selectedIndex: content.selectedIndex
        )
        template.pointOfInterestDelegate = self
        // 生成時点でPOIを渡しているので、差し替えたときと同じ後始末をここで済ませる。
        lastPointOfInterestUpdateDate = Date()
        ignoresMapRegionChangesUntil = Date().addingTimeInterval(Self.mapRegionSettleDuration)
        updateMapTemplateChrome(template)
        return template
    }

    private func configurePointOfInterestTemplate(_ template: CPPointOfInterestTemplate) {
        let content = makePointOfInterestContent()
        updateMapTemplateChrome(template)
        lastPointOfInterestUpdateDate = Date()
        // 差し替えに伴うカメラ移動はパン操作として扱わない。
        ignoresMapRegionChangesUntil = Date().addingTimeInterval(Self.mapRegionSettleDuration)
        template.setPointsOfInterest(content.points, selectedIndex: content.selectedIndex)
    }

    /// ナビバーに並べるカテゴリ。今見ているもの以外を出して1タップで行けるようにする。
    /// leading はシステムの戻るボタンやパン中の「完了」が出る場所なので使わない。
    private var otherCategories: [PlaceSearchService.Category] {
        PlaceSearchService.Category.allCases.filter { $0 != placeCategory }
    }

    private func makeCategoryBarButton(for category: PlaceSearchService.Category) -> CPBarButton {
        let button = CPBarButton(title: category.title) { [weak self] _ in
            Task { @MainActor in
                self?.showPlaces(category: category)
            }
        }
        button.isEnabled = !isSearchingPlaces
        return button
    }

    /// タイトルとナビバーのボタンだけを最新化する。POIの差し替えを伴わないので検索中の表示更新に使う。
    private func updateMapTemplateChrome(_ template: CPPointOfInterestTemplate) {
        // 位置更新のたびにここを通るので、内容が同じときは触らない。
        // ナビバーを入れ直すとCarPlay側が地図の状態（選択中のピンなど）を作り直してしまう。
        let categories = otherCategories
        let state = MapChromeState(
            title: mapTemplateTitle,
            trailingTitles: categories.map(\.title),
            isEnabled: !isSearchingPlaces
        )
        guard state != mapChromeState else { return }
        mapChromeState = state

        template.title = state.title
        // パン操作中の「完了」など、CarPlay標準の地図UIを優先して見せるため先頭側は空けておく。
        template.leadingNavigationBarButtons = []
        template.trailingNavigationBarButtons = categories.map { makeCategoryBarButton(for: $0) }
    }

    private var mapTemplateTitle: String {
        if isSearchingPlaces, let searchingCategory {
            return "\(searchingCategory.title)を検索中…"
        }
        if activeSpots.isEmpty {
            return "\(placeCategory.title)：見つかりません"
        }
        return placeCategory.title
    }

    private func makePointOfInterestContent() -> (points: [CPPointOfInterest], selectedIndex: Int) {
        makePlacePointOfInterestContent(category: placeCategory)
    }

    private func makePlacePointOfInterestContent(
        category: PlaceSearchService.Category
    ) -> (points: [CPPointOfInterest], selectedIndex: Int) {
        let spots = activeSpots
        let highlighted = spots.isEmpty ? nil : highlightedPlaceIndex
        let points = spots.enumerated().map { index, spot in
            makePlacePointOfInterest(
                for: spot,
                number: index + 1,
                category: category,
                highlighted: index == highlighted
            )
        }
        // ピンの強調とテンプレート側の選択は別物。開いた直後は強調だけ付けて、
        // 選択はユーザーがリストをタップしてから渡す（開いた時点でスクロールさせないため）。
        let selectedIndex = isPlaceSelected ? highlighted : nil
        return (points, selectedIndex ?? NSNotFound)
    }

    /// 番号はピンに描く数字と揃える。同じ番号を見出しにも出すことで、
    /// ピンが複数並んでいてもカードがどのピンの話なのか分かるようにする。
    private func makePlacePointOfInterest(
        for spot: PlaceSearchService.Spot,
        number: Int,
        category: PlaceSearchService.Category,
        highlighted: Bool
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
            // 強調中のピンは、選択されていない状態の画像としても選択時の見た目を渡す。
            pinImage: makePinImage(number: number, category: category, selected: highlighted),
            selectedPinImage: makePinImage(number: number, category: category, selected: true)
        )
        pointOfInterest.primaryButton = CPTextButton(title: "案内", textStyle: .confirm) { [weak self] _ in
            Task { @MainActor in
                self?.startNavigation(to: spot)
            }
        }
        return pointOfInterest
    }

    /// 地図画面を開いたまま、駐車場や給油所の表示に切り替える。
    /// 検索中は今の表示を残したまま、タイトルとボタンだけで状態を伝える。
    private func showPlaces(category: PlaceSearchService.Category) {
        searchPlaces(category: category) { [weak self] in
            guard let self, let pointOfInterestTemplate = self.pointOfInterestTemplate else { return }
            self.placeCategory = category
            self.configurePointOfInterestTemplate(pointOfInterestTemplate)
        }
    }

    /// 情報画面から周辺検索を開く。検索結果が0件でもカテゴリ切り替えを使えるようにする。
    private func openPlacesTemplate(category: PlaceSearchService.Category) {
        searchPlaces(category: category) { [weak self] in
            self?.openMapTemplate(category: category)
        }
    }

    /// 現在地を取り直してから周辺を検索する。0件を含め、検索が成功したら completion を呼ぶ。
    /// `center` を渡すとその周辺を探す（地図をパンしたときの再検索用）。距離と番号は
    /// どちらの場合も運転者の現在地から測る。`silently` はパン起因の検索で使い、
    /// 失敗しても運転中にアラートを出さないためのもの。
    private func searchPlaces(
        category: PlaceSearchService.Category,
        around center: CLLocationCoordinate2D? = nil,
        silently: Bool = false,
        completion: @escaping () -> Void
    ) {
        guard !isSearchingPlaces, let search = placeSearches[category] else { return }
        guard locationManager.canRecordLocation else {
            guard !silently else { return }
            // ガイドラインにより、CarPlayの文言でiPhoneの操作を促してはいけない。
            // 状態だけ伝えて、許可の要求は黙って出す（安全なときに気づいてもらう）。
            locationManager.requestPermissionIfNeeded()
            presentAlert(
                "位置情報が許可されていないため\(category.name)を検索できません",
                shortTitle: "位置情報が未許可です"
            )
            return
        }
        searchingCategory = category

        isSearchingPlaces = true
        if let pointOfInterestTemplate {
            updateMapTemplateChrome(pointOfInterestTemplate)
        }

        locationManager.captureCurrentLocation { coordinate in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let coordinate else {
                    // 現在地が取れないと距離も番号も出せないので、パン起因なら黙って諦める。
                    self.failPlaceSearch(
                        message: "現在地を取得できませんでした",
                        shortMessage: "現在地が不明です",
                        silently: silently
                    )
                    return
                }
                let searchCenter = center ?? coordinate
                search.searchSpots(around: searchCenter, measuringFrom: coordinate) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let spots):
                        self.isSearchingPlaces = false
                        self.searchingCategory = nil
                        self.lastPlaceSearchCenter = searchCenter
                        // 手動で開いたときは最寄りを強調して出す。パンでの探し直しでは、
                        // 見ている場所を動かさないよう強調も付けない。
                        self.highlightedPlaceIndex = silently || spots.isEmpty ? nil : 0
                        self.isPlaceSelected = false
                        completion()
                    case .failure(let error):
                        print("CarPlay place search error: \(error.localizedDescription)")
                        self.failPlaceSearch(
                            message: "\(category.name)を検索できませんでした",
                            shortMessage: "検索できません",
                            silently: silently
                        )
                    }
                }
            }
        }
    }

    /// 地図をパンされたときの再検索。見ている場所が変わったぶんだけPOIを差し替える。
    private func handleMapRegionChange(_ region: MKCoordinateRegion) {
        guard !isSearchingPlaces else { return }
        // 自分でPOIを入れ替えた直後のカメラ移動は、ユーザーのパンではないので無視する。
        if let ignoresMapRegionChangesUntil, Date() < ignoresMapRegionChangesUntil { return }
        let center = region.center
        if let lastPlaceSearchCenter,
           Self.distance(from: lastPlaceSearchCenter, to: center) < Self.regionShiftThreshold {
            return
        }
        // すでに出している場所の近くを見ているだけなら、探し直しても同じ顔ぶれになる。
        // カードやピンを選んでカメラが寄った場合もここで弾ける。
        let isNearShownSpot = activeSpots.contains { spot in
            Self.distance(from: spot.coordinate, to: center) < Self.regionShiftThreshold
        }
        if isNearShownSpot { return }
        pendingRegionCenter = center
        scheduleRegionSearch()
    }

    /// パン中は通知が連続で来るので、止まってから探す。前回の差し替えから60秒経つまでは待つ。
    private func scheduleRegionSearch() {
        var delay = Self.regionSearchDelay
        if let lastPointOfInterestUpdateDate {
            let elapsed = Date().timeIntervalSince(lastPointOfInterestUpdateDate)
            delay = max(delay, Self.pointOfInterestUpdateInterval - elapsed)
        }

        regionSearchTimer?.invalidate()
        regionSearchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.runPendingRegionSearch()
            }
        }
    }

    private func cancelRegionSearch() {
        regionSearchTimer?.invalidate()
        regionSearchTimer = nil
        pendingRegionCenter = nil
    }

    private func runPendingRegionSearch() {
        regionSearchTimer = nil
        guard let center = pendingRegionCenter else { return }
        pendingRegionCenter = nil
        // 待っている間に地図画面が閉じられていたら、見えないPOIを作り直すだけなのでやめる。
        guard let pointOfInterestTemplate,
              interfaceController?.topTemplate === pointOfInterestTemplate else { return }

        let category = placeCategory
        searchPlaces(category: category, around: center, silently: true) { [weak self] in
            guard let self,
                  self.placeCategory == category,
                  let pointOfInterestTemplate = self.pointOfInterestTemplate else { return }
            // 番号は付け直しになるが、選択も強調も付けないのでユーザーが見ている場所は動かない。
            self.configurePointOfInterestTemplate(pointOfInterestTemplate)
        }
    }

    private static func distance(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
    }

    /// リストで選ばれた場所のピンを黄色くする。
    /// selectedIndex を入れ直すだけではピン画像が描き替わらないため、POIを作り直して
    /// 強調したいピンに選択時の画像を持たせる。差し替えがまた didSelect を呼んでも
    /// ループしないよう、1秒間は差し替えない。
    private func highlightSelectedPlace(
        on template: CPPointOfInterestTemplate,
        for pointOfInterest: CPPointOfInterest
    ) {
        if let lastSelectionReapplyDate, Date().timeIntervalSince(lastSelectionReapplyDate) < 1 { return }
        guard let index = template.pointsOfInterest.firstIndex(where: { $0 === pointOfInterest }),
              index != highlightedPlaceIndex else { return }

        lastSelectionReapplyDate = Date()
        highlightedPlaceIndex = index
        // ここからはユーザーが選んだ状態。詳細カードを開いたままにするため選択も渡す。
        isPlaceSelected = true
        configurePointOfInterestTemplate(template)
    }

    /// 検索に失敗したときの後始末。表示は元に戻してから理由を伝える。
    /// パン起因(`silently`)のときは今見ている一覧を壊さないよう、タイトルとボタンだけ戻す。
    private func failPlaceSearch(message: String, shortMessage: String? = nil, silently: Bool = false) {
        isSearchingPlaces = false
        searchingCategory = nil
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
    private func startNavigation(to spot: PlaceSearchService.Spot) {
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

    private func makePinImage(
        number: Int,
        category: PlaceSearchService.Category,
        selected: Bool
    ) -> UIImage {
        let key = PinImageKey(
            number: number,
            category: category,
            selected: selected,
            userInterfaceStyle: interfaceController?.carTraitCollection.userInterfaceStyle ?? .unspecified
        )
        if let cached = pinImageCache[key] {
            return cached
        }
        let image = makePlacePinImage(number: number, category: category, selected: selected)
        pinImageCache[key] = image
        return image
    }

    /// 駐車場・給油所のピン。昼夜どちらの地図でも沈まないよう、白縁付きの塗りに白の数字を載せる。
    /// 数字は詳細カードの見出しと同じ番号。カテゴリで地色を変え、選択中だけオレンジで
    /// 一段大きく描いて「いま見ているカードのピンはどれか」が一目で分かるようにする。
    private func makePlacePinImage(
        number: Int,
        category: PlaceSearchService.Category,
        selected: Bool
    ) -> UIImage {
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

            let fillColor: UIColor = selected ? .systemOrange : category.pinColor
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
        InformationActionConfiguration(recordingState: locationManager.recordingState)
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
                makePlacesTextButton(),
            ]
        case .recording:
            return [
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
                makePlacesTextButton(),
            ]
        case .paused:
            return [
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
                makePlacesTextButton(),
            ]
        }
    }

    /// 周辺検索への入口。待機中も記録中も同じ位置に置く（下部ボタンはどの状態でも3個以内）。
    /// カテゴリを選ばせるアクションシートは、狭い画面(800x480)だとタイトル＋4ボタンが
    /// 収まらずキャンセルが切れてしまったので使わない。前回見ていたカテゴリを直接開き、
    /// 切り替えは地図画面のナビバーに任せる（戻るのはシステムの戻るボタン）。
    private func makePlacesTextButton() -> CPTextButton {
        CPTextButton(title: "周辺", textStyle: .normal) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.openPlacesTemplate(category: self.placeCategory)
            }
        }
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

    /// 更新は10秒に1回までなので、秒の値は10秒ずつ飛ぶ。
    /// それでも「今どのくらい走ったか」の実感は秒があるほうが掴みやすいので出す。
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
        handleMapRegionChange(region)
    }

    /// 詳細パネルを開いたら、パンで予約していた差し替えは取り下げる。
    /// 差し替えると選択が外れてパネルが閉じてしまい、読んでいる途中で消えるのを防ぐため。
    func pointOfInterestTemplate(
        _ pointOfInterestTemplate: CPPointOfInterestTemplate,
        didSelectPointOfInterest pointOfInterest: CPPointOfInterest
    ) {
        cancelRegionSearch()
        highlightSelectedPlace(on: pointOfInterestTemplate, for: pointOfInterest)
    }
}
