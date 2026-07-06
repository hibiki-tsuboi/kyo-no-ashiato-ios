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
    private let locationManager = LocationManager.shared

    private struct InformationActionConfiguration: Equatable {
        let recordingState: RecordingState
        let hasMapContent: Bool
    }

    private enum MapPinKind {
        case start
        case waypoint
        case current
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
        connect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        connect(interfaceController)
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

    private func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
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

        if updatesMap, let pointOfInterestTemplate {
            configurePointOfInterestTemplate(pointOfInterestTemplate)
        }

        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        if locationManager.recordingState == .recording {
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
        template.title = "今日のあしあと"
        template.items = makeInformationItems()
        let actionConfiguration = makeInformationActionConfiguration()
        if actionConfiguration != informationActionConfiguration {
            template.actions = makeActions(for: actionConfiguration)
            informationActionConfiguration = actionConfiguration
        }
    }

    private func openMapTemplate() {
        guard let interfaceController else { return }
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
            title: "地図",
            pointsOfInterest: content.points,
            selectedIndex: content.selectedIndex
        )
        template.pointOfInterestDelegate = self
        return template
    }

    private func configurePointOfInterestTemplate(_ template: CPPointOfInterestTemplate) {
        let content = makePointOfInterestContent()
        template.title = "地図"
        // パン操作中の「完了」など、CarPlay標準の地図UIを優先して見せる。
        template.leadingNavigationBarButtons = []
        template.trailingNavigationBarButtons = []
        template.setPointsOfInterest(content.points, selectedIndex: content.selectedIndex)
    }

    private func makePointOfInterestContent() -> (points: [CPPointOfInterest], selectedIndex: Int) {
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
        let route = locationManager.currentRoute
        let distance = route.map { formatDistance($0.totalDistance) } ?? "-"
        let startTime = route.map { formatTime($0.startDate) } ?? "-"
        let elapsed = route.map { formatDuration(activeDuration(for: $0)) } ?? "-"

        return [
            CPInformationItem(title: "状態", detail: stateText),
            CPInformationItem(title: "開始", detail: startTime),
            CPInformationItem(title: "距離", detail: distance),
            CPInformationItem(title: "移動時間", detail: elapsed),
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
                }
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

    private func makeMapTextButton() -> CPTextButton {
        CPTextButton(title: "地図", textStyle: .normal) { [weak self] _ in
            Task { @MainActor in
                self?.openMapTemplate()
            }
        }
    }

    private var hasMapContent: Bool {
        !makeMapPoints().isEmpty
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
