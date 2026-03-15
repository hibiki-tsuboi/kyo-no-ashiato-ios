//
//  HistoryListView.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Query(sort: \RouteRecord.startDate, order: .reverse) private var routes: [RouteRecord]

    var body: some View {
        NavigationStack {
            List {
                ForEach(routes) { route in
                    NavigationLink(destination: RouteDetailView(route: route)) {
                        RouteRowView(route: route)
                    }
                    .listRowBackground(Color(red: 0.98, green: 0.97, blue: 0.94))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.87, green: 0.82, blue: 0.72))
            .navigationTitle("あしあと履歴")
            .overlay {
                if routes.isEmpty {
                    ContentUnavailableView(
                        "あしあとがありません",
                        systemImage: "map",
                        description: Text("「あしあと」タブから旅行のルートを記録できます")
                    )
                }
            }
        }
    }


}

struct RouteRowView: View {
    let route: RouteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(route.startDate, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let endDate = route.endDate {
                    Text("-")
                        .foregroundStyle(.secondary)
                    Text(endDate, style: .time)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let duration = route.duration {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(formatDuration(duration))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("·")
                    .foregroundStyle(.secondary)
                Text(formatDistance(route.totalDistance))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
