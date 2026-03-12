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

    private var coords: [CLLocationCoordinate2D] { route.coordinates }

    private var currentCoordinate: CLLocationCoordinate2D? {
        guard coords.count >= 2 else { return nil }
        let index = Int(sliderValue * Double(coords.count - 1))
        return coords[min(index, coords.count - 1)]
    }

    private var currentTime: Date? {
        guard let duration = route.duration else { return nil }
        return route.startDate.addingTimeInterval(sliderValue * duration)
    }

    var body: some View {
        Map(position: $position) {
            if let first = coords.first {
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
            if let last = coords.last, coords.count > 1 {
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
            if coords.count >= 2 {
                MapPolyline(coordinates: coords)
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if coords.count >= 2 {
                    timeSlider
                }
                routeInfoBar
            }
        }
        .onAppear {
            if let region = route.mapRegion {
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
                Slider(value: $sliderValue, in: 0...1)
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
            infoItem(label: "距離", value: formatDistance(route.totalDistance))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.regularMaterial)
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
