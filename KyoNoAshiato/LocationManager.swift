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
    private var lastAcceptedLocation: CLLocation?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 5
        clManager.activityType = .otherNavigation
        clManager.allowsBackgroundLocationUpdates = true
        clManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = clManager.authorizationStatus
    }

    func setup(modelContext: ModelContext) {
        self.modelContext = modelContext
        recoverIncompleteRoutes()
    }

    func recoverIncompleteRoutes() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<RouteRecord>(
            predicate: #Predicate { $0.endDate == nil }
        )
        guard let incomplete = try? modelContext.fetch(descriptor) else { return }
        for route in incomplete {
            guard route.id != currentRoute?.id else { continue }
            let lastTimestamp = route.points.map(\.timestamp).max()
            route.endDate = lastTimestamp ?? route.startDate
        }
        try? modelContext.save()
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
        lastAcceptedLocation = nil
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
        lastAcceptedLocation = nil
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let route = currentRoute, let modelContext else { return }
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
            currentCoordinates.append(location.coordinate)
            lastAcceptedLocation = location
            didAddPoint = true
        }

        if didAddPoint {
            try? modelContext.save()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        print("LocationManager error: \(error.localizedDescription)")
    }

    private func isValidLocation(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard location.horizontalAccuracy <= 100 else { return false }
        guard abs(location.timestamp.timeIntervalSinceNow) <= 15 else { return false }

        guard let last = lastAcceptedLocation else { return true }

        let timeInterval = location.timestamp.timeIntervalSince(last.timestamp)
        guard timeInterval > 0 else { return false }

        let distance = location.distance(from: last)
        let speed = distance / timeInterval
        let maxPlausibleSpeed: CLLocationSpeed = 95 // 約342km/h

        return speed <= maxPlausibleSpeed
    }
}
