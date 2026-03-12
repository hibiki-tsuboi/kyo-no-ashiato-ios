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
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var isRecording = false
    var currentRoute: RouteRecord?
    var currentCoordinates: [CLLocationCoordinate2D] = []

    private let clManager = CLLocationManager()
    private var modelContext: ModelContext?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 5
        clManager.allowsBackgroundLocationUpdates = true
        clManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = clManager.authorizationStatus
    }

    func setup(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func requestPermission() {
        clManager.requestAlwaysAuthorization()
    }

    func startRecording() {
        guard let modelContext else { return }
        let route = RouteRecord()
        modelContext.insert(route)
        try? modelContext.save()
        currentRoute = route
        currentCoordinates = []
        isRecording = true
        clManager.startUpdatingLocation()
    }

    func stopRecording() {
        guard let route = currentRoute else { return }
        route.endDate = Date()
        try? modelContext?.save()
        clManager.stopUpdatingLocation()
        isRecording = false
        currentRoute = nil
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let route = currentRoute, let modelContext else { return }
        for location in locations {
            guard location.horizontalAccuracy >= 0 else { continue }
            let point = LocationPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: location.timestamp
            )
            point.route = route
            route.points.append(point)
            currentCoordinates.append(location.coordinate)
        }
        try? modelContext.save()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        print("LocationManager error: \(error.localizedDescription)")
    }
}
