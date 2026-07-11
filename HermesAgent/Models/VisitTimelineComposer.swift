import CoreLocation
import Foundation

/// タイムライン上の移動1行（徒歩 13分 · 520m など）。
struct MobilityTimelineEntry: Equatable, Identifiable {
    var id: String
    var mode: MobilityMode
    var time: Date
    var duration: TimeInterval
    var meters: Double

    var label: String { mode.label }

    var detail: String {
        "\(MobilityTotals.formatDuration(duration)) · \(MobilityTotals.formatDistance(meters))"
    }
}

/// 生の訪問ログを「立ち止まった場所」と「移動」行に再構成する。
enum VisitTimelineComposer {
    static let microLegMaxDistance: Double = 200
    static let microLegMaxDuration: TimeInterval = 20 * 60
    static let minMobilityDuration: TimeInterval = 60
    static let minMobilityDistance: Double = 80
    static let minStopDwell: TimeInterval = 10 * 60

    private struct Leg {
        let duration: TimeInterval
        let meters: Double
        let mode: MobilityMode?
    }

    private enum Segment {
        case stop(VisitEntry, dwell: TimeInterval?)
        case movement(MobilityTimelineEntry)
    }

    static func compose(visits: [VisitEntry], now: Date = Date()) -> [LifeLogItem] {
        segments(from: visits, now: now).compactMap { segment in
            switch segment {
            case .stop(let visit, let dwell):
                return .visit(visit, duration: dwell)
            case .movement(let entry):
                return .mobility(entry)
            }
        }
    }

    static func significantStops(_ visits: [VisitEntry], now: Date = Date()) -> [VisitEntry] {
        segments(from: visits, now: now).compactMap { segment in
            if case .stop(let visit, _) = segment { return visit }
            return nil
        }
    }

    // MARK: - Segmentation

    private static func segments(from visits: [VisitEntry], now: Date) -> [Segment] {
        let sorted = visits.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        let clusters = cluster(sorted)
        var out: [Segment] = []
        for (index, cluster) in clusters.enumerated() {
            let nextFirst = index + 1 < clusters.count ? clusters[index + 1].first : nil
            out.append(contentsOf: segments(for: cluster, nextVisit: nextFirst, now: now))
        }
        return out
    }

    private static func cluster(_ visits: [VisitEntry]) -> [[VisitEntry]] {
        guard !visits.isEmpty else { return [] }
        var clusters: [[VisitEntry]] = [[visits[0]]]
        for i in 1..<visits.count {
            let leg = measure(visits[i - 1], visits[i])
            if leg.duration <= 0 { continue }
            if isContinuationLeg(leg) {
                clusters[clusters.count - 1].append(visits[i])
            } else {
                clusters.append([visits[i]])
            }
        }
        return clusters
    }

    private static func isContinuationLeg(_ leg: Leg) -> Bool {
        if leg.mode != nil { return true }
        return leg.meters < microLegMaxDistance && leg.duration < microLegMaxDuration
    }

    private static func segments(for cluster: [VisitEntry], nextVisit: VisitEntry?, now: Date) -> [Segment] {
        guard let first = cluster.first, let last = cluster.last else { return [] }

        if cluster.count >= 2 {
            let span = measure(first, last)
            if span.duration >= minMobilityDuration,
               span.meters >= minMobilityDistance,
               let mode = span.mode ?? inferredMode(span: span, visitCount: cluster.count) {
                let entry = MobilityTimelineEntry(
                    id: "mob-\(mode.rawValue)-\(Int(first.time.timeIntervalSince1970))",
                    mode: mode,
                    time: first.time,
                    duration: span.duration,
                    meters: span.meters
                )
                var out: [Segment] = []
                // 出発地: 移動クラスタの先頭に十分な滞在（次の記録まで minStopDwell 以上）が
                // あれば停留として残す（自宅→電車→オフィスで自宅が消える問題の修正）
                if cluster.count >= 2 {
                    let departGap = cluster[1].time.timeIntervalSince(first.time)
                    if departGap >= minStopDwell {
                        out.append(.stop(first, dwell: departGap))
                    }
                }
                out.append(.movement(entry))
                if shouldShowArrivalStop(last, nextVisit: nextVisit, now: now) {
                    let dwell = dwellAfter(last, nextVisit: nextVisit, now: now)
                    out.append(.stop(last, dwell: dwell))
                }
                return out
            }
        }

        let dwell = dwellAfter(last, nextVisit: nextVisit, now: now)

        if cluster.count == 1, let dwell, dwell < minStopDwell, nextVisit != nil {
            return []
        }

        if cluster.count >= 2 {
            // 移動にならなかった複数記録のクラスタ: 「同一っぽい地名」（ジオコードゆらぎ）だけ
            // 潰し、名前の変わる短い立ち寄り（自宅→コンビニ→自宅）は各停留として残す
            var stops: [Segment] = []
            var i = 0
            while i < cluster.count {
                var j = i
                while j + 1 < cluster.count, isSameishPlace(cluster[j].name, cluster[j + 1].name) { j += 1 }
                let next = j + 1 < cluster.count ? cluster[j + 1] : nextVisit
                stops.append(.stop(cluster[i], dwell: dwellAfter(cluster[i], nextVisit: next, now: now)))
                i = j + 1
            }
            return stops
        }

        return [.stop(last, dwell: dwell)]
    }

    /// ジオコードゆらぎ判定: 同名、または長い共通接頭辞（住所の丁目違い等）は同一地点とみなす。
    static func isSameishPlace(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let prefix = zip(a, b).prefix { $0 == $1 }.count
        return prefix >= 5
    }

    private static func dwellAfter(_ visit: VisitEntry, nextVisit: VisitEntry?, now: Date) -> TimeInterval? {
        let end = nextVisit?.time ?? now
        let seconds = end.timeIntervalSince(visit.time)
        return seconds > 60 ? seconds : nil
    }

    private static func shouldShowArrivalStop(_ visit: VisitEntry, nextVisit: VisitEntry?, now: Date) -> Bool {
        guard let dwell = dwellAfter(visit, nextVisit: nextVisit, now: now) else { return false }
        return dwell >= minStopDwell
    }

    private static func inferredMode(span: Leg, visitCount: Int) -> MobilityMode? {
        guard visitCount >= 2 else { return nil }
        return .walk
    }

    private static func measure(_ a: VisitEntry, _ b: VisitEntry) -> Leg {
        let duration = max(0, b.time.timeIntervalSince(a.time))
        let meters = distanceMeters(from: a, to: b)
        let mode: MobilityMode? = {
            guard duration >= minMobilityDuration, meters >= minMobilityDistance else { return nil }
            let speedKmh = (meters / 1000) / (duration / 3600)
            return MobilityAnalyzer.classify(speedKmh: speedKmh, distanceMeters: meters)
        }()
        return Leg(duration: duration, meters: meters, mode: mode)
    }

    private static func distanceMeters(from a: VisitEntry, to b: VisitEntry) -> Double {
        guard a.lat != 0 || a.lon != 0, b.lat != 0 || b.lon != 0 else { return 0 }
        return CLLocation(latitude: a.lat, longitude: a.lon)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
    }
}
