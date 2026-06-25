import Foundation

/// Lightweight shared store backed by an App Group, used to pass a small
/// snapshot (connection status + recent session titles) from the app to the
/// Home Screen widget.
enum SharedStore {
    static let appGroup = "group.com.custom.hermesagent"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    private enum Keys {
        static let connected = "connected"
        static let sessionTitles = "recentSessionTitles"
        static let updatedAt = "updatedAt"
    }

    static func save(connected: Bool, sessionTitles: [String]) {
        guard let d = defaults else { return }
        d.set(connected, forKey: Keys.connected)
        d.set(Array(sessionTitles.prefix(8)), forKey: Keys.sessionTitles)
        d.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
    }

    static func snapshot() -> (connected: Bool, titles: [String]) {
        guard let d = defaults else { return (false, []) }
        return (d.bool(forKey: Keys.connected), d.stringArray(forKey: Keys.sessionTitles) ?? [])
    }
}
