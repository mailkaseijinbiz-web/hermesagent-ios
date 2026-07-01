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

/// タイムラインに並ぶ1アイテム（場所訪問 / メモ / Mac アクティビティ / 写真）。
enum LifeLogItem: Identifiable {
    case visit(VisitEntry, duration: TimeInterval?)
    case memo(LifeLogMemo)
    case mac(MacActivityEntry)
    case macSummary(MacActivitySummary)
    case photo(PhotoLogEntry)

    var id: String {
        switch self {
        case .visit(let v, _): return "v-\(v.id)"
        case .memo(let m):     return "m-\(m.id)"
        case .mac(let a):      return "a-\(a.id)"
        case .macSummary(let s):
            return "mac-summary-\(Int(s.anchorTime.timeIntervalSince1970))"
        case .photo(let p):    return "p-\(p.id)"
        }
    }

    var time: Date {
        switch self {
        case .visit(let v, _): return v.time
        case .memo(let m):     return m.time
        case .mac(let a):      return a.startDate
        case .macSummary(let s): return s.anchorTime
        case .photo(let p):    return p.time
        }
    }
}

/// メモを日付キー付きでアーカイブする純粋ロジック（テスト可能）。
enum LifeLogArchiveLogic {
    static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        HomeDateHelpers.dayKey(d, calendar: calendar)
    }

    static func memos(on date: Date, todayKey: String, todayMemos: [LifeLogMemo], archive: [String: [LifeLogMemo]], calendar: Calendar = .current) -> [LifeLogMemo] {
        let key = dayKey(date, calendar: calendar)
        if key == todayKey { return todayMemos }
        return archive[key] ?? []
    }

    static func memos(from start: Date, to end: Date, todayKey: String, todayMemos: [LifeLogMemo], archive: [String: [LifeLogMemo]], calendar: Calendar = .current) -> [LifeLogMemo] {
        var out: [LifeLogMemo] = []
        var d = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while d <= endDay {
            out.append(contentsOf: memos(on: d, todayKey: todayKey, todayMemos: todayMemos, archive: archive, calendar: calendar))
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? endDay.addingTimeInterval(86400)
        }
        return out.sorted { $0.time < $1.time }
    }

    /// 日付が変わったら前日分をアーカイブに移す。戻り値は更新後の todayMemos。
    static func rollover(todayMemos: [LifeLogMemo], storedDateKey: String?, todayKey: String, archive: [String: [LifeLogMemo]]) -> (todayMemos: [LifeLogMemo], archive: [String: [LifeLogMemo]], newDateKey: String) {
        guard storedDateKey != todayKey else {
            return (todayMemos, archive, todayKey)
        }
        var updatedArchive = archive
        if let prev = storedDateKey, !todayMemos.isEmpty {
            var existing = updatedArchive[prev] ?? []
            existing.append(contentsOf: todayMemos)
            updatedArchive[prev] = existing
        }
        return ([], updatedArchive, todayKey)
    }
}

/// メモを日付キー付きで管理。LocationManager の訪問記録とマージしてタイムラインを作る。
@MainActor
final class LifeLogStore: ObservableObject {
    static let shared = LifeLogStore()

    @Published var todayMemos: [LifeLogMemo] = []
    @Published var macActivities: [MacActivityEntry] = []

    private let memosKey = "lifeLogMemos"
    private let memosDateKey = "lifeLogMemosDate"
    private let archiveKey = "lifeLogMemosArchive"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadToday()
    }

    // MARK: - タイムライン生成

    /// 訪問記録・メモ・Mac アクティビティ・写真を時系列にマージして返す。
    func timeline(
        visits: [VisitEntry],
        memos: [LifeLogMemo]? = nil,
        macActivities: [MacActivityEntry]? = nil,
        photoEntries: [PhotoLogEntry]? = nil
    ) -> [LifeLogItem] {
        let memoList = memos ?? todayMemos
        let macList = macActivities ?? self.macActivities
        let photos = photoEntries ?? []
        let visitItems: [LifeLogItem] = visits.enumerated().map { idx, v in
            let nextTime = idx + 1 < visits.count ? visits[idx + 1].time : nil
            let dur = nextTime.map { $0.timeIntervalSince(v.time) }
            return .visit(v, duration: dur)
        }
        let memoItems:  [LifeLogItem] = memoList.map { .memo($0) }
        let photoItems: [LifeLogItem] = photos.map { .photo($0) }
        let macSummaryItem: LifeLogItem? = MacActivitySummarizer.summarize(macList).map { .macSummary($0) }

        var items = visitItems + memoItems + photoItems
        if let macSummaryItem { items.append(macSummaryItem) }
        return items.sorted { $0.time < $1.time }
    }

    func timeline(for date: Date, visits: [VisitEntry], photoEntries: [PhotoLogEntry]? = nil) -> [LifeLogItem] {
        let memos = memos(on: date)
        let mac = macActivities(on: date)
        let photos = photoEntries ?? PhotoLogStore.shared.entries(on: date)
        return timeline(visits: visits, memos: memos, macActivities: mac, photoEntries: photos)
    }

    // MARK: - 日付別クエリ

    func memos(on date: Date) -> [LifeLogMemo] {
        rolloverIfNeeded()
        return LifeLogArchiveLogic.memos(
            on: date,
            todayKey: todayKey(),
            todayMemos: todayMemos,
            archive: loadArchive()
        )
    }

    func memos(from start: Date, to end: Date) -> [LifeLogMemo] {
        rolloverIfNeeded()
        return LifeLogArchiveLogic.memos(
            from: start,
            to: end,
            todayKey: todayKey(),
            todayMemos: todayMemos,
            archive: loadArchive()
        )
    }

    func memoCount(on date: Date) -> Int { memos(on: date).count }

    func hasActivity(on date: Date, visitCount: Int) -> Bool {
        memoCount(on: date) > 0 || visitCount > 0 || !macActivities(on: date).isEmpty
            || PhotoLogStore.shared.entryCount(on: date) > 0
    }

    func macActivities(on date: Date) -> [MacActivityEntry] {
        let range = HomeDateHelpers.dayRange(for: date)
        return macActivities.filter { $0.startDate >= range.start && $0.startDate < range.end }
    }

    func macActivities(from start: Date, to end: Date) -> [MacActivityEntry] {
        let s = HomeDateHelpers.startOfDay(start)
        let e = HomeDateHelpers.startOfDay(end)
        let endExclusive = Calendar.current.date(byAdding: .day, value: 1, to: e) ?? e.addingTimeInterval(86400)
        return macActivities.filter { $0.startDate >= s && $0.startDate < endExclusive }
    }

    // MARK: - CRUD

    func addMemo(_ text: String, at time: Date = Date()) {
        rolloverIfNeeded()
        let memo = LifeLogMemo(text: text, time: time)
        todayMemos.append(memo)
        saveToday()
    }

    func updateMemo(id: String, text: String) {
        rolloverIfNeeded()
        if let idx = todayMemos.firstIndex(where: { $0.id == id }) {
            todayMemos[idx].text = text
            todayMemos[idx].editedAt = Date()
            saveToday()
            return
        }
        var archive = loadArchive()
        for (key, var memos) in archive {
            if let idx = memos.firstIndex(where: { $0.id == id }) {
                memos[idx].text = text
                memos[idx].editedAt = Date()
                archive[key] = memos
                saveArchive(archive)
                return
            }
        }
    }

    func deleteMemo(id: String) {
        rolloverIfNeeded()
        if todayMemos.contains(where: { $0.id == id }) {
            todayMemos.removeAll { $0.id == id }
            saveToday()
            return
        }
        var archive = loadArchive()
        for (key, var memos) in archive {
            if memos.contains(where: { $0.id == id }) {
                memos.removeAll { $0.id == id }
                archive[key] = memos.isEmpty ? nil : memos
                if archive[key] == nil { archive.removeValue(forKey: key) }
                saveArchive(archive)
                return
            }
        }
    }

    // MARK: - 永続化

    private func rolloverIfNeeded() {
        let today = todayKey()
        let stored = defaults.string(forKey: memosDateKey)
        let result = LifeLogArchiveLogic.rollover(
            todayMemos: todayMemos,
            storedDateKey: stored,
            todayKey: today,
            archive: loadArchive()
        )
        if stored != today {
            todayMemos = result.todayMemos
            saveArchive(result.archive)
            defaults.set(result.newDateKey, forKey: memosDateKey)
            saveToday()
        }
    }

    private func loadToday() {
        migrateLegacyIfNeeded()
        rolloverIfNeeded()
        if let data = defaults.data(forKey: memosKey),
           let memos = try? JSONDecoder().decode([LifeLogMemo].self, from: data) {
            todayMemos = memos
        }
    }

    private func migrateLegacyIfNeeded() {
        guard defaults.data(forKey: archiveKey) == nil else { return }
        // 既存の today データは memosKey に残っている — rollover でアーカイブへ移行される
    }

    private func saveToday() {
        if let data = try? JSONEncoder().encode(todayMemos) {
            defaults.set(data, forKey: memosKey)
        }
    }

    private func loadArchive() -> [String: [LifeLogMemo]] {
        guard let data = defaults.data(forKey: archiveKey),
              let archive = try? JSONDecoder().decode([String: [LifeLogMemo]].self, from: data) else {
            return [:]
        }
        return archive
    }

    private func saveArchive(_ archive: [String: [LifeLogMemo]]) {
        if let data = try? JSONEncoder().encode(archive) {
            defaults.set(data, forKey: archiveKey)
        }
    }

    private func todayKey() -> String {
        LifeLogArchiveLogic.dayKey(Date())
    }
}
