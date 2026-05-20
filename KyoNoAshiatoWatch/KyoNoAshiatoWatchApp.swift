//
//  KyoNoAshiatoWatchApp.swift
//  KyoNoAshiatoWatch
//
//  Created by Hibiki Tsuboi on 2026/05/20.
//

import SwiftUI

@main
struct KyoNoAshiatoWatch_Watch_AppApp: App {
    @State private var connectivity = WatchConnectivityManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectivity)
                .onAppear {
                    connectivity.activate()
                }
        }
    }
}
