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

            actionButton
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.orange.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                ZStack {
                    Image(systemName: connectivity.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .opacity(connectivity.isSending ? 0 : 1)
                    if connectivity.isSending {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 20, height: 20)
                Text(connectivity.isRecording ? "到着" : "出発")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(connectivity.isRecording ? .red : .green)
        .buttonStyle(.borderedProminent)
        .disabled(connectivity.isSending)
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
