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
        if let sid = info["sessionId"] as? String, !sid.isEmpty {
            openSessionHandler?(sid, Self.isProactivePayload(info))
        }
    }

    nonisolated private static func isProactivePayload(_ info: [AnyHashable: Any]) -> Bool {
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
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushManager.shared.setDeviceToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] APNs registration failed: \(error)")
    }
}
