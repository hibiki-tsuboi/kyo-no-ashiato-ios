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
    private var displayedRecordingState: RecordingState?
    private var pointOfInterestTemplateUnavailable = false
    private let locationManager = LocationManager.shared

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
        displayedRecordingState = nil
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
        if displayedRecordingState != locationManager.recordingState {
            reloadTemplate(animated: false, force: true)
            return
        }

        if let pointOfInterestTemplate {
            configurePointOfInterestTemplate(pointOfInterestTemplate)
        }

        if let informationTemplate {
            informationTemplate.items = makeInformationItems()
            informationTemplate.actions = makeActions()
        }
    }

    private func reloadTemplate(animated: Bool, force: Bool = false) {
        guard let interfaceController else { return }

        if !pointOfInterestTemplateUnavailable {
            let template = pointOfInterestTemplate ?? makePointOfInterestTemplate()
            configurePointOfInterestTemplate(template)
            pointOfInterestTemplate = template
            displayedRecordingState = locationManager.recordingState
            interfaceController.setRootTemplate(template, animated: animated) { [weak self] success, error in
                guard !success else { return }
                if let error {
                    print("CarPlay point of interest template error: \(error.localizedDescription)")
                }
                Task { @MainActor in
                    self?.pointOfInterestTemplateUnavailable = true
                    self?.reloadTemplate(animated: false, force: true)
                }
            }
            return
        }

        let template = informationTemplate ?? makeInformationTemplate()
        template.items = makeInformationItems()
        template.actions = makeActions()
        informationTemplate = template
        displayedRecordingState = locationManager.recordingState
        guard force || interfaceController.rootTemplate !== template else { return }
        interfaceController.setRootTemplate(template, animated: animated) { success, error in
            if !success, let error {
                print("CarPlay root template error: \(error.localizedDescription)")
            }
        }
    }

    private func makePointOfInterestTemplate() -> CPPointOfInterestTemplate {
        let points = makePointsOfInterest()
        let template = CPPointOfInterestTemplate(
            title: "今日のあしあと",
            pointsOfInterest: points,
            selectedIndex: NSNotFound
        )
        template.pointOfInterestDelegate = self
        return template
    }

    private func configurePointOfInterestTemplate(_ template: CPPointOfInterestTemplate) {
        let points = makePointsOfInterest()
        template.title = "今日のあしあと"
        template.leadingNavigationBarButtons = leadingNavigationBarButtons()
        template.trailingNavigationBarButtons = trailingNavigationBarButtons()
        template.setPointsOfInterest(points, selectedIndex: NSNotFound)
    }

    private func makePointsOfInterest() -> [CPPointOfInterest] {
        let coordinates = currentCoordinates
        guard !coordinates.isEmpty else { return [] }

        var points: [CPPointOfInterest] = []
        let summary = routeSummary

        if locationManager.recordingState != .idle, let start = coordinates.first {
            points.append(
                makePointOfInterest(
                    coordinate: start,
                    title: "出発地点",
                    subtitle: formatTime(locationManager.currentRoute?.startDate ?? Date()),
                    summary: summary
                )
            )
        }

        if let latest = coordinates.last {
            let shouldAddLatest = points.isEmpty || !isSameCoordinate(points[0].location.placemark.coordinate, latest)
            if shouldAddLatest {
                points.append(
                    makePointOfInterest(
                        coordinate: latest,
                        title: "現在地",
                        subtitle: stateText,
                        summary: summary
                    )
                )
            }
        }

        return Array(points.prefix(12))
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

    private var currentCoordinates: [CLLocationCoordinate2D] {
        if let route = locationManager.currentRoute {
            let coordinates = route.coordinates
            if !coordinates.isEmpty {
                return coordinates
            }
        }
        return locationManager.currentCoordinates
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
                }
            ]
        case .recording:
            return [
                CPTextButton(title: "一時停止", textStyle: .normal) { [weak self] _ in
                    Task { @MainActor in
                        self?.locationManager.pauseRecording()
                        self?.reloadTemplate(animated: false)
                    }
                },
                CPTextButton(title: "到着", textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in
                        self?.stopRecordingFromCarPlay()
                    }
                },
            ]
        case .paused:
            return [
                CPTextButton(title: "再開", textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in
                        self?.locationManager.resumeRecording()
                        self?.reloadTemplate(animated: false)
                    }
                },
                CPTextButton(title: "到着", textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in
                        self?.stopRecordingFromCarPlay()
                    }
                },
            ]
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
        presentAlert("あしあとを記録しました")
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

    private func presentAlert(_ title: String) {
        guard let interfaceController else { return }
        let close = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.interfaceController?.dismissTemplate(animated: true) { success, error in
                    if !success, let error {
                        print("CarPlay alert dismiss error: \(error.localizedDescription)")
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
