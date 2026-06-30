import Foundation

/// Stock price snapshot shared from the iOS app to the Home Screen widget via App Group.
struct StockSnapshot: Codable, Identifiable, Hashable {
    let ticker: String
    let label: String
    let price: String
    let change: String
    let changePercent: String
    let isPositive: Bool
    var id: String { ticker }
}

/// A compact, codable view of an AI employee shared from the app to the widget
/// extension via the App Group. Mirrors the fields the Mac hub serves in
/// `/api/employees` (see `MobileEmployee`), minus anything the widget can't use.
struct EmployeeSnapshot: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let roleTitle: String
    let accent: String   // hex string, e.g. "7F77DD"
    let model: String
}

/// A compact, codable view of a developed app (AppProject) shared to the widget so
/// the Home Screen "アプリ" widget can list them and deep-link each one open
/// (`hermesagent://app/<id>`). `hasURL` lets the widget dim apps with no previewURL.
struct AppSnapshot: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let status: String          // "idea" | "building" | "done"
    let assigneeEmoji: String
    let hasURL: Bool
}

/// Lightweight shared store backed by an App Group, used to pass a small
/// snapshot (connection status, recent session titles, the AI-employee roster +
/// active selection, and the developed-apps list) from the app to the Home Screen widgets.
enum SharedStore {
    static let appGroup = "group.com.custom.hermesagent"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    private enum Keys {
        static let connected = "connected"
        static let sessionTitles = "recentSessionTitles"
        static let employees = "employeesSnapshot"          // JSON-encoded [EmployeeSnapshot]
        static let apps = "appsSnapshot"                    // JSON-encoded [AppSnapshot]
        static let stocks = "stocksSnapshot"                // JSON-encoded [StockSnapshot]
        static let activeEmployeeId = "activeEmployeeId"
        static let updatedAt = "updatedAt"
    }

    /// A point-in-time snapshot the widget renders from.
    struct Snapshot: Equatable {
        var connected: Bool = false
        var titles: [String] = []
        var employees: [EmployeeSnapshot] = []
        var apps: [AppSnapshot] = []
        var stocks: [StockSnapshot] = []
        var activeEmployeeId: String? = nil

        /// The currently-active employee (the one the app is talking to), if any.
        var activeEmployee: EmployeeSnapshot? {
            guard let id = activeEmployeeId else { return nil }
            return employees.first { $0.id == id }
        }
    }

    static func save(connected: Bool,
                     sessionTitles: [String],
                     employees: [EmployeeSnapshot],
                     apps: [AppSnapshot],
                     activeEmployeeId: String?) {
        guard let d = defaults else { return }
        d.set(connected, forKey: Keys.connected)
        d.set(Array(sessionTitles.prefix(8)), forKey: Keys.sessionTitles)
        if let data = try? JSONEncoder().encode(employees) {
            d.set(data, forKey: Keys.employees)
        }
        if let data = try? JSONEncoder().encode(apps) {
            d.set(data, forKey: Keys.apps)
        }
        if let activeEmployeeId = activeEmployeeId {
            d.set(activeEmployeeId, forKey: Keys.activeEmployeeId)
        } else {
            d.removeObject(forKey: Keys.activeEmployeeId)
        }
        d.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
    }

    static func saveStocks(_ stocks: [StockSnapshot]) {
        guard let d = defaults,
              let data = try? JSONEncoder().encode(stocks) else { return }
        d.set(data, forKey: Keys.stocks)
    }

    static func snapshot() -> Snapshot {
        guard let d = defaults else { return Snapshot() }
        var snap = Snapshot()
        snap.connected = d.bool(forKey: Keys.connected)
        snap.titles = d.stringArray(forKey: Keys.sessionTitles) ?? []
        if let data = d.data(forKey: Keys.employees),
           let emps = try? JSONDecoder().decode([EmployeeSnapshot].self, from: data) {
            snap.employees = emps
        }
        if let data = d.data(forKey: Keys.apps),
           let apps = try? JSONDecoder().decode([AppSnapshot].self, from: data) {
            snap.apps = apps
        }
        if let data = d.data(forKey: Keys.stocks),
           let stocks = try? JSONDecoder().decode([StockSnapshot].self, from: data) {
            snap.stocks = stocks
        }
        snap.activeEmployeeId = d.string(forKey: Keys.activeEmployeeId)
        return snap
    }
}
