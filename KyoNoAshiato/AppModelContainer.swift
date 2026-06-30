//
//  AppModelContainer.swift
//  KyoNoAshiato
//
//  Created by Codex on 2026/06/29.
//

import SwiftData

enum AppModelContainer {
    static let shared: ModelContainer = {
        let schema = Schema([
            RouteRecord.self,
            LocationPoint.self,
            RoutePhoto.self,
            RouteMedia.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}
