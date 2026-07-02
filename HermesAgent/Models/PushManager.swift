import UIKit
import UserNotifications

/// Handles iOS push-notification plumbing: permission, APNs device token capture,
/// and foreground presentation. The token is handed to AppState, which registers
/// it with the Mac (the push provider).
@MainActor
final class PushManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushManager()

    private(set) var deviceToken: String?
    /// Called when a device token becomes available, so AppState can register it.
    var registerHandler: (() -> Void)?
    /// Called when the user taps a notification — carries the originating sessionId
    /// and whether this was a proactive employee check-in.
    var openSessionHandler: ((String, Bool) -> Void)?
    /// Foreground proactive check-in — sessionId, notification title, body preview.
    var proactiveForegroundHandler: ((String, String, String) -> Void)?
    /// Background proactive check-in — notification title, body preview (best-effort Live Activity).
    var proactiveBackgroundHandler: ((String, String) -> Void)?
    /// Local 21:00 evening reflection notification tap.
    var eveningReflectHandler: (() -> Void)?
    /// Local 8:00 morning one-liner glance notification tap.
    var morningReflectHandler: (() -> Void)?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        #if targetEnvironment(simulator)
        return   // simulators can't obtain real APNs device tokens; skip the prompt
        #else
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
        #endif
    }

    func setDeviceToken(_ hex: String) {
        deviceToken = hex
        registerHandler?()
    }

    // Show the banner even in the foreground (the user may be on another tab).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if Self.isProactivePayload(info),
           let sid = info["sessionId"] as? String, !sid.isEmpty {
            let title = notification.request.content.title
            let body = notification.request.content.body
            await MainActor.run {
                proactiveForegroundHandler?(sid, title, body)
            }
        }
        return [.banner, .sound]
    }

    // User tapped a notification → jump to the originating session (APNs payload
    // carries `sessionId` at the top level, set by the Mac APNsSender).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let action = info["action"] as? String, action == "evening_reflect" {
            eveningReflectHandler?()
            return
        }
        if let action = info["action"] as? String, action == "morning_reflect" {
            morningReflectHandler?()
            return
        }
        if let sid = info["sessionId"] as? String, !sid.isEmpty {
            openSessionHandler?(sid, Self.isProactivePayload(info))
        }
    }

    nonisolated static func isProactivePayload(_ info: [AnyHashable: Any]) -> Bool {
        if let b = info["proactive"] as? Bool { return b }
        if let n = info["proactive"] as? Int { return n != 0 }
        if let s = info["proactive"] as? String { return s == "true" || s == "1" }
        return false
    }
}

/// UIKit app delegate (bridged into the SwiftUI App) — needed to receive the
/// APNs device token callback.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = PushTokenHex.encode(deviceToken)
        Task { @MainActor in PushManager.shared.setDeviceToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] APNs registration failed: \(error)")
    }

    /// Best-effort Live Activity for proactive check-ins when the app is backgrounded.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard application.applicationState != .active,
              PushManager.isProactivePayload(userInfo) else {
            completionHandler(.noData)
            return
        }
        let title = (userInfo["title"] as? String)
            ?? (userInfo["aps"] as? [String: Any]).flatMap { ($0["alert"] as? [String: Any])?["title"] as? String }
            ?? "Hermes"
        let body = (userInfo["body"] as? String)
            ?? (userInfo["aps"] as? [String: Any]).flatMap { ($0["alert"] as? [String: Any])?["body"] as? String }
            ?? ""
        Task { @MainActor in
            PushManager.shared.proactiveBackgroundHandler?(title, body)
            completionHandler(.newData)
        }
    }
}
