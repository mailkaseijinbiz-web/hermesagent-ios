import HermesShared
import Foundation

/// 今日のひとこと — タイムライン上の事実だけから組み立てる（LLM 不使用）。
/// ウィンドウタイトルやプロジェクト名は含めず、アプリ名・場所・枚数などのみ。
enum LifeLogOneLiner {
    static let minMacDuration: TimeInterval = 300

    static func compose(items: [LifeLogItem], metrics: DayHealthMetrics) -> String? {
        var parts: [String] = []

        if let mac = macPhrase(from: items) { parts.append(mac) }
        if let mobility = mobilityPhrase(from: items) { parts.append(mobility) }
        if let visits = visitPhrase(from: items) { parts.append(visits) }
        if let photos = photoPhrase(from: items) { parts.append(photos) }
        if let memos = memoPhrase(from: items) { parts.append(memos) }
        if let health = healthPhrase(metrics: metrics) { parts.append(health) }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "。") + "。"
    }

    private static func macPhrase(from items: [LifeLogItem]) -> String? {
        var usage: [String: TimeInterval] = [:]
        for item in items {
            switch item {
            case .mac(let e):
                guard e.duration >= minMacDuration else { continue }
                usage[MacWorkFocus.workTitle(for: e), default: 0] += e.duration
            case .macSummary(let s):
                for app in s.apps where app.workTitle != "その他" && app.totalDuration >= minMacDuration {
                    usage[app.workTitle, default: 0] += app.totalDuration
                }
            default:
                break
            }
        }
        let top = usage.sorted { $0.value > $1.value }.prefix(2)
        guard !top.isEmpty else { return nil }
        return top.map { "\($0.key) \(MacActivitySummarizer.formatDuration($0.value))" }.joined(separator: "、")
    }

    private static func mobilityPhrase(from items: [LifeLogItem]) -> String? {
        let segments = items.compactMap { item -> MobilityTimelineEntry? in
            if case .mobility(let m) = item { return m }
            return nil
        }
        guard !segments.isEmpty else { return nil }
        return segments.map { "\($0.label)\($0.detail.replacingOccurrences(of: " · ", with: " "))" }.joined(separator: "、")
    }

    private static func visitPhrase(from items: [LifeLogItem]) -> String? {
        let names = items.compactMap { item -> String? in
            guard case .visit(let v, _) = item else { return nil }
            let name = v.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        var seen = Set<String>()
        var unique: [String] = []
        for name in names where seen.insert(name).inserted {
            unique.append(name)
        }
        guard !unique.isEmpty else { return nil }
        if unique.count == 1 { return "\(unique[0])を訪問" }
        if unique.count == 2 { return "\(unique[0])・\(unique[1])を訪問" }
        return "\(unique[0])ほか\(unique.count)か所を訪問"
    }

    private static func photoPhrase(from items: [LifeLogItem]) -> String? {
        let count = items.reduce(into: 0) { n, item in
            if case .photo = item { n += 1 }
        }
        guard count > 0 else { return nil }
        return "写真\(count)枚"
    }

    private static func memoPhrase(from items: [LifeLogItem]) -> String? {
        let memos = items.compactMap { item -> LifeLogMemo? in
            if case .memo(let m) = item { return m }
            return nil
        }
        guard !memos.isEmpty else { return nil }
        if memos.count == 1 {
            let text = memos[0].timelineDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 4, text.count <= 40 { return text }
        }
        return "メモ\(memos.count)件"
    }

    private static func healthPhrase(metrics: DayHealthMetrics) -> String? {
        if metrics.steps >= 1000 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: metrics.steps), number: .decimal)
            return "歩数\(formatted)歩"
        }
        if metrics.sleepHours >= 0.5 {
            return String(format: "睡眠%.1f時間", metrics.sleepHours)
        }
        return nil
    }
}
