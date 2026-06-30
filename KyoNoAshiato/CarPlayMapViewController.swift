//
//  CarPlayMapViewController.swift
//  KyoNoAshiato
//
//  Created by Codex on 2026/06/30.
//

import MapKit
import UIKit

@MainActor
final class CarPlayMapViewController: UIViewController {
    private let locationManager: LocationManager
    private let mapView = MKMapView()
    private var routeOverlay: MKPolyline?
    private var recordingObserver: NSObjectProtocol?
    private var shouldFollowUser = true

    init(locationManager: LocationManager) {
        self.locationManager = locationManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureMapView()
        observeRecordingChanges()
        updateRoute(animated: false)
    }

    func updateRoute(animated: Bool) {
        let coordinates = currentCoordinates

        if let routeOverlay {
            mapView.removeOverlay(routeOverlay)
            self.routeOverlay = nil
        }

        if coordinates.count >= 2 {
            let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
            routeOverlay = overlay
            mapView.addOverlay(overlay)
        }

        guard shouldFollowUser else { return }
        if let latest = coordinates.last {
            center(on: latest, animated: animated)
        } else {
            centerOnUser(animated: animated)
        }
    }

    func centerOnUser(animated: Bool = true) {
        shouldFollowUser = true
        mapView.setUserTrackingMode(.follow, animated: animated)
        if let coordinate = mapView.userLocation.location?.coordinate {
            center(on: coordinate, animated: animated)
        }
    }

    func centerOnRoute(animated: Bool = true) {
        let coordinates = currentCoordinates
        guard coordinates.count >= 2, let routeOverlay else {
            centerOnUser(animated: animated)
            return
        }
        shouldFollowUser = false
        mapView.setVisibleMapRect(
            routeOverlay.boundingMapRect,
            edgePadding: UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
            animated: animated
        )
    }

    private func configureMapView() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.pointOfInterestFilter = .excludingAll

        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func observeRecordingChanges() {
        recordingObserver = NotificationCenter.default.addObserver(
            forName: .locationManagerRecordingDidChange,
            object: locationManager,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateRoute(animated: true)
            }
        }
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

    private func center(on coordinate: CLLocationCoordinate2D, animated: Bool) {
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 800,
            longitudinalMeters: 800
        )
        mapView.setRegion(region, animated: animated)
    }
}

extension CarPlayMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.strokeColor = .systemBlue
        renderer.lineWidth = 6
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }
}
