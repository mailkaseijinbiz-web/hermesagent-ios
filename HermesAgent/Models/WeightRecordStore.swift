import Foundation

struct WeightRecord: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kg: Double
    var recordedAt: Double
    var memoId: String?
    var source: String = "memo"
}

@MainActor
final class WeightRecordStore: ObservableObject {
    static let shared = WeightRecordStore()

    @Published private(set) var records: [WeightRecord] = []

    private let key = "weightRecords"
    private let maxRecords = 365

    private init() { load() }

    func latest() -> WeightRecord? {
        records.sorted { $0.recordedAt < $1.recordedAt }.last
    }

    @discardableResult
    func hasRecord(memoId: String) -> Bool {
        records.contains { $0.memoId == memoId }
    }

    func append(kg: Double, at date: Date = Date(), memoId: String? = nil, source: String = "memo") -> WeightRecord? {
        guard let normalized = normalize(kg) else { return nil }
        if let memoId, records.contains(where: { $0.memoId == memoId }) { return nil }
        let record = WeightRecord(kg: normalized, recordedAt: date.timeIntervalSince1970, memoId: memoId, source: source)
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        save()
        return record
    }

    private func normalize(_ kg: Double) -> Double? {
        guard kg >= 20, kg <= 300 else { return nil }
        return (kg * 10).rounded() / 10
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WeightRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
