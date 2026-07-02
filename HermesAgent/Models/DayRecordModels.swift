import Foundation

// MARK: - Macハブの正準ライフログ（/api/lifelog/day の DayRecord）
// ハブ側は JSONEncoder デフォルトキーでエンコードする。tags/imageFile/url などは
// JSON に存在しないことがあるため decodeIfPresent で寛容にデコードする。

/// 1日のライフログイベント（睡眠/訪問/Mac/写真/メモ/振り返り）。
struct LifeEvent: Codable, Identifiable, Equatable {
    var id: String
    var kind: String  // sleep|visit|mac|photo|memo|reflection
    var start: Double  // epoch sec
    var end: Double?
    var title: String
    var detail: String?
    var place: String?
    var tags: [String]
    var imageFile: String?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, start, end, title, detail, place, tags, imageFile, url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        place = try c.decodeIfPresent(String.self, forKey: .place)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }
}

/// 24時間バーの1帯（在宅/外出/睡眠/Mac作業）。
struct TimeBand: Codable, Equatable {
    var kind: String  // sleep|home|out|mac
    var start: Double  // epoch sec
    var end: Double
}

/// 1日のヘルスメトリクス。ハブに無い値は nil。
struct DayMetrics: Codable, Equatable {
    var steps: Int?
    var sleepHours: Double?
    var moodScore: Int?
    var restingHeartRate: Int?
    var exerciseMinutes: Int?
    var distanceKm: Double?
    var activeEnergyKcal: Double?

    /// 1つでも値があるか（メトリクス帯の表示判定用）。
    var hasAnyValue: Bool {
        steps != nil || sleepHours != nil || moodScore != nil
            || restingHeartRate != nil || exerciseMinutes != nil
    }
}

/// Macハブが集約した1日の正準記録。
struct DayRecord: Codable, Equatable {
    var dateKey: String
    var events: [LifeEvent]
    var bands: [TimeBand]
    var metrics: DayMetrics
    var anomalies: [String]
    var summary: String?
    var generatedAt: Double

    enum CodingKeys: String, CodingKey {
        case dateKey, events, bands, metrics, anomalies, summary, generatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateKey = try c.decode(String.self, forKey: .dateKey)
        events = try c.decodeIfPresent([LifeEvent].self, forKey: .events) ?? []
        bands = try c.decodeIfPresent([TimeBand].self, forKey: .bands) ?? []
        metrics = try c.decodeIfPresent(DayMetrics.self, forKey: .metrics) ?? DayMetrics()
        anomalies = try c.decodeIfPresent([String].self, forKey: .anomalies) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        generatedAt = try c.decodeIfPresent(Double.self, forKey: .generatedAt) ?? 0
    }
}

/// /api/lifelog/range の1日分（古い順、今日を含む）。週ヒートマップ用。
struct LifelogRangeDay: Codable, Equatable, Identifiable {
    var dateKey: String
    var macHours: Double
    var visits: Int
    var events: Int
    var steps: Int?
    var sleepHours: Double?
    var moodScore: Int?

    var id: String { dateKey }

    enum CodingKeys: String, CodingKey {
        case dateKey, macHours, visits, events, steps, sleepHours, moodScore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateKey = try c.decode(String.self, forKey: .dateKey)
        macHours = try c.decodeIfPresent(Double.self, forKey: .macHours) ?? 0
        visits = try c.decodeIfPresent(Int.self, forKey: .visits) ?? 0
        events = try c.decodeIfPresent(Int.self, forKey: .events) ?? 0
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        sleepHours = try c.decodeIfPresent(Double.self, forKey: .sleepHours)
        moodScore = try c.decodeIfPresent(Int.self, forKey: .moodScore)
    }
}
