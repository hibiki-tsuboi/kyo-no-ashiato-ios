//
//  RouteDetailView.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import SwiftData
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

struct RouteDetailView: View {
    let route: RouteRecord
    @Environment(\.modelContext) private var modelContext
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
    @State private var isPlacingPhoto = false
    @State private var pendingPhotoCoordinate: CLLocationCoordinate2D?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhoto: RoutePhoto?
    @State private var photoThumbnails: [UUID: UIImage] = [:]

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
        ZStack(alignment: .bottomTrailing) {
            MapReader { proxy in
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
                    ForEach(route.photos) { photo in
                        Annotation("", coordinate: photo.coordinate) {
                            photoPin(photo)
                        }
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
                .onTapGesture(coordinateSpace: .local) { location in
                    guard isPlacingPhoto else { return }
                    guard let coordinate = proxy.convert(location, from: .local) else { return }
                    pendingPhotoCoordinate = coordinate
                    withAnimation { isPlacingPhoto = false }
                    isPhotoPickerPresented = true
                }
            }

            VStack(spacing: 12) {
                photoAddButton
                routeOverviewButton
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .top) {
            if isPlacingPhoto {
                placementBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
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
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoPickerItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await savePickedMedia(newItem) }
        }
        .sheet(item: $selectedPhoto) { photo in
            MediaViewerView(
                image: UIImage(data: photo.imageData),
                videoURL: photo.mediaType == .video ? videoTempURL(for: photo) : nil
            ) {
                deletePhoto(photo)
            }
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
            rebuildPhotoThumbnails()
            if let region = cachedMapRegion {
                position = .region(region)
            }
        }
    }

    private var routeOverviewButton: some View {
        Button {
            showEntireRoute()
        } label: {
            Image(systemName: "scope")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel("ルート全体を表示")
        .disabled(cachedMapRegion == nil)
    }

    private var photoAddButton: some View {
        Button {
            withAnimation { isPlacingPhoto = true }
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.title3)
                .foregroundStyle(isPlacingPhoto ? .white : .primary)
                .frame(width: 44, height: 44)
                .background(isPlacingPhoto ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial))
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel("写真・動画を追加")
    }

    private var placementBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
            Text("写真・動画を置く場所を地図でタップ")
                .font(.subheadline)
            Spacer(minLength: 8)
            Button("キャンセル") {
                withAnimation { isPlacingPhoto = false }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(radius: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func photoPin(_ photo: RoutePhoto) -> some View {
        Button {
            selectedPhoto = photo
        } label: {
            Group {
                if let thumbnail = photoThumbnails[photo.id] {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.gray)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white, lineWidth: 2)
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.mediaType == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.6), in: Circle())
                        .padding(2)
                }
            }
            .shadow(radius: 3)
        }
        .buttonStyle(.plain)
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

    private func showEntireRoute() {
        guard let region = cachedMapRegion else { return }
        withAnimation(.easeInOut) {
            position = .region(region)
        }
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

    // MARK: - Media

    private func savePickedMedia(_ item: PhotosPickerItem) async {
        defer { photoPickerItem = nil }
        guard let coordinate = pendingPhotoCoordinate else { return }
        pendingPhotoCoordinate = nil

        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if isVideo {
            await saveVideo(item, at: coordinate)
        } else {
            await savePhoto(item, at: coordinate)
        }
    }

    private func savePhoto(_ item: PhotosPickerItem, at coordinate: CLLocationCoordinate2D) async {
        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data),
            let resized = downscale(image, maxDimension: 2048),
            let jpeg = resized.jpegData(compressionQuality: 0.8)
        else { return }

        let photo = RoutePhoto(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            imageData: jpeg
        )
        modelContext.insert(photo)
        photo.route = route
        try? modelContext.save()

        if let thumbnail = downscale(resized, maxDimension: 160) {
            photoThumbnails[photo.id] = thumbnail
        }
    }

    private func saveVideo(_ item: PhotosPickerItem, at coordinate: CLLocationCoordinate2D) async {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return }
        defer { try? FileManager.default.removeItem(at: movie.url) }

        let asset = AVURLAsset(url: movie.url)
        guard
            let poster = await posterImage(from: asset),
            let resizedPoster = downscale(poster, maxDimension: 2048),
            let posterJPEG = resizedPoster.jpegData(compressionQuality: 0.8),
            let videoData = await compressedVideoData(from: asset)
        else { return }

        let media = RoutePhoto(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            imageData: posterJPEG,
            videoData: videoData
        )
        modelContext.insert(media)
        media.route = route
        try? modelContext.save()

        if let thumbnail = downscale(resizedPoster, maxDimension: 160) {
            photoThumbnails[media.id] = thumbnail
        }
    }

    /// 動画の先頭フレームをポスター画像として取り出す。
    private func posterImage(from asset: AVURLAsset) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 動画を中画質で再エンコードして容量を抑える。失敗時は元データをそのまま保持する。
    private func compressedVideoData(from asset: AVURLAsset) async -> Data? {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            return try? Data(contentsOf: asset.url)
        }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }
        do {
            try await export.export(to: outURL, as: .mp4)
            return try? Data(contentsOf: outURL)
        } catch {
            return try? Data(contentsOf: asset.url)
        }
    }

    /// 動画ビューア用に、保存済み動画データを一時ファイルへ書き出して URL を返す。
    private func videoTempURL(for photo: RoutePhoto) -> URL? {
        guard let data = photo.videoData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ashiato_\(photo.id.uuidString).mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
        return url
    }

    private func deletePhoto(_ photo: RoutePhoto) {
        photoThumbnails[photo.id] = nil
        modelContext.delete(photo)
        try? modelContext.save()
    }

    private func rebuildPhotoThumbnails() {
        var thumbnails: [UUID: UIImage] = [:]
        for photo in route.photos {
            if let image = UIImage(data: photo.imageData),
               let thumbnail = downscale(image, maxDimension: 160) {
                thumbnails[photo.id] = thumbnail
            }
        }
        photoThumbnails = thumbnails
    }

    /// 長辺が maxDimension を超える場合のみ縮小する。それ以下はそのまま返す。
    private func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Share

    private func generateShareSnapshot() async {
        guard let region = cachedMapRegion, cachedCoords.count >= 2 else { return }
        isGeneratingSnapshot = true
        defer { isGeneratingSnapshot = false }

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 600, height: 450)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            if let url = jpegFileURL(for: drawRoute(on: snapshot)) {
                shareItems = [url]
                isShowingShareSheet = true
            }
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

    private func jpegFileURL(for image: UIImage) -> URL? {
        let limit = 1_000_000
        var quality: CGFloat = 0.9
        while quality >= 0.1 {
            if let data = image.jpegData(compressionQuality: quality), data.count <= limit {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ashiato_share.jpg")
                try? data.write(to: url)
                return url
            }
            quality -= 0.1
        }
        return nil
    }

}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// メディアピンをタップしたときのフルスクリーン表示。写真は静止画、動画は再生プレイヤーを出す。
/// 画像・動画 URL は呼び出し元で用意したものを受け取るため、削除後に SwiftData オブジェクトへ触れずに済む。
private struct MediaViewerView: View {
    let image: UIImage?
    let videoURL: URL?
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false
    @State private var player: AVPlayer?

    private var isVideo: Bool { videoURL != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let videoURL {
                    VideoPlayer(player: player)
                        .onAppear {
                            if player == nil {
                                let newPlayer = AVPlayer(url: videoURL)
                                player = newPlayer
                                newPlayer.play()
                            }
                        }
                        .onDisappear { player?.pause() }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView("読み込めませんでした", systemImage: "photo")
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .alert(isVideo ? "この動画を削除しますか？" : "この写真を削除しますか？", isPresented: $isConfirmingDelete) {
                Button("削除", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("削除すると元に戻せません。")
            }
        }
    }
}

/// PhotosPicker から選ばれた動画をアプリの一時ディレクトリへコピーして受け取るための転送型。
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
