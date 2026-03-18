//
//  RouteDetailView.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import MapKit
import UIKit

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
    @State private var isEditingTransportMode = false
    @State private var selectedTransportMode: TransportMode = .walking
    @State private var cachedCoords: [CLLocationCoordinate2D] = []
    @State private var cachedTotalDistance: CLLocationDistance = 0
    @State private var cachedMapRegion: MKCoordinateRegion?
    @State private var shareItems: [Any] = []
    @State private var isShowingShareSheet = false
    @State private var isGeneratingSnapshot = false

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
                    .stroke(.blue, lineWidth: 4)
            }
            if let coord = currentCoordinate {
                Annotation("", coordinate: coord) {
                    ZStack {
                        Circle()
                            .fill(.orange)
                            .frame(width: 32, height: 32)
                        Text("👣")
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
                    Task { await generateShareSnapshot() }
                } label: {
                    if isGeneratingSnapshot {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isGeneratingSnapshot)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editingTitle = route.title
                        isEditingTitle = true
                    } label: {
                        Label("タイトルを編集", systemImage: "pencil")
                    }
                    Button {
                        selectedTransportMode = route.transportMode
                        isEditingTransportMode = true
                    } label: {
                        Label("移動手段を変更", systemImage: "figure.walk.motion")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
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
        .sheet(isPresented: $isEditingTransportMode) {
            NavigationStack {
                Form {
                    Section {
                        Picker("移動手段", selection: $selectedTransportMode) {
                            ForEach(TransportMode.allCases, id: \.self) { mode in
                                Label("\(mode.emoji) \(mode.label)", systemImage: "")
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    if route.manualTransportMode != nil {
                        Section {
                            Button("自動判定に戻す", role: .destructive) {
                                route.manualTransportMode = nil
                                isEditingTransportMode = false
                            }
                        }
                    }
                }
                .navigationTitle("移動手段を変更")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("キャンセル") {
                            isEditingTransportMode = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            route.manualTransportMode = selectedTransportMode
                            isEditingTransportMode = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ShareSheet(items: shareItems)
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
                Text("出発")
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
                Text("到着")
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
            infoItem(icon: "📍", label: "出発", value: route.startDate.formatted(date: .omitted, time: .shortened))
            Divider().frame(height: 32)
            if let endDate = route.endDate {
                infoItem(icon: "🏁", label: "到着", value: endDate.formatted(date: .omitted, time: .shortened))
                Divider().frame(height: 32)
            }
            if let duration = route.duration {
                infoItem(icon: "⏱️", label: "所要時間", value: formatDuration(duration))
                Divider().frame(height: 32)
            }
            infoItem(
                icon: route.transportMode.emoji,
                label: "距離",
                value: formatDistance(cachedTotalDistance)
            )
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

    private func infoItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(icon)
                Text(label)
            }
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

    // MARK: - Share

    private func generateShareSnapshot() async {
        guard let region = cachedMapRegion, cachedCoords.count >= 2 else { return }
        isGeneratingSnapshot = true
        defer { isGeneratingSnapshot = false }

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 800, height: 600)
        options.scale = 2

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            let image = compressUnder1MB(drawRoute(on: snapshot))
            shareItems = [image]
            isShowingShareSheet = true
        } catch {
            shareItems = []
        }
    }

    private func drawRoute(on snapshot: MKMapSnapshotter.Snapshot) -> UIImage {
        let base = snapshot.image
        let renderer = UIGraphicsImageRenderer(size: base.size, format: {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = base.scale
            return fmt
        }())
        return renderer.image { ctx in
            base.draw(at: .zero)
            let cgCtx = ctx.cgContext

            // ルートのポリライン描画
            cgCtx.setStrokeColor(UIColor.systemBlue.cgColor)
            cgCtx.setLineWidth(4)
            cgCtx.setLineCap(.round)
            cgCtx.setLineJoin(.round)
            if let first = cachedCoords.first {
                cgCtx.move(to: snapshot.point(for: first))
            }
            for coord in cachedCoords.dropFirst() {
                cgCtx.addLine(to: snapshot.point(for: coord))
            }
            cgCtx.strokePath()

            // 出発マーカー（緑）
            if let first = cachedCoords.first {
                drawCircleMarker(at: snapshot.point(for: first), color: .systemGreen, in: cgCtx)
            }
            // 到着マーカー（赤）
            if let last = cachedCoords.last {
                drawCircleMarker(at: snapshot.point(for: last), color: .systemRed, in: cgCtx)
            }
        }
    }

    private func drawCircleMarker(at point: CGPoint, color: UIColor, in ctx: CGContext) {
        let radius: CGFloat = 10
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.fillEllipse(in: rect)
        ctx.strokeEllipse(in: rect)
    }

    private func compressUnder1MB(_ image: UIImage) -> UIImage {
        let limit = 1_000_000
        var quality: CGFloat = 0.9
        while quality > 0.1 {
            if let data = image.jpegData(compressionQuality: quality), data.count <= limit,
               let compressed = UIImage(data: data) {
                return compressed
            }
            quality -= 0.1
        }
        return image
    }

}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
