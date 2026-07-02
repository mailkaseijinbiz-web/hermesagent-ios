import Foundation
import UserNotifications

/// 8:00 ローカル通知 — 昨夜確定した「今日のひとこと」を見返す（v2）。
enum MorningReflectionScheduler {
    static let notificationId = "hermes.morning-reflect"
    private static let hour = 8
    private static let minute = 0

    static func reschedule(lastNightOneLiner: String?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        guard let line = lastNightOneLiner?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return }

        var date = DateComponents()
        date.hour = hour
        date.minute = minute

        let preview = line.count > 36 ? String(line.prefix(36)) + "…" : line
        let content = UNMutableNotificationContent()
        content.title = "昨夜のひとこと"
        content.body = preview
        content.sound = .default
        content.userInfo = ["action": "morning_reflect"]

        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        center.add(request)
    }
}
