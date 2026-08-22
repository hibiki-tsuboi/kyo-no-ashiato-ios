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
/// CarPlay接続中はこの通知が車の画面にも出る（運転中に押すべきボタンの案内なので、
/// 「運転中に必要な操作」としてCarPlayの通知ガイドラインに沿う用途）。
final class NotificationManager {
    static let shared = NotificationManager()

    /// CarPlay表示を許可するカテゴリの識別子。通知側にも同じ識別子を付ける必要がある。
    private static let departureCategoryIdentifier = "departureReminder"

    /// 同じ外出で何度も通知しないためのクールダウン。
    private let cooldown: TimeInterval = 10 * 60
    private let lastReminderKey = "lastDepartureReminderDate"

    private init() {}

    /// 通知の許可をリクエストする。すでに決定済みなら何も起きない。
    /// CarPlayに出すには許可のオプションに `.carPlay` を含める必要がある。
    /// 車の画面に出さない設定にされていても、iPhone側の通知はそのまま出る。
    func requestAuthorization() {
        registerCategories()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .carPlay]) { _, _ in }
    }

    /// CarPlay表示を許可するカテゴリを登録する。許可の状態に関係なく入れておく。
    /// ジオフェンスでバックグラウンド起動された回では画面が出ないので、起動時にも呼ぶ。
    func registerCategories() {
        let departure = UNNotificationCategory(
            identifier: Self.departureCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.allowInCarPlay]
        )
        UNUserNotificationCenter.current().setNotificationCategories([departure])
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
        // CarPlayにも出るので、iPhoneを操作させる言い回しは避ける（CarPlayのガイドライン）。
        content.body = "移動を始めたみたいです。「出発」を押すと記録を始められます。"
        content.sound = .default
        content.categoryIdentifier = Self.departureCategoryIdentifier

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
