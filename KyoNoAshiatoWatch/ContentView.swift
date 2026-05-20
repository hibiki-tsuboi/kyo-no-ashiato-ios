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

            if connectivity.isRecording {
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

            actionButton

            if let error = connectivity.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 4)
        .onReceive(ticker) { date in
            now = date
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: connectivity.isRecording ? "record.circle.fill" : "figure.walk")
                .foregroundStyle(connectivity.isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: connectivity.isRecording)
            Text(connectivity.isRecording ? "あしあと中" : "今日のあしあと")
                .font(.headline)
        }
    }

    private var actionButton: some View {
        Button {
            connectivity.toggleRecording()
        } label: {
            HStack {
                Image(systemName: connectivity.isRecording ? "stop.circle.fill" : "record.circle.fill")
                Text(connectivity.isRecording ? "到着" : "出発")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(connectivity.isRecording ? .red : .green)
        .buttonStyle(.borderedProminent)
    }

    private var formattedElapsed: String {
        guard let startDate = connectivity.startDate else { return "00:00" }
        let elapsed = max(0, now.timeIntervalSince(startDate))
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
