//
//  KyoNoAshiatoApp.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/03/12.
//

import SwiftUI
import SwiftData
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LocationManager.shared.setup(modelContext: AppModelContainer.shared.mainContext)
        // 出発リマインドをCarPlayにも出すためのカテゴリ登録。ジオフェンスでの
        // バックグラウンド起動でも通知は飛ぶので、画面の表示を待たずにここで入れる。
        NotificationManager.shared.registerCategories()
        // 動画閲覧用に temp に書き出した中間ファイルを掃除する。再生時に必要なら再生成される。
        cleanupTemporaryMediaFiles()
        return true
    }

    /// `RouteDetailView.videoTempURL(for:)` が temp に書き出す `ashiato_<uuid>.mp4` を一掃する。
    /// SwiftData 側の delete では消えないため、起動ごとに前回分をまとめて落としておく。
    private func cleanupTemporaryMediaFiles() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        for url in entries
        where url.lastPathComponent.hasPrefix("ashiato_") && url.pathExtension == "mp4" {
            try? fm.removeItem(at: url)
        }
    }
}

@main
struct KyoNoAshiatoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var locationManager = LocationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private let sharedModelContainer = AppModelContainer.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locationManager)
                .preferredColorScheme(.light)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                locationManager.recoverIncompleteRoutes()
            }
        }
    }
}
