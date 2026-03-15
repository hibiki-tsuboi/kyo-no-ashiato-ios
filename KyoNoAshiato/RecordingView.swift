//
//  RecordingView.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import MapKit
import Combine

struct RecordingView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.modelContext) private var modelContext
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showPermissionAlert = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $position) {
                    UserAnnotation()
                    if locationManager.currentCoordinates.count >= 2 {
                        MapPolyline(coordinates: locationManager.currentCoordinates)
                            .stroke(.blue, lineWidth: 4)
                    }
                }
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    if locationManager.isRecording {
                        RecordingStatusView(route: locationManager.currentRoute)
                            .padding(.bottom, 12)
                    }
                    recordingButton
                        .padding(.bottom, 48)
                }
            }
            .navigationTitle("今日のあしあと")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            locationManager.setup(modelContext: modelContext)
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestPermission()
            }
        }
        .onChange(of: locationManager.authorizationStatus) { _, status in
            if status == .denied || status == .restricted {
                showPermissionAlert = true
            }
        }
        .alert("位置情報の許可が必要です", isPresented: $showPermissionAlert) {
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("あしあとを残すために位置情報へのアクセスを許可してください。")
        }
    }

    private var recordingButton: some View {
        Button {
            if locationManager.isRecording {
                locationManager.stopRecording()
            } else {
                locationManager.startRecording()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: locationManager.isRecording ? "stop.circle.fill" : "record.circle.fill")
                    .font(.title2)
                Text(locationManager.isRecording ? "あしあとを終了" : "あしあとを開始")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(locationManager.isRecording ? Color.red : Color.green)
            .clipShape(Capsule())
            .shadow(radius: 6)
        }
    }
}

struct RecordingStatusView: View {
    let route: RouteRecord?
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text("あしあと中  \(formattedElapsed)")
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(radius: 4)
        .onReceive(timer) { _ in
            if let startDate = route?.startDate {
                elapsed = Date().timeIntervalSince(startDate)
            }
        }
        .onAppear {
            if let startDate = route?.startDate {
                elapsed = Date().timeIntervalSince(startDate)
            }
        }
    }

    private var formattedElapsed: String {
        let h = Int(elapsed) / 3600
        let m = Int(elapsed) % 3600 / 60
        let s = Int(elapsed) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
