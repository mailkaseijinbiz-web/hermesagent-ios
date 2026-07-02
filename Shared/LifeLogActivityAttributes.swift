import ActivityKit
import Foundation

/// Lock screen / Dynamic Island Live Activity for today's lifelog glance.
struct LifeLogActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var headline: String
        var detail: String
        var statusLabel: String
    }

    /// Fixed label shown in the widget chrome (e.g. "ライフログ").
    var title: String
}
