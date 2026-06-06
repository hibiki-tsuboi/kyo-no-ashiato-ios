//
//  ContentView.swift
//  KyoNoAshiatoWatch
//
//  Created by Hibiki Tsuboi on 2026/05/20.
//

import SwiftUI
import Combine

struct ContentView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            statusHeader

            if let error = connectivity.lastError {
                errorBanner(error)
            } else if connectivity.isRecording {
                Text(formattedElapsed)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .fontWeight(.bold)
                Text(formattedDistance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("出発を押すと\nあしあとを開始します")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            actionButtons
        }
        .padding(.vertical, 4)
        .onReceive(ticker) { date in
            now = date
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.iphone")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color.orange.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIconName)
                .foregroundStyle(headerIconColor)
                .symbolEffect(.pulse, isActive: connectivity.isRecording && !connectivity.isPaused)
            Text(headerText)
                .font(.headline)
        }
    }

    private var headerIconName: String {
        if connectivity.isPaused { return "pause.circle.fill" }
        if connectivity.isRecording { return "record.circle.fill" }
        return "figure.walk"
    }

    private var headerIconColor: Color {
        if connectivity.isPaused { return .orange }
        if connectivity.isRecording { return .red }
        return .secondary
    }

    private var headerText: String {
        if connectivity.isPaused { return "一時停止中" }
        if connectivity.isRecording { return "あしあと中" }
        return "今日のあしあと"
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !connectivity.isRecording {
            singleButton(
                title: "出発",
                systemImage: "record.circle.fill",
                tint: .green
            ) {
                connectivity.toggleRecording()
            }
        } else {
            HStack(spacing: 6) {
                singleButton(
                    title: connectivity.isPaused ? "再開" : "停止",
                    systemImage: connectivity.isPaused ? "play.circle.fill" : "pause.circle.fill",
                    tint: connectivity.isPaused ? .green : .orange
                ) {
                    connectivity.togglePause()
                }
                singleButton(
                    title: "到着",
                    systemImage: "stop.circle.fill",
                    tint: .red
                ) {
                    connectivity.stopRecording()
                }
            }
        }
    }

    private func singleButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZStack {
                    Image(systemName: systemImage)
                        .opacity(connectivity.isSending ? 0 : 1)
                    if connectivity.isSending {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 18, height: 18)
                Text(title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .buttonStyle(.borderedProminent)
        .disabled(connectivity.isSending)
    }

    private var formattedElapsed: String {
        guard let startDate = connectivity.startDate else { return "00:00" }
        // 一時停止中は pausedAt を「現在」とみなして経過時間を止める。
        let referenceNow = connectivity.isPaused ? (connectivity.pausedAt ?? now) : now
        let elapsed = max(0, referenceNow.timeIntervalSince(startDate) - connectivity.pausedDuration)
        let h = Int(elapsed) / 3600
        let m = Int(elapsed) % 3600 / 60
        let s = Int(elapsed) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private var formattedDistance: String {
        let meters = connectivity.distance
        return meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }
}
