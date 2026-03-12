//
//  KyoNoAshiatoApp.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import SwiftData

@main
struct KyoNoAshiatoApp: App {
    @State private var locationManager = LocationManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            RouteRecord.self,
            LocationPoint.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locationManager)
                .preferredColorScheme(.light)
        }
        .modelContainer(sharedModelContainer)
    }
}
