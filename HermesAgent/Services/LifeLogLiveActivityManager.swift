import ActivityKit
import Foundation

/// Keeps a persistent "today's lifelog" Live Activity on the lock screen / Dynamic Island.
@MainActor
enum LifeLogLiveActivityManager {
    private static var activity: Activity<LifeLogActivityAttributes>?
    private static var pushTokenTask: Task<Void, Never>?
    private static var startTokenTask: Task<Void, Never>?
    private static var apiClient: APIClient?

    struct Snapshot: Equatable {
        var headline: String
        var detail: String
        var statusLabel: String
    }

    static func configure(apiClient: APIClient) {
        self.apiClient = apiClient
        resumeExistingActivityIfNeeded()
    }

    /// Re-attach to a lifelog Live Activity started by push or a prior app session.
    private static func resumeExistingActivityIfNeeded() {
        guard activity == nil,
              let existing = Activity<LifeLogActivityAttributes>.activities.first else { return }
        activity = existing
        observeUpdateToken(for: existing)
    }

    static func observePushTokens() {
        guard #available(iOS 17.2, *), let apiClient else { return }
        startTokenTask?.cancel()
        startTokenTask = Task {
            for await tokenData in Activity<LifeLogActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                let hex = PushTokenHex.encode(tokenData)
                try? await apiClient.registerLifeLogLiveActivityStartToken(hex)
            }
        }
    }

    static func refreshFromLocal(macSummary: String? = nil) {
        let snapshot = buildSnapshot(macSummary: macSummary)
        guard !snapshot.headline.isEmpty || !snapshot.detail.isEmpty else { return }
        update(snapshot)
    }

    static func update(_ snapshot: Snapshot) {
        resumeExistingActivityIfNeeded()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let headline = String(snapshot.headline.prefix(80))
        let detail = String(snapshot.detail.prefix(72))
        let status = String(snapshot.statusLabel.prefix(16))
        guard !headline.isEmpty || !detail.isEmpty else { return }

        let state = LifeLogActivityAttributes.ContentState(
            headline: headline,
            detail: detail,
            statusLabel: status.isEmpty ? "今日" : status
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))

        if let activity {
            Task { await activity.update(content) }
            return
        }

        let attrs = LifeLogActivityAttributes(title: "ライフログ")
        guard let newActivity = try? Activity.request(
            attributes: attrs,
            content: content,
            pushType: .token
        ) else { return }
        activity = newActivity
        observeUpdateToken(for: newActivity)
    }

    static func buildSnapshot(macSummary: String?) -> Snapshot {
        let today = Date()
        let lifeLog = LifeLogStore.shared
        let location = LocationManager.shared
        let visits = location.visits(on: today)
        let items = lifeLog.timeline(for: today, visits: visits)
        let health = HealthManager.shared

        let headline: String = {
            if let reflection = lifeLog.eveningReflection(on: today)?.oneLiner,
               !reflection.isEmpty {
                return reflection
            }
            if let mac = macSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !mac.isEmpty {
                return String(mac.prefix(80))
            }
            let metrics = DayHealthMetrics(
                steps: health.todaySteps,
                activeEnergy: health.todayActiveEnergy,
                restingHR: health.todayRestingHR,
                sleepHours: health.todaySleepHours,
                bodyMassKg: health.todayBodyMassKg
            )
            if let line = LifeLogOneLiner.compose(items: items, metrics: metrics) {
                return line
            }
            return "今日の記録"
        }()

        var detailParts: [String] = []
        if health.todaySteps > 0 { detailParts.append("\(health.todaySteps.formatted())歩") }
        let loc = location.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loc.isEmpty {
            detailParts.append(String(loc.prefix(28)))
        } else if !items.isEmpty {
            detailParts.append("\(items.count)件")
        }
        let detail = detailParts.joined(separator: " · ")

        return Snapshot(headline: headline, detail: detail, statusLabel: "今日")
    }

    private static func observeUpdateToken(for activity: Activity<LifeLogActivityAttributes>) {
        pushTokenTask?.cancel()
        guard let apiClient else { return }
        pushTokenTask = Task {
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let hex = PushTokenHex.encode(tokenData)
                try? await apiClient.registerLifeLogLiveActivityPushToken(hex)
            }
        }
    }
}
