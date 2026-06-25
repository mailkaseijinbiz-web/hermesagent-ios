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
    /// Called when the user taps a notification — carries the originating sessionId.
    var openSessionHandler: ((String) -> Void)?

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
        [.banner, .sound]
    }

    // User tapped a notification → jump to the originating session (APNs payload
    // carries `sessionId` at the top level, set by the Mac APNsSender).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let sid = info["sessionId"] as? String, !sid.isEmpty {
            openSessionHandler?(sid)
        }
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
