import Foundation

struct MacAppUsage: Equatable {
    let appName: String
    let kind: String
    let totalDuration: TimeInterval
    let sessionCount: Int
    let firstTime: Date
}

struct MacActivitySummary: Equatable {
    let apps: [MacAppUsage]
    let totalDuration: TimeInterval
    let rawEntryCount: Int
    let anchorTime: Date

    var hasHermes: Bool { apps.contains { $0.kind == "hermes" } }
}

/// Mac 作業ログをアプリ単位に要約（Mac `DayTimelineGraph.compactForDisplay` と同趣旨）。
enum MacActivitySummarizer {
    static func summarize(_ entries: [MacActivityEntry], maxApps: Int = 5) -> MacActivitySummary? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.startTime < $1.startTime }
        let merged = mergeAdjacent(sorted)
        let grouped = groupByApp(merged)
        let ranked = grouped.sorted { $0.totalDuration > $1.totalDuration }
        let top = Array(ranked.prefix(maxApps))
        let rest = Array(ranked.dropFirst(maxApps))
        var apps = top
        if !rest.isEmpty {
            let otherDur = rest.reduce(0.0) { $0 + $1.totalDuration }
            let otherCount = rest.reduce(0) { $0 + $1.sessionCount }
            let otherFirst = rest.map(\.firstTime).min() ?? sorted[0].startDate
            apps.append(MacAppUsage(
                appName: "その他",
                kind: "mac",
                totalDuration: otherDur,
                sessionCount: otherCount,
                firstTime: otherFirst
            ))
        }
        let total = sorted.reduce(0.0) { $0 + $1.duration }
        return MacActivitySummary(
            apps: apps,
            totalDuration: total,
            rawEntryCount: entries.count,
            anchorTime: sorted[0].startDate
        )
    }

    private static func mergeAdjacent(_ entries: [MacActivityEntry], maxGap: TimeInterval = 1800) -> [MacActivityEntry] {
        var result: [MacActivityEntry] = []
        for e in entries {
            if var last = result.last,
               last.appName == e.appName,
               e.startTime - last.endTime <= maxGap {
                last.endTime = max(last.endTime, e.endTime)
                if e.kind == "hermes" { last.kind = "hermes" }
                result[result.count - 1] = last
            } else {
                result.append(e)
            }
        }
        return result
    }

    private static func groupByApp(_ entries: [MacActivityEntry]) -> [MacAppUsage] {
        var map: [String: (kind: String, duration: TimeInterval, count: Int, first: Date)] = [:]
        for e in entries {
            if var g = map[e.appName] {
                g.duration += e.duration
                g.count += 1
                g.first = min(g.first, e.startDate)
                if e.kind == "hermes" { g.kind = "hermes" }
                map[e.appName] = g
            } else {
                map[e.appName] = (e.kind, e.duration, 1, e.startDate)
            }
        }
        return map.map { name, g in
            MacAppUsage(appName: name, kind: g.kind, totalDuration: g.duration,
                        sessionCount: g.count, firstTime: g.first)
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "1分未満" }
        if m < 60 { return "\(m)分" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)時間" : "\(h)時間\(rem)分"
    }
}
