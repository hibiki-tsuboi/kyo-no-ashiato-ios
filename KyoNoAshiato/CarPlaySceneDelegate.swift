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
    private let locationManager = LocationManager.shared

    private struct MapPoint {
        let coordinate: CLLocationCoordinate2D
        let title: String
        let subtitle: String?
        let summary: String?
        let isCurrent: Bool
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
    }

    private func disconnect() {
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
        recordingObserver = nil
        informationTemplate = nil
        pointOfInterestTemplate = nil
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
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCarPlayUI()
            }
        }
    }

    private func refreshCarPlayUI() {
        guard let informationTemplate else {
            reloadTemplate(animated: false, force: true)
            return
        }

        configureInformationTemplate(informationTemplate)

        if let pointOfInterestTemplate {
            configurePointOfInterestTemplate(pointOfInterestTemplate)
        }
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
        let content = makePointOfInterestContent()
        guard !content.points.isEmpty else {
            presentAlert("出発後に地図を表示できます")
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
            title: "今日のあしあと",
            pointsOfInterest: content.points,
            selectedIndex: content.selectedIndex
        )
        template.pointOfInterestDelegate = self
        return template
    }

    private func configurePointOfInterestTemplate(_ template: CPPointOfInterestTemplate) {
        let content = makePointOfInterestContent()
        template.title = "今日のあしあと"
        template.leadingNavigationBarButtons = leadingNavigationBarButtons()
        template.trailingNavigationBarButtons = trailingNavigationBarButtons()
        template.setPointsOfInterest(content.points, selectedIndex: content.selectedIndex)
    }

    private func makePointOfInterestContent() -> (points: [CPPointOfInterest], selectedIndex: Int) {
        let mapPoints = makeMapPoints()
        let points = mapPoints.map { point in
            makePointOfInterest(
                coordinate: point.coordinate,
                title: point.title,
                subtitle: point.subtitle,
                summary: point.summary
            )
        }
        let selectedIndex = mapPoints.firstIndex { $0.isCurrent } ?? NSNotFound
        return (points, selectedIndex)
    }

    private func makeMapPoints() -> [MapPoint] {
        let summary = routeSummary

        if let route = locationManager.currentRoute {
            let sortedPoints = route.points.sorted { $0.timestamp < $1.timestamp }
            guard let first = sortedPoints.first else { return [] }

            guard sortedPoints.count >= 2, let latest = sortedPoints.last else {
                return [
                    MapPoint(
                        coordinate: coordinate(for: first),
                        title: "現在地",
                        subtitle: stateText,
                        summary: summary,
                        isCurrent: true
                    )
                ]
            }

            let start = MapPoint(
                coordinate: coordinate(for: first),
                title: "出発地点",
                subtitle: formatTime(route.startDate),
                summary: summary,
                isCurrent: false
            )
            let current = MapPoint(
                coordinate: coordinate(for: latest),
                title: "現在地",
                subtitle: stateText,
                summary: summary,
                isCurrent: true
            )
            let intermediate = sampledIntermediatePoints(
                Array(sortedPoints.dropFirst().dropLast()),
                maxCount: 10
            ).enumerated().map { index, point in
                MapPoint(
                    coordinate: coordinate(for: point),
                    title: "通過地点 \(index + 1)",
                    subtitle: formatTime(point.timestamp),
                    summary: summary,
                    isCurrent: false
                )
            }

            if isSameCoordinate(start.coordinate, current.coordinate) {
                return [current]
            }
            return [start] + intermediate + [current]
        }

        if let latest = locationManager.currentCoordinates.last {
            return [
                MapPoint(
                    coordinate: latest,
                    title: "現在地",
                    subtitle: stateText,
                    summary: summary,
                    isCurrent: true
                )
            ]
        }

        return []
    }

    private func coordinate(for point: LocationPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func sampledIntermediatePoints(_ points: [LocationPoint], maxCount: Int) -> [LocationPoint] {
        guard maxCount > 0, points.count > maxCount else { return points }

        var sampled: [LocationPoint] = []
        var usedIndices = Set<Int>()
        let step = Double(points.count + 1) / Double(maxCount + 1)

        for sampleNumber in 1...maxCount {
            let rawIndex = Int((Double(sampleNumber) * step).rounded()) - 1
            let index = min(points.count - 1, max(0, rawIndex))
            guard usedIndices.insert(index).inserted else { continue }
            sampled.append(points[index])
        }

        return sampled
    }

    private func makePointOfInterest(
        coordinate: CLLocationCoordinate2D,
        title: String,
        subtitle: String?,
        summary: String?
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
            pinImage: nil
        )
    }

    private var routeSummary: String? {
        guard let route = locationManager.currentRoute else { return nil }
        return "\(formatDistance(route.totalDistance)) / \(formatDuration(activeDuration(for: route)))"
    }

    private func isSameCoordinate(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000001 && abs(lhs.longitude - rhs.longitude) < 0.000001
    }

    private func makeInformationTemplate() -> CPInformationTemplate {
        CPInformationTemplate(
            title: "今日のあしあと",
            layout: .twoColumn,
            items: makeInformationItems(),
            actions: makeActions()
        )
    }

    private func leadingNavigationBarButtons() -> [CPBarButton] {
        switch locationManager.recordingState {
        case .idle:
            return []
        case .recording:
            return [
                makeBarButton(title: "一時停止") { [weak self] in
                    self?.locationManager.pauseRecording()
                    self?.refreshCarPlayUI()
                }
            ]
        case .paused:
            return [
                makeBarButton(title: "再開") { [weak self] in
                    self?.locationManager.resumeRecording()
                    self?.refreshCarPlayUI()
                }
            ]
        }
    }

    private func trailingNavigationBarButtons() -> [CPBarButton] {
        switch locationManager.recordingState {
        case .idle:
            return [
                makeBarButton(title: "出発") { [weak self] in
                    self?.startRecordingFromCarPlay()
                }
            ]
        case .recording, .paused:
            return [
                makeBarButton(title: "到着") { [weak self] in
                    self?.stopRecordingFromCarPlay()
                }
            ]
        }
    }

    private func makeBarButton(title: String, action: @escaping () -> Void) -> CPBarButton {
        let button = CPBarButton(title: title) { _ in
            Task { @MainActor in
                action()
            }
        }
        button.buttonStyle = .rounded
        return button
    }

    private func makeInformationItems() -> [CPInformationItem] {
        let route = locationManager.currentRoute
        let distance = route.map { formatDistance($0.totalDistance) } ?? "-"
        let startTime = route.map { formatTime($0.startDate) } ?? "-"
        let elapsed = route.map { formatDuration(activeDuration(for: $0)) } ?? "-"
        let pointCount = route.map { "\($0.points.count)" } ?? "-"

        return [
            CPInformationItem(title: "状態", detail: stateText),
            CPInformationItem(title: "開始", detail: startTime),
            CPInformationItem(title: "距離", detail: distance),
            CPInformationItem(title: "時間", detail: elapsed),
            CPInformationItem(title: "記録点", detail: pointCount),
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
                },
                makeMapTextButton(),
            ]
        case .recording:
            return [
                CPTextButton(title: "一時停止", textStyle: .normal) { [weak self] _ in
                    Task { @MainActor in
                        self?.locationManager.pauseRecording()
                        self?.refreshCarPlayUI()
                    }
                },
                CPTextButton(title: "到着", textStyle: .confirm) { [weak self] _ in
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
                CPTextButton(title: "到着", textStyle: .confirm) { [weak self] _ in
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
            return "記録中"
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
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "-"
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
}
