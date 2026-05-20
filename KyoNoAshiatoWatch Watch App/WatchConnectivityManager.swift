//
//  WatchConnectivityManager.swift
//  KyoNoAshiatoWatch Watch App
//
//  Watch 側で iPhone とメッセージをやり取りする。
//

import Foundation
import Observation
import WatchConnectivity

@Observable
final class WatchConnectivityManager: NSObject {
    var isRecording = false
    var startDate: Date?
    var distance: Double = 0
    var isReachable = false
    var lastError: String?

    @ObservationIgnored private var session: WCSession { WCSession.default }

    override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        } else {
            applyReachability()
        }
    }

    func toggleRecording() {
        send(command: isRecording ? "stop" : "start")
    }

    func requestStatus() {
        send(command: "status")
    }

    private func send(command: String) {
        guard session.activationState == .activated else {
            lastError = "iPhone と接続中..."
            return
        }
        guard session.isReachable else {
            lastError = "iPhone と接続できません"
            return
        }
        lastError = nil
        session.sendMessage(["command": command], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.applyPayload(reply)
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.lastError = "通信エラー: \(error.localizedDescription)"
            }
        })
    }

    @MainActor
    private func applyPayload(_ payload: [String: Any]) {
        if let recording = payload["isRecording"] as? Bool {
            isRecording = recording
        }
        if let startInterval = payload["startDate"] as? TimeInterval, startInterval > 0 {
            startDate = Date(timeIntervalSince1970: startInterval)
        } else {
            startDate = nil
        }
        if let dist = payload["distance"] as? Double {
            distance = dist
        }
    }

    @MainActor
    private func applyReachability() {
        isReachable = session.isReachable
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            self.applyReachability()
            if state == .activated {
                self.requestStatus()
            }
            if let error {
                self.lastError = "接続エラー: \(error.localizedDescription)"
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.applyReachability()
            if session.isReachable {
                self.requestStatus()
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyPayload(applicationContext)
        }
    }
}
