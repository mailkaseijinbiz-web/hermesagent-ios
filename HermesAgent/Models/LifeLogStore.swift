import Foundation
import Combine

/// ライフログのメモエントリ（ユーザーが追記するテキスト）。
struct LifeLogMemo: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var time: Date
    var editedAt: Date? = nil
}

/// Mac からフェッチしたアプリ/Hermes セッション。
struct MacActivityEntry: Codable, Identifiable {
    var id: String
    var kind: String         // "app" | "hermes"
    var appName: String
    var bundleId: String?    // Optionalでバックコンパット
    var label: String
    var windowTitle: String? // ウィンドウタイトル（Optionalでバックコンパット）
    var startTime: Double    // epoch seconds
    var endTime: Double
    var duration: Double { endTime - startTime }
    var startDate: Date { Date(timeIntervalSince1970: startTime) }
}

/// タイムラインに並ぶ1アイテム（場所訪問 / メモ / Mac アクティビティ）。
enum LifeLogItem: Identifiable {
    case visit(VisitEntry, duration: TimeInterval?)   // duration = 次の記録まで滞在時間
    case memo(LifeLogMemo)
    case mac(MacActivityEntry)

    var id: String {
        switch self {
        case .visit(let v, _): return "v-\(v.id)"
        case .memo(let m):     return "m-\(m.id)"
        case .mac(let a):      return "a-\(a.id)"
        }
    }

    var time: Date {
        switch self {
        case .visit(let v, _): return v.time
        case .memo(let m):     return m.time
        case .mac(let a):      return a.startDate
        }
    }
}

/// 今日のメモを管理するストア。LocationManager の訪問記録とマージしてタイムラインを作る。
@MainActor
final class LifeLogStore: ObservableObject {
    static let shared = LifeLogStore()

    @Published var todayMemos: [LifeLogMemo] = []
    @Published var macActivities: [MacActivityEntry] = []

    private let memosKey = "lifeLogMemos"
    private let memosDateKey = "lifeLogMemosDate"

    init() { loadToday() }

    // MARK: - タイムライン生成

    /// 訪問記録・メモ・Mac アクティビティを時系列にマージして返す。
    func timeline(visits: [VisitEntry]) -> [LifeLogItem] {
        let visitItems: [LifeLogItem] = visits.enumerated().map { idx, v in
            let nextTime = idx + 1 < visits.count ? visits[idx + 1].time : nil
            let dur = nextTime.map { $0.timeIntervalSince(v.time) }
            return .visit(v, duration: dur)
        }
        let memoItems:  [LifeLogItem] = todayMemos.map    { .memo($0) }
        let macItems:   [LifeLogItem] = macActivities.map { .mac($0)  }

        return (visitItems + memoItems + macItems).sorted { $0.time < $1.time }
    }

    // MARK: - CRUD

    func addMemo(_ text: String, at time: Date = Date()) {
        let memo = LifeLogMemo(text: text, time: time)
        todayMemos.append(memo)
        saveToday()
    }

    func updateMemo(id: String, text: String) {
        guard let idx = todayMemos.firstIndex(where: { $0.id == id }) else { return }
        todayMemos[idx].text = text
        todayMemos[idx].editedAt = Date()
        saveToday()
    }

    func deleteMemo(id: String) {
        todayMemos.removeAll { $0.id == id }
        saveToday()
    }

    // MARK: - 永続化

    private func rolloverIfNeeded() {
        let today = dayKey(Date())
        if UserDefaults.standard.string(forKey: memosDateKey) != today {
            todayMemos = []
            UserDefaults.standard.set(today, forKey: memosDateKey)
            saveToday()
        }
    }

    private func loadToday() {
        rolloverIfNeeded()
        if let data = UserDefaults.standard.data(forKey: memosKey),
           let memos = try? JSONDecoder().decode([LifeLogMemo].self, from: data) {
            todayMemos = memos
        }
    }

    private func saveToday() {
        if let data = try? JSONEncoder().encode(todayMemos) {
            UserDefaults.standard.set(data, forKey: memosKey)
        }
    }

    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
