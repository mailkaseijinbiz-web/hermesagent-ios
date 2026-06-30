import Foundation
import HealthKit
import UIKit

/// 1日分の歩数（ダッシュボードの推移グラフ用）。
struct HealthDay: Identifiable, Equatable {
    let date: Date
    let steps: Int
    var id: Date { date }
}

/// Reads health metrics from HealthKit (steps, distance, energy, exercise, heart rate, sleep,
/// body mass) and pushes a snapshot to the Mac hub's POST /api/health. The hub surfaces it to
/// the 健康アドバイザー employee. Read-only HealthKit access (we never write).
@MainActor
final class HealthManager: ObservableObject {
    static let shared = HealthManager()

    private let store = HKHealthStore()
    @Published var authorized = false
    @Published var lastSync: Date?
    @Published var lastSummary: String?

    // 推移（ダッシュボード表示用）。端末ローカルの HealthKit から読み取る。
    @Published var weekSteps: [HealthDay] = []
    @Published var todaySteps = 0
    @Published var todayActiveEnergy = 0
    @Published var todayRestingHR = 0
    @Published var todaySleepHours: Double = 0
    @Published var todayMindfulMinutes: Int = 0

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        func q(_ id: HKQuantityTypeIdentifier) { if let t = HKQuantityType.quantityType(forIdentifier: id) { s.insert(t) } }
        q(.stepCount); q(.distanceWalkingRunning); q(.activeEnergyBurned)
        q(.appleExerciseTime); q(.heartRate); q(.restingHeartRate); q(.bodyMass)
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        if let mindful = HKObjectType.categoryType(forIdentifier: .mindfulSession) { s.insert(mindful) }
        return s
    }

    /// HealthKit の読み取り許可をリクエスト（初回のみシステムダイアログが出る）。
    func requestAuthorization() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            authorized = true
        } catch {
            authorized = false
        }
    }

    /// 許可 → 取得 → ハブへ送信。アプリ前面化時などに呼ぶ。
    func syncNow(via apiClient: APIClient) async {
        guard isAvailable else { return }
        await requestAuthorization()
        let snap = await readSnapshot()
        // date/source 以外に1つでも実データがあれば送る
        let metricKeys = ["steps", "distanceKm", "activeEnergyKcal", "exerciseMinutes",
                          "heartRate", "restingHeartRate", "sleepHours", "bodyMassKg"]
        guard metricKeys.contains(where: { snap[$0] != nil }) else { return }
        do {
            try await apiClient.pushHealth(snap)
            lastSync = Date()
            lastSummary = Self.summarize(snap)
        } catch {
            // 失敗は静かに（次回再送）
        }
    }

    /// 送信したスナップショットの簡易サマリー（設定画面表示用）。
    static func summarize(_ s: [String: Any]) -> String {
        var p: [String] = []
        if let v = s["steps"] as? Int { p.append("歩数 \(v)") }
        if let v = s["distanceKm"] as? Double { p.append(String(format: "距離 %.1fkm", v)) }
        if let v = s["activeEnergyKcal"] as? Double { p.append("\(Int(v))kcal") }
        if let v = s["heartRate"] as? Int { p.append("心拍 \(v)") }
        if let v = s["restingHeartRate"] as? Int { p.append("安静 \(v)") }
        if let v = s["sleepHours"] as? Double { p.append(String(format: "睡眠 %.1fh", v)) }
        if let v = s["bodyMassKg"] as? Double { p.append(String(format: "体重 %.1fkg", v)) }
        return p.isEmpty ? "データなし" : p.joined(separator: " / ")
    }

    // MARK: - 推移（ダッシュボード）

    /// ダッシュボード用に、7日間の歩数推移＋今日のハイライト（歩数/消費/安静時心拍/睡眠）を読み込む。
    func loadTrends() async {
        guard isAvailable else { return }
        await requestAuthorization()
        let week = await dailySteps(days: 7)
        let snap = await readSnapshot()
        weekSteps = week
        todaySteps = (snap["steps"] as? Int) ?? (week.last?.steps ?? 0)
        todayActiveEnergy = Int((snap["activeEnergyKcal"] as? Double) ?? 0)
        todayRestingHR = (snap["restingHeartRate"] as? Int) ?? (snap["heartRate"] as? Int) ?? 0
        todaySleepHours = (snap["sleepHours"] as? Double) ?? 0
        todayMindfulMinutes = await mindfulMinutesToday()
    }

    private func mindfulMinutesToday() async -> Int {
        guard let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { return 0 }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let secs = (samples as? [HKCategorySample])?.reduce(0.0) {
                    $0 + $1.endDate.timeIntervalSince($1.startDate)
                } ?? 0
                cont.resume(returning: Int(secs / 60))
            }
            self.store.execute(query)
        }
    }

    /// 直近 `days` 日の日別歩数（古い→新しい順）。
    private func dailySteps(days: Int = 7) async -> [HealthDay] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return [] }
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: endDay),
              let end = cal.date(byAdding: .day, value: 1, to: endDay) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        var interval = DateComponents(); interval.day = 1
        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: .cumulativeSum, anchorDate: start,
                                                intervalComponents: interval)
            q.initialResultsHandler = { _, results, _ in
                var out: [HealthDay] = []
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let steps = Int(stat.sumQuantity()?.doubleValue(for: .count()) ?? 0)
                    out.append(HealthDay(date: stat.startDate, steps: steps))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// 今日(累積系)＋直近(心拍/睡眠/体重)の健康スナップショットを /api/health 形式の dict で返す。
    func readSnapshot() async -> [String: Any] {
        guard isAvailable else { return [:] }
        var out: [String: Any] = [:]
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let today = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        if let v = await sum(.stepCount, .count(), today) { out["steps"] = Int(v) }
        if let v = await sum(.distanceWalkingRunning, .meterUnit(with: .kilo), today) { out["distanceKm"] = (v * 10).rounded() / 10 }
        if let v = await sum(.activeEnergyBurned, .kilocalorie(), today) { out["activeEnergyKcal"] = v.rounded() }
        if let v = await sum(.appleExerciseTime, .minute(), today) { out["exerciseMinutes"] = Int(v) }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let v = await latest(.heartRate, bpm) { out["heartRate"] = Int(v) }
        if let v = await latest(.restingHeartRate, bpm) { out["restingHeartRate"] = Int(v) }
        if let v = await latest(.bodyMass, .gramUnit(with: .kilo)) { out["bodyMassKg"] = (v * 10).rounded() / 10 }
        if let v = await sleepHoursRecent() { out["sleepHours"] = (v * 10).rounded() / 10 }

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        out["date"] = df.string(from: Date())
        out["source"] = UIDevice.current.name
        return out
    }

    // MARK: - HealthKit queries (async wrappers)

    private func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ predicate: NSPredicate) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func latest(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await withCheckedContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func sleepHoursRecent() async -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let end = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -18, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else { cont.resume(returning: nil); return }
                let asleep: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue
                ]
                let secs = samples.filter { asleep.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                cont.resume(returning: secs > 0 ? secs / 3600.0 : nil)
            }
            store.execute(query)
        }
    }
}
