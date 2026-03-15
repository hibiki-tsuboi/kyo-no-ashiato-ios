//
//  RouteDetailView.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import MapKit

struct RouteDetailView: View {
    let route: RouteRecord
    @State private var position: MapCameraPosition = .automatic
    @State private var sliderValue: Double = 0
    @State private var markerProgress: Double = 0
    @State private var pendingMarkerProgress: Double = 0
    @State private var isSliding = false
    @State private var markerUpdateTask: Task<Void, Never>?
    @State private var isEditingTitle = false
    @State private var editingTitle = ""
    @State private var cachedCoords: [CLLocationCoordinate2D] = []
    @State private var cachedTotalDistance: CLLocationDistance = 0
    @State private var cachedMapRegion: MKCoordinateRegion?

    private var currentCoordinate: CLLocationCoordinate2D? {
        guard cachedCoords.count >= 2 else { return nil }
        let index = Int(markerProgress * Double(cachedCoords.count - 1))
        return cachedCoords[min(index, cachedCoords.count - 1)]
    }

    private var currentTime: Date? {
        guard let duration = route.duration else { return nil }
        return route.startDate.addingTimeInterval(sliderValue * duration)
    }

    var body: some View {
        Map(position: $position) {
            if let first = cachedCoords.first {
                Annotation("出発", coordinate: first) {
                    ZStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 32, height: 32)
                        Image(systemName: "figure.walk")
                            .foregroundStyle(.white)
                            .font(.caption)
                    }
                }
            }
            if let last = cachedCoords.last, cachedCoords.count > 1 {
                Annotation("到着", coordinate: last) {
                    ZStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 32, height: 32)
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.white)
                            .font(.caption)
                    }
                }
            }
            if cachedCoords.count >= 2 {
                MapPolyline(coordinates: cachedCoords)
                    .stroke(.yellow, lineWidth: 4)
            }
            if let coord = currentCoordinate {
                Annotation("", coordinate: coord) {
                    ZStack {
                        Circle()
                            .fill(.blue)
                            .frame(width: 36, height: 36)
                        Image(systemName: "figure.walk")
                            .foregroundStyle(.white)
                            .font(.subheadline)
                    }
                    .shadow(radius: 4)
                }
            }
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingTitle = route.title
                    isEditingTitle = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $isEditingTitle) {
            NavigationStack {
                Form {
                    TextField("タイトル", text: $editingTitle)
                }
                .navigationTitle("タイトルを編集")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("キャンセル") {
                            isEditingTitle = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            route.title = editingTitle
                            isEditingTitle = false
                        }
                        .disabled(editingTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(180)])
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if cachedCoords.count >= 2 {
                    timeSlider
                }
                routeInfoBar
            }
        }
        .onAppear {
            prepareRouteCache()
            if let region = cachedMapRegion {
                position = .region(region)
            }
        }
    }

    private var timeSlider: some View {
        VStack(spacing: 4) {
            if let time = currentTime {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Text("開始")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { sliderValue },
                        set: { newValue in
                            sliderValue = newValue
                            pendingMarkerProgress = newValue
                            if !isSliding {
                                markerProgress = newValue
                            }
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { isEditing in
                        isSliding = isEditing
                        if isEditing {
                            startMarkerUpdateLoop()
                        } else {
                            markerUpdateTask?.cancel()
                            markerUpdateTask = nil
                            markerProgress = sliderValue
                        }
                    }
                )
                    .tint(.blue)
                Text("終了")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var routeInfoBar: some View {
        HStack(spacing: 0) {
            infoItem(label: "開始", value: route.startDate.formatted(date: .omitted, time: .shortened))
            Divider().frame(height: 32)
            if let endDate = route.endDate {
                infoItem(label: "終了", value: endDate.formatted(date: .omitted, time: .shortened))
                Divider().frame(height: 32)
            }
            if let duration = route.duration {
                infoItem(label: "所要時間", value: formatDuration(duration))
                Divider().frame(height: 32)
            }
            infoItem(label: "距離", value: formatDistance(cachedTotalDistance))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func prepareRouteCache() {
        let sortedPoints = route.points.sorted { $0.timestamp < $1.timestamp }
        cachedCoords = sortedPoints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        cachedTotalDistance = calculateTotalDistance(from: cachedCoords)
        cachedMapRegion = calculateMapRegion(from: cachedCoords)
        markerProgress = sliderValue
        pendingMarkerProgress = sliderValue
    }

    private func startMarkerUpdateLoop() {
        markerUpdateTask?.cancel()
        markerUpdateTask = Task {
            while !Task.isCancelled && isSliding {
                markerProgress = pendingMarkerProgress
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func calculateTotalDistance(from coords: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coords.count >= 2 else { return 0 }
        return zip(coords, coords.dropFirst()).reduce(0) { sum, pair in
            let from = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let to = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return sum + from.distance(from: to)
        }
    }

    private func calculateMapRegion(from coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }

        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }

        guard
            let minLat = lats.min(),
            let maxLat = lats.max(),
            let minLon = lons.min(),
            let maxLon = lons.max()
        else {
            return nil
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private func infoItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        } else {
            return String(format: "%.0f m", meters)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let h = Int(duration) / 3600
        let m = Int(duration) % 3600 / 60
        if h > 0 {
            return "\(h)時間\(m)分"
        } else {
            return "\(m)分"
        }
    }
}
