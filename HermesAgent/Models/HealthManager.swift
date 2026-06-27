import Foundation
import HealthKit
import UIKit

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

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        func q(_ id: HKQuantityTypeIdentifier) { if let t = HKQuantityType.quantityType(forIdentifier: id) { s.insert(t) } }
        q(.stepCount); q(.distanceWalkingRunning); q(.activeEnergyBurned)
        q(.appleExerciseTime); q(.heartRate); q(.restingHeartRate); q(.bodyMass)
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
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
        } catch {
            // 失敗は静かに（次回再送）
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
