//
//  NotificationManager.swift
//  KyoNoAshiato
//
//  Created by Hibiki Tsuboi on 2026/05/25.
//

import Foundation
import UserNotifications

/// 移動開始を検知したときに「あしあとを残しませんか」と思い出させるための通知を扱う。
/// 通知はあくまで思い出させるだけで、記録の開始はユーザーが手動で「出発」を押して行う。
final class NotificationManager {
    static let shared = NotificationManager()

    /// 同じ外出で何度も通知しないためのクールダウン。
    private let cooldown: TimeInterval = 10 * 60
    private let lastReminderKey = "lastDepartureReminderDate"

    private init() {}

    /// 通知の許可をリクエストする。すでに決定済みなら何も起きない。
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 移動開始を知らせるリマインド通知を送る。
    /// クールダウン中、または通知未許可の場合は実質的に何も表示されない。
    func sendDepartureReminder() {
        let now = Date()
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastReminderKey) as? Date,
           now.timeIntervalSince(last) < cooldown {
            return
        }
        defaults.set(now, forKey: lastReminderKey)

        let content = UNMutableNotificationContent()
        content.title = "あしあとを残しませんか？"
        content.body = "移動を始めたみたいです。アプリを開いて「出発」を押すと記録できます。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
