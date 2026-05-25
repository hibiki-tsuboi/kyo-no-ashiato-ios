//
//  RecordingView.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import SwiftData
import MapKit
import Combine

struct RecordingView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.modelContext) private var modelContext
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showPermissionAlert = false
    @State private var completedRoute: RouteRecord?
    @State private var isHomeSet = HomeStore.shared.isConfigured
    @State private var homeMessage: String?

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

                currentLocationButton
                    .padding(.trailing, 16)
                    .padding(.bottom, 54)

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            setHomeToCurrentLocation()
                        } label: {
                            Label(isHomeSet ? "現在地で自宅を更新" : "現在地を自宅にする",
                                  systemImage: "house")
                        }
                        if isHomeSet {
                            Button(role: .destructive) {
                                HomeStore.shared.clearHome()
                                isHomeSet = false
                            } label: {
                                Label("自宅の設定を解除", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: isHomeSet ? "house.fill" : "house")
                    }
                    .accessibilityLabel("自宅の設定")
                }
            }
        }
        .onAppear {
            locationManager.setup(modelContext: modelContext)
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestPermission()
            }
            NotificationManager.shared.requestAuthorization()
        }
        .onChange(of: locationManager.authorizationStatus) { _, status in
            if status == .denied || status == .restricted {
                showPermissionAlert = true
            }
        }
        .sheet(item: $completedRoute) { route in
            ArrivalSheet(route: route)
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
        .alert("自宅の設定", isPresented: Binding(
            get: { homeMessage != nil },
            set: { if !$0 { homeMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(homeMessage ?? "")
        }
    }

    private func setHomeToCurrentLocation() {
        locationManager.captureCurrentLocation { coordinate in
            if let coordinate {
                HomeStore.shared.setHome(coordinate)
                isHomeSet = true
                homeMessage = "現在地を自宅として設定しました。次に自宅から離れたときにお知らせします。"
            } else {
                homeMessage = "現在地を取得できませんでした。屋外などで少し待ってから、もう一度お試しください。"
            }
        }
    }

    private var currentLocationButton: some View {
        Button {
            centerOnCurrentLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel("現在地へ移動")
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var recordingButton: some View {
        Button {
            if locationManager.isRecording {
                let route = locationManager.currentRoute
                locationManager.stopRecording()
                completedRoute = route
            } else {
                locationManager.startRecording()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: locationManager.isRecording ? "stop.circle.fill" : "record.circle.fill")
                    .font(.title2)
                Text(locationManager.isRecording ? "到着" : "出発")
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

    private func centerOnCurrentLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestPermission()
        case .denied, .restricted:
            showPermissionAlert = true
        default:
            withAnimation(.easeInOut) {
                position = .userLocation(followsHeading: false, fallback: .automatic)
            }
        }
    }
}

struct ArrivalSheet: View {
    let route: RouteRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var title: String

    init(route: RouteRecord) {
        self.route = route
        self._title = State(initialValue: route.title)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("👣")
                    .font(.system(size: 64))
                Text("あしあとを記録しました")
                    .font(.title2)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 8) {
                    Text("タイトル")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("タイトル", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(spacing: 12) {
                    summaryRow(icon: "📍", label: "出発", value: route.startDate.formatted(date: .omitted, time: .shortened))
                    if let endDate = route.endDate {
                        summaryRow(icon: "🏁", label: "到着", value: endDate.formatted(date: .omitted, time: .shortened))
                    }
                    if let duration = route.duration {
                        summaryRow(icon: "⏱️", label: "所要時間", value: formatDuration(duration))
                    }
                    summaryRow(icon: route.transportMode.emoji, label: "距離", value: formatDistance(route.totalDistance))
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        route.title = title
                        try? modelContext.save()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Text(icon)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.1f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let h = Int(duration) / 3600
        let m = Int(duration) % 3600 / 60
        let s = Int(duration) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
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
