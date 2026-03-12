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
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                ForEach(routes) { route in
                    NavigationLink(destination: RouteDetailView(route: route)) {
                        RouteRowView(route: route)
                    }
                }
                .onDelete(perform: deleteRoutes)
            }
            .navigationTitle("履歴")
            .toolbar {
                EditButton()
            }
            .overlay {
                if routes.isEmpty {
                    ContentUnavailableView(
                        "記録がありません",
                        systemImage: "map",
                        description: Text("「記録」タブから旅行のルートを記録できます")
                    )
                }
            }
        }
    }

    private func deleteRoutes(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(routes[index])
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
            }
        }
        .padding(.vertical, 4)
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
