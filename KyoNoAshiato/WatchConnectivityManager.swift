//
//  WatchConnectivityManager.swift
//  KyoNoAshiato
//
//  iPhone 側で Apple Watch とのメッセージをやり取りする。
//

import Foundation
import CoreLocation
import WatchConnectivity

final class WatchConnectivityManager: NSObject {
    weak var locationManager: LocationManager?

    init(locationManager: LocationManager) {
        self.locationManager = locationManager
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        }
    }

    /// 現在の記録状態を Watch に送る。状態は最新値のみ必要なので
    /// `updateApplicationContext` を使う（順序保証あり・最新値で上書き）。
    func sendStatus() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let context = currentStatusPayload()
        do {
            try session.updateApplicationContext(context)
        } catch {
            print("WatchConnectivity updateApplicationContext error: \(error)")
        }
    }

    private func currentStatusPayload() -> [String: Any] {
        let isRecording = locationManager?.isRecording ?? false
        var payload: [String: Any] = ["isRecording": isRecording]
        if let route = locationManager?.currentRoute {
            payload["startDate"] = route.startDate.timeIntervalSince1970
        }
        payload["distance"] = currentDistance()
        return payload
    }

    private func currentDistance() -> Double {
        guard let coords = locationManager?.currentCoordinates, coords.count >= 2 else { return 0 }
        var total: CLLocationDistance = 0
        for i in 1..<coords.count {
            let from = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let to = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            total += to.distance(from: from)
        }
        return total
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        if let error {
            print("WatchConnectivity activation error: \(error)")
            return
        }
        if state == .activated {
            sendStatus()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            handleCommand(message)
            replyHandler(currentStatusPayload())
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            handleCommand(message)
            sendStatus()
        }
    }

    @MainActor
    private func handleCommand(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        switch command {
        case "start":
            if locationManager?.isRecording == false {
                locationManager?.startRecording()
            }
        case "stop":
            if locationManager?.isRecording == true {
                locationManager?.stopRecording()
            }
        case "status":
            break
        default:
            break
        }
    }
}
