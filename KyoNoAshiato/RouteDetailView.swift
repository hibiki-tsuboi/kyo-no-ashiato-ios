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

    var body: some View {
        Map(position: $position) {
            let coords = route.coordinates
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
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            routeInfoBar
        }
        .onAppear {
            if let region = route.mapRegion {
                position = .region(region)
            }
        }
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
            }
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
