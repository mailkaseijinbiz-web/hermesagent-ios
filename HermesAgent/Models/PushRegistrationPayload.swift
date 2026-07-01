import Foundation

/// JSON bodies for push token registration with the Mac hub (unit-testable).
enum PushRegistrationPayload {
    static func liveActivityStartToken(_ hex: String) -> [String: String] {
        ["token": hex]
    }
}
