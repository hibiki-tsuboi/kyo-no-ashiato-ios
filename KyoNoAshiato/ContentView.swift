//
//  ContentView.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("出発", systemImage: "record.circle") {
                RecordingView()
            }
            Tab("あしあと", systemImage: "clock") {
                HistoryListView()
            }
        }
    }
}
