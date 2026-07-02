import Foundation
import UserNotifications

/// 21:00 ローカル通知 — 今日の振り返り v0
enum EveningReflectionScheduler {
    static let notificationId = "hermes.evening-reflect"
    private static let hour = 21
    private static let minute = 0

    static func reschedule(completedToday: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        guard !completedToday else { return }

        var date = DateComponents()
        date.hour = hour
        date.minute = minute

        let content = UNMutableNotificationContent()
        content.title = "今日を振り返りませんか？"
        content.body = "今日のページを閉じる前に、いちばん残したい記録を選びましょう。"
        content.sound = .default
        content.userInfo = ["action": "evening_reflect"]

        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        center.add(request)
    }

    static func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private static var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
}
