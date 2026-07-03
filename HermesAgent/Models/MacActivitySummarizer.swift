import HermesShared
import Foundation

struct MacAppUsage: Equatable {
    let workTitle: String
    let toolName: String
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

/// Mac 作業ログを作業内容単位に要約（同じウィンドウ/ページ/チャットを束ねる）。
enum MacActivitySummarizer {
    static func summarize(_ entries: [MacActivityEntry], maxApps: Int = 5) -> MacActivitySummary? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.startTime < $1.startTime }
        let merged = mergeAdjacent(sorted)
        let grouped = groupByWorkFocus(merged)
        let ranked = grouped.sorted { $0.totalDuration > $1.totalDuration }
        let top = Array(ranked.prefix(maxApps))
        let rest = Array(ranked.dropFirst(maxApps))
        var apps = top
        if !rest.isEmpty {
            let otherDur = rest.reduce(0.0) { $0 + $1.totalDuration }
            let otherCount = rest.reduce(0) { $0 + $1.sessionCount }
            let otherFirst = rest.map(\.firstTime).min() ?? sorted[0].startDate
            apps.append(MacAppUsage(
                workTitle: "その他",
                toolName: "",
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
               MacWorkFocus.focusGroupKey(for: last) == MacWorkFocus.focusGroupKey(for: e),
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

    private static func groupByWorkFocus(_ entries: [MacActivityEntry]) -> [MacAppUsage] {
        var map: [String: (workTitle: String, toolName: String, kind: String, duration: TimeInterval, count: Int, first: Date)] = [:]
        for e in entries {
            let key = MacWorkFocus.focusGroupKey(for: e)
            let work = MacWorkFocus.workTitle(for: e)
            let tool = MacWorkFocus.toolName(for: e)
            if var g = map[key] {
                g.duration += e.duration
                g.count += 1
                g.first = min(g.first, e.startDate)
                if e.kind == "hermes" { g.kind = "hermes" }
                map[key] = g
            } else {
                map[key] = (work, tool, e.kind, e.duration, 1, e.startDate)
            }
        }
        return map.map { _, g in
            MacAppUsage(
                workTitle: g.workTitle,
                toolName: g.toolName,
                kind: g.kind,
                totalDuration: g.duration,
                sessionCount: g.count,
                firstTime: g.first
            )
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
