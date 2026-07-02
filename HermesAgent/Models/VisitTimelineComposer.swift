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
                var out: [Segment] = [.movement(entry)]
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

        return [.stop(last, dwell: dwell)]
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
