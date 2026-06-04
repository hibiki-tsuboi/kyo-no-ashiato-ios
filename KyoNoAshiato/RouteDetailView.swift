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
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhoto: RoutePhoto?
    @State private var carouselPinSnapshot: [RoutePhoto] = []
    @State private var photoThumbnails: [UUID: UIImage] = [:]
    @State private var isSavingMedia = false
    @State private var savingPinCoordinate: CLLocationCoordinate2D?
    @State private var isAutoPlacePickerPresented = false
    @State private var autoPlacePickerItems: [PhotosPickerItem] = []
    @State private var skippedItems: [SkippedItem] = []
    @State private var pendingSkippedItem: SkippedItem?

    private var currentCoordinate: CLLocationCoordinate2D? {
        guard cachedCoords.count >= 2 else { return nil }
        let index = Int(markerProgress * Double(cachedCoords.count - 1))
        return cachedCoords[min(index, cachedCoords.count - 1)]
    }

    private var currentTime: Date? {
        guard let duration = route.duration else { return nil }
        return route.startDate.addingTimeInterval(sliderValue * duration)
    }

    /// ピン横断ナビ用の並び順。撮影日時が無いピンは作成日時にフォールバックする。
    private var sortedPhotos: [RoutePhoto] {
        route.photos.sorted { $0.orderingDate < $1.orderingDate }
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
                    if let savingPinCoordinate {
                        Annotation("", coordinate: savingPinCoordinate) {
                            savingPinPlaceholder
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
                    withAnimation { isPlacingPhoto = false }
                    if let skipped = pendingSkippedItem {
                        // スキップサムネ経由：1 枚を即配置してキューから取り除く
                        pendingSkippedItem = nil
                        placeMedia(skipped.media, at: coordinate)
                        skippedItems.removeAll { $0.id == skipped.id }
                        try? modelContext.save()
                        notifyMediaSaveSuccess()
                    } else {
                        pendingPhotoCoordinate = coordinate
                        isPhotoPickerPresented = true
                    }
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
            // スキップサムネからの個別配置時のみ、対象を思い出させるためにバナーを出す。
            // 通常の手動モードはメニュー文言で意図が明確 + 右下ボタンが解除動作なので不要。
            if isPlacingPhoto, pendingSkippedItem != nil {
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
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoPickerItems,
            maxSelectionCount: 0,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            // state 書き戻しは view 更新サイクルの外に出して "Modifying state during view update" を避ける
            Task { @MainActor in
                photoPickerItems = []
                await savePickedMedia(items)
            }
        }
        .photosPicker(
            isPresented: $isAutoPlacePickerPresented,
            selection: $autoPlacePickerItems,
            maxSelectionCount: 0,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: autoPlacePickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            Task { @MainActor in
                autoPlacePickerItems = []
                await autoPlacePickedMedia(items)
            }
        }
        .sheet(item: $selectedPhoto) { photo in
            let snapshot = carouselPinSnapshot.isEmpty ? sortedPhotos : carouselPinSnapshot
            let initialIndex = snapshot.firstIndex(where: { $0.id == photo.id }) ?? 0
            MediaCarouselView(
                pins: snapshot,
                initialPinIndex: initialIndex,
                videoURLProvider: { videoTempURL(for: $0) },
                onDeleteItem: { item, pin in
                    deleteMediaItem(item, in: pin)
                },
                onPinEmptied: { pin in
                    deletePin(pin)
                },
                onAddMedia: { pin, items in
                    await addMedia(items, to: pin)
                },
                onActivePinChanged: { pin in
                    focusMap(on: pin.coordinate)
                }
            )
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !skippedItems.isEmpty {
                    skippedItemsBanner
                }
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

    @ViewBuilder
    private var photoAddButton: some View {
        if isPlacingPhoto {
            // 「残す」モード中はメニューを開かず、押したら解除のキャンセルボタンになる。
            Button {
                pendingSkippedItem = nil
                withAnimation { isPlacingPhoto = false }
            } label: {
                photoAddButtonLabel
            }
            .disabled(isSavingMedia)
            .accessibilityLabel("残すモードを終了")
        } else {
            Menu {
                Button {
                    withAnimation { isPlacingPhoto = true }
                } label: {
                    Label("地図をタップして残す（手動）", systemImage: "hand.tap")
                }
                Button {
                    isAutoPlacePickerPresented = true
                } label: {
                    Label("写真の位置情報から残す（自動）", systemImage: "sparkles")
                }
            } label: {
                photoAddButtonLabel
            }
            .disabled(isSavingMedia)
            .accessibilityLabel("写真・動画を残す")
        }
    }

    private var photoAddButtonLabel: some View {
        Group {
            if isSavingMedia {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: "photo.badge.plus")
                    .font(.title3)
                    .foregroundStyle(isPlacingPhoto ? .white : .primary)
            }
        }
        .frame(width: 44, height: 44)
        .background(isPlacingPhoto ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial))
        .clipShape(Circle())
        .shadow(radius: 4)
    }

    private var savingPinPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.45))
                .frame(width: 46, height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white, lineWidth: 2)
                }
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
        .shadow(radius: 3)
    }

    private var placementBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
            Text("この写真を残したい場所をタップ")
                .font(.subheadline)
            Spacer(minLength: 8)
            Button("キャンセル") {
                pendingSkippedItem = nil
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

    /// 自動配置で GPS が見つからずスキップされた写真・動画を並べるバナー。
    /// サムネタップで「この 1 枚を地図タップで置く」モードへ入る。× で破棄。
    private var skippedItemsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("位置情報なし — タップして残す (\(skippedItems.count))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(skippedItems) { item in
                        skippedThumbnail(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func skippedThumbnail(_ item: SkippedItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: item.media.resizedImage)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if item.media.videoData != nil {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .font(.caption)
                            .padding(3)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    pendingSkippedItem = item
                    withAnimation { isPlacingPhoto = true }
                }

            Button {
                // 配置モード進行中の対象を破棄したらモードも畳む。さもないとバナーが孤児ピンを指し続ける。
                if pendingSkippedItem?.id == item.id {
                    pendingSkippedItem = nil
                    withAnimation { isPlacingPhoto = false }
                }
                skippedItems.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7))
                    .font(.callout)
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("この写真を破棄")
        }
        .frame(width: 56, height: 56)
    }

    private func photoPin(_ photo: RoutePhoto) -> some View {
        let mediaCount = photo.allMedia.count
        let representativeIsVideo = photo.representative.mediaType == .video
        return Button {
            // タップ時点の並び順を凍結して渡す。シート中に photos が増減しても順序が揺れない。
            carouselPinSnapshot = sortedPhotos
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
                if representativeIsVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.6), in: Circle())
                        .padding(2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if mediaCount > 1 {
                    Text("\(mediaCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule())
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

    /// カルーセル内のピン切替に合わせて地図カメラをそのピンに寄せる。
    /// シートで地図が隠れている間に位置を更新しておけば、閉じたとき自然にそのピンが中央に来る。
    private func focusMap(on coordinate: CLLocationCoordinate2D) {
        let span = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        withAnimation(.easeInOut) {
            position = .region(MKCoordinateRegion(center: coordinate, span: span))
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

    /// 写真または動画を準備したあとの中間データ。1 メディア分。
    fileprivate struct PreparedMedia {
        let imageData: Data
        let videoData: Data?
        /// サムネ生成に再利用するための、リサイズ済み静止画。
        let resizedImage: UIImage
        /// EXIF / 動画メタデータから取り出した撮影位置。自動配置のフォールバック判断に使う。
        let coordinate: CLLocationCoordinate2D?
        /// EXIF / 動画メタデータから取り出した撮影日時。並び順の主キーに使う。
        let captureDate: Date?
    }

    /// 自動配置時に GPS が無くてスキップされ、サムネバナーで再配置を待つ 1 件。
    fileprivate struct SkippedItem: Identifiable {
        let id = UUID()
        let media: PreparedMedia
    }

    private func savePickedMedia(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        guard let coordinate = pendingPhotoCoordinate else { return }
        pendingPhotoCoordinate = nil

        isSavingMedia = true
        savingPinCoordinate = coordinate
        defer {
            isSavingMedia = false
            savingPinCoordinate = nil
        }

        var prepared: [PreparedMedia] = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo {
                if let p = await prepareVideo(item) {
                    prepared.append(p)
                }
            } else {
                if let p = await preparePhoto(item) {
                    prepared.append(p)
                }
            }
        }

        guard let first = prepared.first else { return }

        // 1 タップで作る 1 ピン。レガシー列は先頭メディアでシードして互換性を保ち、
        // 実体は `media` に全件 RouteMedia としてぶら下げる（表示は `allMedia` 経由）。
        // 並び順用には、選んだメディアのうち最も古い撮影日時を採用する。
        let earliestCaptureDate = prepared.compactMap(\.captureDate).min()
        let pin = RoutePhoto(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            imageData: first.imageData,
            videoData: first.videoData,
            captureDate: earliestCaptureDate
        )
        modelContext.insert(pin)
        pin.route = route

        for (index, p) in prepared.enumerated() {
            let media = RouteMedia(
                imageData: p.imageData,
                videoData: p.videoData,
                sortOrder: index
            )
            modelContext.insert(media)
            media.photo = pin
        }
        try? modelContext.save()

        if let thumbnail = downscale(first.resizedImage, maxDimension: 160) {
            photoThumbnails[pin.id] = thumbnail
        }

        notifyMediaSaveSuccess()
    }

    private func notifyMediaSaveSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 自動配置フロー本体。
    /// 各メディアを prepare → GPS あり: 即 RoutePhoto を作成 / GPS なし: スキップキューに退避。
    private func autoPlacePickedMedia(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isSavingMedia = true
        defer { isSavingMedia = false }

        var placedAny = false
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            let prepared: PreparedMedia?
            if isVideo {
                prepared = await prepareVideo(item)
            } else {
                prepared = await preparePhoto(item)
            }
            guard let media = prepared else { continue }

            if let coord = media.coordinate {
                placeMedia(media, at: coord)
                placedAny = true
            } else {
                skippedItems.append(SkippedItem(media: media))
            }
        }

        if placedAny {
            try? modelContext.save()
            notifyMediaSaveSuccess()
        }
    }

    /// 1 件分の PreparedMedia を指定座標に即追加する。
    /// 自動配置と、スキップ後のサムネバナーからの個別タップ配置の両方から呼ぶ。
    private func placeMedia(_ media: PreparedMedia, at coordinate: CLLocationCoordinate2D) {
        let pin = RoutePhoto(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            imageData: media.imageData,
            videoData: media.videoData,
            captureDate: media.captureDate
        )
        modelContext.insert(pin)
        pin.route = route

        let routeMedia = RouteMedia(
            imageData: media.imageData,
            videoData: media.videoData,
            sortOrder: 0
        )
        modelContext.insert(routeMedia)
        routeMedia.photo = pin

        if let thumbnail = downscale(media.resizedImage, maxDimension: 160) {
            photoThumbnails[pin.id] = thumbnail
        }
    }

    private func preparePhoto(_ item: PhotosPickerItem) async -> PreparedMedia? {
        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data),
            let resized = downscale(image, maxDimension: 2048),
            let jpeg = resized.jpegData(compressionQuality: 0.8)
        else { return nil }
        // GPS / 撮影日時は EXIF を保ったオリジナル Data から読む。リサイズ後の JPEG には EXIF が落ちうる。
        let coordinate = MediaLocation.extract(fromImage: data)
        let captureDate = MediaLocation.extractCaptureDate(fromImage: data)
        return PreparedMedia(
            imageData: jpeg,
            videoData: nil,
            resizedImage: resized,
            coordinate: coordinate,
            captureDate: captureDate
        )
    }

    private func prepareVideo(_ item: PhotosPickerItem) async -> PreparedMedia? {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return nil }
        defer { try? FileManager.default.removeItem(at: movie.url) }

        let asset = AVURLAsset(url: movie.url)
        guard
            let poster = await posterImage(from: asset),
            let resizedPoster = downscale(poster, maxDimension: 2048),
            let posterJPEG = resizedPoster.jpegData(compressionQuality: 0.8),
            let videoData = await compressedVideoData(from: asset)
        else { return nil }
        let coordinate = await MediaLocation.extract(fromVideo: asset)
        let captureDate = await MediaLocation.extractCaptureDate(fromVideo: asset)
        return PreparedMedia(
            imageData: posterJPEG,
            videoData: videoData,
            resizedImage: resizedPoster,
            coordinate: coordinate,
            captureDate: captureDate
        )
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
    private func videoTempURL(for item: MediaItem) -> URL? {
        guard let data = item.videoData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ashiato_\(item.id.uuidString).mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
        return url
    }

    /// 既存ピンへ複数メディアを追記する。
    /// - 旧データ（`pin.media` が空）に追加する場合は、まずレガシー列の内容を
    ///   `sortOrder: 0` の `RouteMedia` として「昇格」させてから、追加分を続けて並べる。
    ///   こうしないと、追加後に `allMedia` が `media` 配列だけを参照して、旧データが見えなくなる。
    /// - 戻り値は追記後の `pin.allMedia`。カルーセル側はこれでローカルスナップショットを差し替える。
    private func addMedia(_ items: [PhotosPickerItem], to pin: RoutePhoto) async -> [MediaItem] {
        var prepared: [PreparedMedia] = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo {
                if let p = await prepareVideo(item) { prepared.append(p) }
            } else {
                if let p = await preparePhoto(item) { prepared.append(p) }
            }
        }
        guard !prepared.isEmpty else { return pin.allMedia }

        // 旧データを RouteMedia(sortOrder: 0) に昇格。
        // `pin.imageData` / `videoData` 自体は互換性のため残しておく（pin.allMedia は
        // `media` が非空ならそちらを優先するので、重複表示にはならない）。
        if pin.media.isEmpty {
            let legacy = RouteMedia(
                imageData: pin.imageData,
                videoData: pin.videoData,
                sortOrder: 0
            )
            modelContext.insert(legacy)
            legacy.photo = pin
        }

        let startOrder = (pin.media.map(\.sortOrder).max() ?? -1) + 1
        for (i, p) in prepared.enumerated() {
            let media = RouteMedia(
                imageData: p.imageData,
                videoData: p.videoData,
                sortOrder: startOrder + i
            )
            modelContext.insert(media)
            media.photo = pin
        }
        try? modelContext.save()

        // 旧データを legacy 昇格させたケースなど、representative が同じ画像でもキャッシュキー側で
        // 連動できないことがあるので、追記後は無条件に当該ピンのサムネだけ生成し直す。
        refreshThumbnail(for: pin)

        notifyMediaSaveSuccess()

        return pin.allMedia
    }

    /// カルーセル内で個別メディアを削除する。
    /// - レガシー（旧 1 対 1 のピン本体）を消す場合はピンごと削除する。
    /// - 新形式の RouteMedia 1 件を消す場合はそれだけ削除し、ピンは残す。
    ///   呼び出し側で残数が 0 になったら `deletePin` を別途呼ぶ。
    private func deleteMediaItem(_ item: MediaItem, in pin: RoutePhoto) {
        switch item {
        case .legacy:
            deletePin(pin)
        case .modern(let media):
            modelContext.delete(media)
            try? modelContext.save()
            // 代表メディア（sortOrder: 0）が消えると地図ピンに古いサムネが残るので、削除のたびに更新する。
            refreshThumbnail(for: pin)
        }
    }

    private func deletePin(_ pin: RoutePhoto) {
        photoThumbnails[pin.id] = nil
        modelContext.delete(pin)
        try? modelContext.save()
    }

    private func rebuildPhotoThumbnails() {
        var thumbnails: [UUID: UIImage] = [:]
        for photo in route.photos {
            if let image = UIImage(data: photo.representative.imageData),
               let thumbnail = downscale(image, maxDimension: 160) {
                thumbnails[photo.id] = thumbnail
            }
        }
        photoThumbnails = thumbnails
    }

    /// 1 ピンぶんのサムネだけを `representative` から再生成する。
    /// 全件再構築の `rebuildPhotoThumbnails` は `onAppear` 用、こちらは個別更新用。
    private func refreshThumbnail(for pin: RoutePhoto) {
        guard
            let image = UIImage(data: pin.representative.imageData),
            let thumbnail = downscale(image, maxDimension: 160)
        else {
            photoThumbnails[pin.id] = nil
            return
        }
        photoThumbnails[pin.id] = thumbnail
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

/// ピンに紐づく複数メディアを横スワイプで閲覧するためのフルスクリーンビュー。
/// 旧データ（`media` 空）でも `RoutePhoto.allMedia` が 1 件返してくれるので、
/// 単体メディア時代のピンもそのまま 1 ページのカルーセルとして同じコードで表示できる。
///
/// さらに、複数ピンを横断する「次のピン／前のピン」ナビも担う。
/// `pins` には親が並び順スナップショットを渡し、ビュー内で `localPins` として固定保持する。
private struct MediaCarouselView: View {
    /// 表示対象のピン一覧（並び順は親が決める）。`onAppear` で一度だけスナップショット化する。
    let pins: [RoutePhoto]
    let initialPinIndex: Int
    let videoURLProvider: (MediaItem) -> URL?
    /// 個別メディア 1 件の削除依頼。呼び出し側でレガシーか新形式かに応じた削除を行う。
    let onDeleteItem: (MediaItem, RoutePhoto) -> Void
    /// 最後の 1 件を削除して空になった場合の通知。呼び出し側はピンごと削除する。
    let onPinEmptied: (RoutePhoto) -> Void
    /// 当該ピンに対する追記依頼。呼び出し側で保存処理を行い、追記後の `allMedia` を返す。
    let onAddMedia: (RoutePhoto, [PhotosPickerItem]) async -> [MediaItem]
    /// ピン切替時の通知。親は地図カメラをそのピンに寄せる。
    let onActivePinChanged: (RoutePhoto) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 親から渡された `pins` をオープン時に固定して保持するローカルスナップショット。
    /// ピン削除はまずこの配列を更新し、そのあとに SwiftData 側を触る。
    @State private var localPins: [RoutePhoto] = []
    @State private var currentPinIndex: Int = 0
    /// 現在ピンの `allMedia` のローカルスナップショット。
    @State private var items: [MediaItem] = []
    @State private var hasLoaded = false
    @State private var currentMediaIndex = 0
    @State private var isConfirmingDelete = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isPickerPresented = false
    @State private var isAddingMedia = false

    private var safeMediaIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(currentMediaIndex, 0), items.count - 1)
    }

    private var currentPin: RoutePhoto? {
        guard !localPins.isEmpty,
              currentPinIndex >= 0,
              currentPinIndex < localPins.count
        else { return nil }
        return localPins[currentPinIndex]
    }

    private var canGoPrevPin: Bool { currentPinIndex > 0 }
    private var canGoNextPin: Bool { currentPinIndex < localPins.count - 1 }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("読み込めませんでした", systemImage: "photo")
                        .foregroundStyle(.white)
                } else {
                    TabView(selection: $currentMediaIndex) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            mediaPage(item)
                                .tag(index)
                        }
                    }
                    // ピン切替時に TabView の内部状態（スワイプ位置・動画プレイヤー）を確実に作り直す。
                    .id(currentPin?.id)
                    .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .safeAreaInset(edge: .bottom) {
                if localPins.count > 1 {
                    pinNavigationBar
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPickerPresented = true
                    } label: {
                        if isAddingMedia {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "photo.badge.plus")
                        }
                    }
                    .disabled(isAddingMedia)
                    .accessibilityLabel("写真・動画を追加")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(items.isEmpty || isAddingMedia)
                }
            }
            .alert(deleteAlertTitle, isPresented: $isConfirmingDelete) {
                Button("削除", role: .destructive) { performDelete() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("削除すると元に戻せません。")
            }
            .photosPicker(
                isPresented: $isPickerPresented,
                selection: $pickerItems,
                maxSelectionCount: 0,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: pickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let picked = newItems
                // state 書き戻しは view 更新サイクルの外に出して "Modifying state during view update" を避ける
                Task { @MainActor in
                    pickerItems = []
                    await performAdd(picked)
                }
            }
            .onAppear {
                guard !hasLoaded else { return }
                localPins = pins
                currentPinIndex = min(max(initialPinIndex, 0), max(localPins.count - 1, 0))
                loadCurrentPinMedia()
                if let pin = currentPin {
                    onActivePinChanged(pin)
                }
                hasLoaded = true
            }
        }
    }

    private var pinNavigationBar: some View {
        HStack(spacing: 0) {
            Button {
                navigatePin(by: -1)
            } label: {
                Label("前の地点", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(canGoPrevPin ? .white : .white.opacity(0.3))
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoPrevPin || isAddingMedia)
            .accessibilityLabel("前の地点")

            Spacer(minLength: 0)
            Text("\(currentPinIndex + 1) / \(localPins.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .monospacedDigit()
            Spacer(minLength: 0)

            Button {
                navigatePin(by: 1)
            } label: {
                Label("次の地点", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(canGoNextPin ? .white : .white.opacity(0.3))
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoNextPin || isAddingMedia)
            .accessibilityLabel("次の地点")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5))
    }

    private var deleteAlertTitle: String {
        guard !items.isEmpty else { return "" }
        let isVideo = items[safeMediaIndex].mediaType == .video
        return isVideo ? "この動画を削除しますか？" : "この写真を削除しますか？"
    }

    @ViewBuilder
    private func mediaPage(_ item: MediaItem) -> some View {
        if item.mediaType == .video, let url = videoURLProvider(item) {
            VideoPage(url: url)
        } else if let image = UIImage(data: item.imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ContentUnavailableView("読み込めませんでした", systemImage: "photo")
                .foregroundStyle(.white)
        }
    }

    private func navigatePin(by offset: Int) {
        let newIndex = currentPinIndex + offset
        guard newIndex >= 0, newIndex < localPins.count else { return }
        currentPinIndex = newIndex
        loadCurrentPinMedia()
        if let pin = currentPin {
            onActivePinChanged(pin)
        }
    }

    private func loadCurrentPinMedia() {
        guard let pin = currentPin else {
            items = []
            currentMediaIndex = 0
            return
        }
        items = pin.allMedia
        currentMediaIndex = 0
    }

    private func performAdd(_ picked: [PhotosPickerItem]) async {
        guard let pin = currentPin else { return }
        isAddingMedia = true
        defer { isAddingMedia = false }

        let previousCount = items.count
        let updated = await onAddMedia(pin, picked)
        guard updated.count > previousCount else { return }

        items = updated
        // 追記分の先頭ページへ移動して、新しく入れたメディアが見えるようにする。
        currentMediaIndex = min(previousCount, max(0, items.count - 1))
    }

    private func performDelete() {
        guard !items.isEmpty, let pin = currentPin else { return }
        let index = safeMediaIndex
        let target = items[index]
        let willEmptyPin = items.count <= 1

        if willEmptyPin {
            // ピンが空になる削除：
            // - 他にピンが残っていれば、ローカル配列からピンを外し、隣のピンへ移動してから SwiftData を触る。
            // - 最後のピンなら、items を先に空にして dismiss してから削除を流す（観測中の entity 参照を切るため）。
            let pinIndexToRemove = currentPinIndex

            if localPins.count <= 1 {
                items = []
                localPins.removeAll()
                dismiss()
                onDeleteItem(target, pin)
                if case .modern = target {
                    onPinEmptied(pin)
                }
                return
            }

            // 隣のピンへ寄せる：末尾を削るときは前へ、それ以外は同じ index（次のピンに自然にスライド）。
            localPins.remove(at: pinIndexToRemove)
            if currentPinIndex >= localPins.count {
                currentPinIndex = localPins.count - 1
            }
            loadCurrentPinMedia()
            if let nextPin = currentPin {
                onActivePinChanged(nextPin)
            }

            onDeleteItem(target, pin)
            if case .modern = target {
                onPinEmptied(pin)
            }
        } else {
            items.remove(at: index)
            if currentMediaIndex >= items.count {
                currentMediaIndex = max(0, items.count - 1)
            }
            onDeleteItem(target, pin)
        }
    }
}

/// カルーセル内で動画ページが表示されている間だけ再生する小コンポーネント。
/// 各ページが独立した AVPlayer を持つので、スワイプで別ページに移ると自動で停止する。
private struct VideoPage: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                if player == nil {
                    let newPlayer = AVPlayer(url: url)
                    player = newPlayer
                    newPlayer.play()
                }
            }
            .onDisappear {
                player?.pause()
                player = nil
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
