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
    private var selectedMapPinKind: MapPinKind = .current
    private let locationManager = LocationManager.shared

    private enum MapPinKind: String {
        case start
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
        interfaceController = nil
        selectedMapPinKind = .current
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
        template.actions = makeActions()
    }

    private func openMapTemplate() {
        guard let interfaceController else { return }
        selectedMapPinKind = .current
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
        let selectedIndex = mapPoints.firstIndex { $0.pinKind == selectedMapPinKind }
            ?? mapPoints.firstIndex { $0.isCurrent }
            ?? NSNotFound
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
            return [start, current]
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
        let pointOfInterest = CPPointOfInterest(
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
        pointOfInterest.userInfo = pinKind.rawValue
        return pointOfInterest
    }

    private func makePinImage(for pinKind: MapPinKind, selected: Bool) -> UIImage? {
        guard pinKind == .current else { return nil }

        let size = selected ? CPPointOfInterest.selectedPinImageSize : CPPointOfInterest.pinImageSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let diameter = min(size.width, size.height) * (selected ? 0.62 : 0.52)
            let circleRect = CGRect(
                x: (size.width - diameter) / 2,
                y: (size.height - diameter) / 2,
                width: diameter,
                height: diameter
            )

            if selected {
                UIColor.systemBlue.withAlphaComponent(0.22).setFill()
                let haloDiameter = min(size.width, size.height) * 0.9
                let haloRect = CGRect(
                    x: (size.width - haloDiameter) / 2,
                    y: (size.height - haloDiameter) / 2,
                    width: haloDiameter,
                    height: haloDiameter
                )
                UIBezierPath(ovalIn: haloRect).fill()
            }

            UIColor.systemBlue.setFill()
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

    private func makeActions() -> [CPTextButton] {
        switch locationManager.recordingState {
        case .idle:
            return [
                CPTextButton(title: "出発", textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in
                        self?.startRecordingFromCarPlay()
                    }
                }
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
                        self?.stopRecordingFromCarPlay()
                    }
                },
                makeMapTextButton(),
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
                        self?.stopRecordingFromCarPlay()
                    }
                },
                makeMapTextButton(),
            ]
        }
    }

    private func makeMapTextButton() -> CPTextButton {
        CPTextButton(title: "地図", textStyle: .normal) { [weak self] _ in
            Task { @MainActor in
                self?.openMapTemplate()
            }
        }
    }

    private func startRecordingFromCarPlay() {
        guard canRecordLocation else {
            requestLocationPermissionIfNeeded()
            presentAlert("iPhoneで位置情報を許可してください")
            return
        }

        locationManager.startRecording()
        refreshCarPlayUI()
    }

    private func stopRecordingFromCarPlay() {
        locationManager.stopRecording()
        refreshCarPlayUI()
        presentAlert("あしあとを記録しました", returnsToRootAfterDismiss: true)
    }

    private var canRecordLocation: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .denied, .notDetermined, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestLocationPermissionIfNeeded() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestPermission()
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
                self?.interfaceController?.dismissTemplate(animated: true) { success, error in
                    if !success, let error {
                        print("CarPlay alert dismiss error: \(error.localizedDescription)")
                    }
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
}

extension CarPlaySceneDelegate: CPPointOfInterestTemplateDelegate {
    func pointOfInterestTemplate(
        _ pointOfInterestTemplate: CPPointOfInterestTemplate,
        didChangeMapRegion region: MKCoordinateRegion
    ) {
    }

    func pointOfInterestTemplate(
        _ pointOfInterestTemplate: CPPointOfInterestTemplate,
        didSelectPointOfInterest pointOfInterest: CPPointOfInterest
    ) {
        guard
            let rawPinKind = pointOfInterest.userInfo as? String,
            let pinKind = MapPinKind(rawValue: rawPinKind)
        else {
            return
        }

        selectedMapPinKind = pinKind
        if let selectedIndex = pointOfInterestTemplate.pointsOfInterest.firstIndex(where: { $0 === pointOfInterest }) {
            pointOfInterestTemplate.selectedIndex = selectedIndex
        }
    }
}
