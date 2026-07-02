import CoreLocation
import Foundation

enum MobilityMode: String, CaseIterable, Equatable {
    case walk
    case bike
    case train

    var label: String {
        switch self {
        case .walk: return "徒歩"
        case .bike: return "自転車"
        case .train: return "電車"
        }
    }
}

struct MobilityTotals: Equatable {
    var walkSeconds: TimeInterval = 0
    var walkMeters: Double = 0
    var bikeSeconds: TimeInterval = 0
    var bikeMeters: Double = 0
    var trainSeconds: TimeInterval = 0
    var trainMeters: Double = 0

    var isEmpty: Bool {
        walkSeconds + bikeSeconds + trainSeconds == 0
    }

    func summaryLine() -> String? {
        var parts: [String] = []
        if walkSeconds >= 60 {
            parts.append("徒歩 \(Self.formatDuration(walkSeconds)) · \(Self.formatDistance(walkMeters))")
        }
        if bikeSeconds >= 60 {
            parts.append("自転車 \(Self.formatDuration(bikeSeconds)) · \(Self.formatDistance(bikeMeters))")
        }
        if trainSeconds >= 60 {
            parts.append("電車 \(Self.formatDuration(trainSeconds)) · \(Self.formatDistance(trainMeters))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins)分" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded()))m" }
        return String(format: "%.1fkm", meters / 1000)
    }
}

/// Estimate walk / bike / train time and distance from GPS visit coordinates.
enum MobilityAnalyzer {
    /// Ignore gaps longer than this between visits (not one continuous leg).
    static let defaultMaxGap: TimeInterval = 3 * 3600

    static func analyze(visits: [VisitEntry], maxGap: TimeInterval = defaultMaxGap) -> MobilityTotals {
        let sorted = visits
            .filter { $0.lat != 0 || $0.lon != 0 }
            .sorted { $0.time < $1.time }
        guard sorted.count >= 2 else { return MobilityTotals() }

        var totals = MobilityTotals()
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            let duration = b.time.timeIntervalSince(a.time)
            guard duration >= 60, duration <= maxGap else { continue }

            let dist = CLLocation(latitude: a.lat, longitude: a.lon)
                .distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
            guard dist >= 80 else { continue }

            let speedKmh = (dist / 1000) / (duration / 3600)
            guard let mode = classify(speedKmh: speedKmh, distanceMeters: dist) else { continue }

            switch mode {
            case .walk:
                totals.walkSeconds += duration
                totals.walkMeters += dist
            case .bike:
                totals.bikeSeconds += duration
                totals.bikeMeters += dist
            case .train:
                totals.trainSeconds += duration
                totals.trainMeters += dist
            }
        }
        return totals
    }

    static func classify(speedKmh: Double, distanceMeters: Double) -> MobilityMode? {
        guard distanceMeters >= 80 else { return nil }
        if speedKmh < 2 { return nil }
        if speedKmh < 9 { return .walk }
        if speedKmh < 28 { return .bike }
        return .train
    }
}
