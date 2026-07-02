import Foundation
import Combine

/// ライフログのメモエントリ（ユーザーが追記するテキスト）。
struct LifeLogMemo: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var time: Date
    var editedAt: Date? = nil
    /// nil / "ios" = 端末ローカル、"mac" = Mac ハブから同期。
    var source: String? = nil
    var pageTitle: String? = nil
    var mediaKind: String? = nil
    /// Mac ハブ側の添付画像ファイル名（`~/.hermes/memo-images/` 配下）。
    var imageNames: [String]? = nil

    var isEditableOnDevice: Bool { source == nil || source == "ios" }

    var hasMacImages: Bool { !(imageNames ?? []).isEmpty }

    /// Mac ライフログタイムラインと同じラベル/本文。
    var timelineLabel: String {
        if let kg = WeightMemoParser.parse(text) { return WeightMemoParser.displayLabel(kg: kg) }
        switch mediaKind {
        case "url": return "共有リンク"
        case "image": return "写真"
        case "video": return "動画"
        default: return source == "web" ? "Web" : "メモ"
        }
    }

    var timelineDetail: String {
        if let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return text
    }
}

/// Mac dailyHistory 行（健康・外出・写真）。過去日の iOS 表示用。
struct MacDayRecord: Codable, Equatable {
    var date: String
    var steps: Int?
    var activeEnergyKcal: Int?
    var restingHeartRate: Int?
    var sleepHours: Double?
    var bodyMassKg: Double?
    var locations: String = ""
    var photos: String = ""

    var hasHealthData: Bool {
        (steps ?? 0) > 0 || (activeEnergyKcal ?? 0) > 0 || (restingHeartRate ?? 0) > 0
            || (sleepHours ?? 0) > 0 || (bodyMassKg ?? 0) > 0
    }

    var hasLocations: Bool {
        !locations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Mac からフェッチしたアプリ/Hermes セッション。
struct MacActivityEntry: Codable, Identifiable {
    var id: String
    var kind: String         // "app" | "hermes"
    var appName: String
    var bundleId: String?    // Optionalでバックコンパット
    var label: String
    var windowTitle: String? // ウィンドウタイトル（Optionalでバックコンパット）
    var url: String?         // ブラウザURL（Optionalでバックコンパット）
    var startTime: Double    // epoch seconds
    var endTime: Double
    var duration: Double { endTime - startTime }
    var startDate: Date { Date(timeIntervalSince1970: startTime) }
}

/// タイムラインに並ぶ1アイテム（場所訪問 / 移動 / メモ / Mac アクティビティ / 写真）。
/// 1晩の睡眠記録（就寝〜起床、HealthKit sleepAnalysis 由来）。
struct SleepRecord: Codable, Equatable {
    var start: Date       // 就寝
    var end: Date         // 起床
    var hours: Double     // 実睡眠時間（時間）
}

enum LifeLogItem: Identifiable {
    case visit(VisitEntry, duration: TimeInterval?)
    case mobility(MobilityTimelineEntry)
    case memo(LifeLogMemo)
    case mac(MacActivityEntry)
    case macSummary(MacActivitySummary)
    case photo(PhotoLogEntry)
    /// Mac dailyHistory の外出/写真サマリー行（Mac タイムラインの location/photo イベント相当）。
    case macSnapshot(label: String, detail: String, time: Date)
    /// 睡眠ブロック（就寝→起床）。
    case sleep(SleepRecord)
    /// 連続した写真の組写真（コラージュ表示）。
    case photoGroup([PhotoLogEntry])

    var id: String {
        switch self {
        case .visit(let v, _): return "v-\(v.id)"
        case .mobility(let m): return m.id
        case .memo(let m):     return "m-\(m.id)"
        case .mac(let a):      return "a-\(a.id)"
        case .macSummary(let s):
            return "mac-summary-\(Int(s.anchorTime.timeIntervalSince1970))"
        case .photo(let p):    return "p-\(p.id)"
        case .macSnapshot(let label, let detail, let time):
            return "snap-\(label)-\(Int(time.timeIntervalSince1970))-\(detail.hashValue)"
        case .sleep(let s):    return "sleep-\(Int(s.end.timeIntervalSince1970))"
        case .photoGroup(let ps): return "pg-\(ps.first?.id ?? "empty")"
        }
    }

    var time: Date {
        switch self {
        case .visit(let v, _): return v.time
        case .mobility(let m): return m.time
        case .memo(let m):     return m.time
        case .mac(let a):      return a.startDate
        case .macSummary(let s): return s.anchorTime
        case .photo(let p):    return p.time
        case .macSnapshot(_, _, let time): return time
        case .sleep(let s):    return s.start   // 就寝時刻の位置（前夜スタートなら日頭に並ぶ）
        case .photoGroup(let ps): return ps.first?.time ?? .distantPast
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

/// Mac 同期データのマージ（テスト可能）。
enum LifeLogSyncLogic {
    static func mergeMemos(existing: [LifeLogMemo], incoming: [LifeLogMemo]) -> [LifeLogMemo] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for memo in incoming { byId[memo.id] = memo }
        return byId.values.sorted { $0.time < $1.time }
    }

    /// Mac から取得したメモの時刻が別日になっている場合、対象日の時刻帯に寄せる。
    static func normalizeMacMemosForDay(_ memos: [LifeLogMemo], day: Date, calendar: Calendar = .current) -> [LifeLogMemo] {
        let dayStart = calendar.startOfDay(for: day)
        return memos.map { memo in
            guard !calendar.isDate(memo.time, inSameDayAs: day) else { return memo }
            var m = memo
            let h = calendar.component(.hour, from: memo.time)
            let min = calendar.component(.minute, from: memo.time)
            let sec = calendar.component(.second, from: memo.time)
            m.time = calendar.date(bySettingHour: h, minute: min, second: sec, of: dayStart)
                ?? dayStart.addingTimeInterval(12 * 3600)
            return m
        }
    }

    static func mergeMacActivities(existing: [MacActivityEntry], incoming: [MacActivityEntry]) -> [MacActivityEntry] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for entry in incoming { byId[entry.id] = entry }
        return byId.values.sorted { $0.startTime < $1.startTime }
    }

    static func bucketMacActivities(_ entries: [MacActivityEntry], calendar: Calendar = .current) -> [String: [MacActivityEntry]] {
        var buckets: [String: [MacActivityEntry]] = [:]
        for entry in entries {
            let key = HomeDateHelpers.dayKey(entry.startDate, calendar: calendar)
            buckets[key, default: []].append(entry)
        }
        return buckets
    }

    /// ローカル HealthKit 指標に Mac dailyHistory をマージ（非ゼロのローカル値を優先）。
    static func mergeHealth(local: DayHealthMetrics, remote: MacDayRecord?) -> DayHealthMetrics {
        guard let r = remote, r.hasHealthData else { return local }
        var m = local
        if m.steps == 0, let v = r.steps, v > 0 { m.steps = v }
        if m.activeEnergy == 0, let v = r.activeEnergyKcal, v > 0 { m.activeEnergy = v }
        if m.restingHR == 0, let v = r.restingHeartRate, v > 0 { m.restingHR = v }
        if m.sleepHours == 0, let v = r.sleepHours, v > 0 { m.sleepHours = v }
        if m.bodyMassKg == 0, let v = r.bodyMassKg, v > 0 { m.bodyMassKg = v }
        return m
    }
}

/// メモを日付キー付きで管理。LocationManager の訪問記録とマージしてタイムラインを作る。
@MainActor
final class LifeLogStore: ObservableObject {
    static let shared = LifeLogStore()

    @Published var todayMemos: [LifeLogMemo] = []
    @Published private(set) var macMemoCache: [String: [LifeLogMemo]] = [:]
    @Published private(set) var macActivityCache: [String: [MacActivityEntry]] = [:]
    @Published private(set) var macDayRecordCache: [String: MacDayRecord] = [:]
    /// Bumped on each Mac ingest so SwiftUI re-renders after pull-to-refresh.
    @Published private(set) var macSyncRevision: Int = 0

    private let memosKey = "lifeLogMemos"
    private let memosDateKey = "lifeLogMemosDate"
    private let archiveKey = "lifeLogMemosArchive"
    private let macMemosKey = "lifeLogMacMemosCache"
    private let macActivitiesKey = "lifeLogMacActivitiesCache"
    private let macDayRecordsKey = "lifeLogMacDayRecordsCache"
    private let dayCoversKey = "lifeLogDayCovers"
    private let eveningReflectionsKey = "lifeLogEveningReflections"
    private let hiddenTimelineKey = "lifeLogHiddenTimeline"
    private let dailySleepKey = "lifeLogDailySleep"
    private let defaults: UserDefaults

    /// 日付キー → 表紙に選んだタイムライン項目 ID（LIFEのBOOK「今日の表紙」）。
    @Published private(set) var dayCovers: [String: String] = [:]
    /// 日付キー → 夜の振り返りで確定した「今日のひとこと」。
    @Published private(set) var eveningReflections: [String: DayEveningReflection] = [:]
    /// 日付キー → 非表示にしたタイムライン項目 ID。
    @Published private(set) var hiddenTimelineByDay: [String: Set<String>] = [:]
    /// 日付キー（起床日）→ その晩の睡眠記録（HealthKit sleepAnalysis 由来）。
    @Published private(set) var dailySleep: [String: SleepRecord] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadCaches()
        loadToday()
    }

    // MARK: - タイムライン生成

    /// 訪問記録・メモ・Mac アクティビティ・写真を時系列にマージして返す。
    func timeline(
        visits: [VisitEntry],
        memos: [LifeLogMemo]? = nil,
        macActivities: [MacActivityEntry]? = nil,
        photoEntries: [PhotoLogEntry]? = nil,
        referenceNow: Date = Date()
    ) -> [LifeLogItem] {
        let memoList = memos ?? todayMemos
        let macList = macActivities ?? self.macActivities(on: Date())
        let photos = photoEntries ?? []
        let visitItems = VisitTimelineComposer.compose(visits: visits, now: referenceNow)
        let memoItems:  [LifeLogItem] = memoList.map { .memo($0) }
        let photoItems: [LifeLogItem] = photos.map { .photo($0) }
        let significantMac = macList.filter { $0.duration >= 30 }
        let uniqueFocusCount = Set(significantMac.map { MacWorkFocus.focusGroupKey(for: $0) }).count
        let macItems: [LifeLogItem]
        if uniqueFocusCount > 5, let summary = MacActivitySummarizer.summarize(macList) {
            macItems = [.macSummary(summary)]
        } else {
            macItems = significantMac.map { .mac($0) }
        }

        var items = visitItems + memoItems + photoItems + macItems
        return items.sorted { $0.time < $1.time }
    }

    // MARK: - 今日の表紙（LIFEのBOOK）

    func dayCoverItemId(for date: Date) -> String? {
        dayCovers[LifeLogArchiveLogic.dayKey(date)]
    }

    func resolveCover(in items: [LifeLogItem], for date: Date) -> LifeLogItem? {
        guard let id = dayCoverItemId(for: date) else { return nil }
        return items.first { $0.id == id }
    }

    func setDayCover(_ item: LifeLogItem, for date: Date) {
        let key = LifeLogArchiveLogic.dayKey(date)
        dayCovers[key] = item.id
        saveDayCovers()
    }

    func clearDayCover(for date: Date) {
        let key = LifeLogArchiveLogic.dayKey(date)
        dayCovers.removeValue(forKey: key)
        saveDayCovers()
    }

    // MARK: - 夜の振り返り

    func eveningReflection(on date: Date) -> DayEveningReflection? {
        eveningReflections[LifeLogArchiveLogic.dayKey(date)]
    }

    func hasCompletedEveningReflection(on date: Date = Date()) -> Bool {
        eveningReflection(on: date) != nil
    }

    func saveEveningReflection(_ reflection: DayEveningReflection, for date: Date) {
        let key = LifeLogArchiveLogic.dayKey(date)
        eveningReflections[key] = reflection
        saveEveningReflections()
    }

    func updateEveningReflectionFeedback(for date: Date, thumb: String?, comment: String) {
        let key = LifeLogArchiveLogic.dayKey(date)
        guard var r = eveningReflections[key] else { return }
        r.feedbackThumb = thumb
        r.feedbackComment = comment.isEmpty ? nil : comment
        eveningReflections[key] = r
        saveEveningReflections()
    }

    func updateEveningReflectionOneLiner(for date: Date, oneLiner: String, aiSource: String, aiReflection: String? = nil) {
        let key = LifeLogArchiveLogic.dayKey(date)
        guard var r = eveningReflections[key] else { return }
        r.oneLiner = oneLiner
        r.aiSource = aiSource
        if let aiReflection { r.aiReflection = aiReflection.isEmpty ? nil : aiReflection }
        eveningReflections[key] = r
        saveEveningReflections()
    }

    func timeline(for date: Date, visits: [VisitEntry], photoEntries: [PhotoLogEntry]? = nil) -> [LifeLogItem] {
        let memos = memos(on: date)
        let mac = macActivities(on: date)
        let photos = photoEntries ?? PhotoLogStore.shared.entries(on: date)
        let referenceNow = referenceTime(for: date)
        var items = timeline(
            visits: visits,
            memos: memos,
            macActivities: mac,
            photoEntries: photos,
            referenceNow: referenceNow
        )
        items.append(contentsOf: macSnapshotItems(for: date, existing: items))
        if let sleep = dailySleep[LifeLogArchiveLogic.dayKey(date)] {
            items.append(.sleep(sleep))
        }
        let hidden = hiddenTimelineByDay[LifeLogArchiveLogic.dayKey(date)] ?? []
        let sorted = items.filter { !hidden.contains($0.id) }.sorted { $0.time < $1.time }
        return Self.groupConsecutivePhotos(sorted)
    }

    /// 連続する写真（スクショ以外）を1つの組写真にまとめる。
    /// 間に別の記録が挟まれば別グループになる。1枚だけならそのまま。
    static func groupConsecutivePhotos(_ items: [LifeLogItem]) -> [LifeLogItem] {
        var out: [LifeLogItem] = []
        var run: [PhotoLogEntry] = []
        func flush() {
            if run.count == 1 { out.append(.photo(run[0])) }
            else if run.count > 1 { out.append(.photoGroup(run)) }
            run = []
        }
        for item in items {
            if case .photo(let p) = item, p.isScreenshot != true {
                run.append(p)
            } else {
                flush()
                out.append(item)
            }
        }
        flush()
        return out
    }

    /// その晩の睡眠記録を登録する（起床日をキーに保存、上書き可）。
    func setSleep(_ record: SleepRecord, for date: Date) {
        let key = LifeLogArchiveLogic.dayKey(date)
        guard dailySleep[key] != record else { return }
        dailySleep[key] = record
        saveDailySleep()
    }

    private func saveDailySleep() {
        // 90日より古い記録は落としてファイルを肥大化させない
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        dailySleep = dailySleep.filter { $0.value.end > cutoff }
        if let data = try? JSONEncoder().encode(dailySleep) {
            defaults.set(data, forKey: dailySleepKey)
        }
    }

    func hideTimelineItem(id: String, for date: Date) {
        let key = LifeLogArchiveLogic.dayKey(date)
        var copy = hiddenTimelineByDay
        var set = copy[key] ?? []
        set.insert(id)
        copy[key] = set
        hiddenTimelineByDay = copy
        if dayCovers[key] == id {
            dayCovers.removeValue(forKey: key)
            saveDayCovers()
        }
        saveHiddenTimeline()
    }

    func deleteTimelineItem(_ item: LifeLogItem, for date: Date) {
        switch item {
        case .memo(let m) where m.isEditableOnDevice:
            deleteMemo(id: m.id)
        default:
            hideTimelineItem(id: item.id, for: date)
        }
    }

    private func referenceTime(for date: Date) -> Date {
        if Calendar.current.isDateInToday(date) { return Date() }
        return Calendar.current.startOfDay(for: date).addingTimeInterval(86399)
    }

    /// Mac dailyHistory の外出/写真サマリーをタイムライン行として追加（Mac 側と同じ見え方）。
    private func macSnapshotItems(for date: Date, existing: [LifeLogItem]) -> [LifeLogItem] {
        guard let record = macDayRecord(on: date) else { return [] }
        let noon = Calendar.current.startOfDay(for: date).addingTimeInterval(12 * 3600)
        var out: [LifeLogItem] = []
        let existingText = existing.map { item -> String in
            switch item {
            case .memo(let m): return m.timelineDetail + m.text
            case .visit(let v, _): return v.name
            case .photo(let p): return p.label
            case .macSnapshot(_, let detail, _): return detail
            default: return ""
            }
        }.joined(separator: " ")

        let loc = record.locations.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.hasLocations, !loc.isEmpty, !textCovers(existingText, summary: loc) {
            out.append(.macSnapshot(label: "外出", detail: loc, time: noon.addingTimeInterval(60)))
        }
        let photoLine = record.photos.trimmingCharacters(in: .whitespacesAndNewlines)
        if !photoLine.isEmpty, !textCovers(existingText, summary: photoLine) {
            out.append(.macSnapshot(label: "写真", detail: photoLine, time: noon.addingTimeInterval(120)))
        }
        return out
    }

    /// サマリー内の語が既存タイムラインに含まれていれば重複とみなす。
    private func textCovers(_ existing: String, summary: String) -> Bool {
        if existing.contains(summary) { return true }
        let parts = summary.split { $0 == "," || $0 == "、" || $0 == "→" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        return !parts.isEmpty && parts.allSatisfy { existing.contains($0) }
    }

    // MARK: - 日付別クエリ

    func memos(on date: Date) -> [LifeLogMemo] {
        rolloverIfNeeded()
        let local = LifeLogArchiveLogic.memos(
            on: date,
            todayKey: todayKey(),
            todayMemos: todayMemos,
            archive: loadArchive()
        )
        let key = LifeLogArchiveLogic.dayKey(date)
        let remote = macMemoCache[key] ?? []
        return LifeLogSyncLogic.mergeMemos(existing: local, incoming: remote)
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
            || macDayRecord(on: date)?.hasHealthData == true
            || macDayRecord(on: date)?.hasLocations == true
    }

    func macActivities(on date: Date) -> [MacActivityEntry] {
        let key = LifeLogArchiveLogic.dayKey(date)
        return macActivityCache[key] ?? []
    }

    func macDayRecord(on date: Date) -> MacDayRecord? {
        let key = LifeLogArchiveLogic.dayKey(date)
        return macDayRecordCache[key]
    }

    func macActivities(from start: Date, to end: Date) -> [MacActivityEntry] {
        var out: [MacActivityEntry] = []
        var d = Calendar.current.startOfDay(for: start)
        let endDay = Calendar.current.startOfDay(for: end)
        while d <= endDay {
            out.append(contentsOf: macActivities(on: d))
            d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? endDay.addingTimeInterval(86400)
        }
        return out.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Mac sync

    func ingestMacMemos(_ memos: [LifeLogMemo], dayKey: String) {
        guard let day = HomeDateHelpers.dayKeyToDate(dayKey) else { return }
        let normalized = LifeLogSyncLogic.normalizeMacMemosForDay(memos, day: day)
        var cache = macMemoCache
        cache[dayKey] = normalized
        macMemoCache = cache
        macSyncRevision += 1
        saveMacMemoCache()
    }

    func ingestMacActivities(_ entries: [MacActivityEntry]) {
        guard !entries.isEmpty else { return }
        var cache = macActivityCache
        for (dayKey, bucket) in LifeLogSyncLogic.bucketMacActivities(entries) {
            let merged = LifeLogSyncLogic.mergeMacActivities(existing: cache[dayKey] ?? [], incoming: bucket)
            cache[dayKey] = merged
        }
        macActivityCache = cache
        macSyncRevision += 1
        saveMacActivityCache()
    }

    func ingestMacDayRecord(_ record: MacDayRecord) {
        guard record.hasHealthData || record.hasLocations || !record.photos.isEmpty else { return }
        var cache = macDayRecordCache
        cache[record.date] = record
        macDayRecordCache = cache
        macSyncRevision += 1
        saveMacDayRecordCache()
    }

    /// iOS → Mac 送信後にローカル ID をハブ側 ID に揃える（重複表示を防ぐ）。
    func reconcileMemoId(localId: String, remoteId: String) {
        guard localId != remoteId else { return }
        rolloverIfNeeded()
        if let idx = todayMemos.firstIndex(where: { $0.id == localId }) {
            todayMemos[idx].id = remoteId
            todayMemos[idx].source = "ios"
            saveToday()
        }
    }

    // MARK: - CRUD

    func addMemo(_ text: String, at time: Date = Date()) -> LifeLogMemo {
        rolloverIfNeeded()
        var memo = LifeLogMemo(text: text, time: time, source: "ios")
        todayMemos.append(memo)
        saveToday()
        return memo
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

    private func loadCaches() {
        if let data = defaults.data(forKey: macMemosKey),
           let cache = try? JSONDecoder().decode([String: [LifeLogMemo]].self, from: data) {
            macMemoCache = cache
        }
        if let data = defaults.data(forKey: macActivitiesKey),
           let cache = try? JSONDecoder().decode([String: [MacActivityEntry]].self, from: data) {
            macActivityCache = cache
        }
        if let data = defaults.data(forKey: macDayRecordsKey),
           let cache = try? JSONDecoder().decode([String: MacDayRecord].self, from: data) {
            macDayRecordCache = cache
        }
        if let data = defaults.data(forKey: dayCoversKey),
           let covers = try? JSONDecoder().decode([String: String].self, from: data) {
            dayCovers = covers
        }
        if let data = defaults.data(forKey: eveningReflectionsKey),
           let reflections = try? JSONDecoder().decode([String: DayEveningReflection].self, from: data) {
            eveningReflections = reflections
        }
        if let data = defaults.data(forKey: hiddenTimelineKey),
           let hidden = try? JSONDecoder().decode([String: [String]].self, from: data) {
            hiddenTimelineByDay = hidden.mapValues { Set($0) }
        }
        if let data = defaults.data(forKey: dailySleepKey),
           let sleep = try? JSONDecoder().decode([String: SleepRecord].self, from: data) {
            dailySleep = sleep
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

    private func saveMacMemoCache() {
        if let data = try? JSONEncoder().encode(macMemoCache) {
            defaults.set(data, forKey: macMemosKey)
        }
    }

    private func saveMacActivityCache() {
        if let data = try? JSONEncoder().encode(macActivityCache) {
            defaults.set(data, forKey: macActivitiesKey)
        }
    }

    private func saveMacDayRecordCache() {
        if let data = try? JSONEncoder().encode(macDayRecordCache) {
            defaults.set(data, forKey: macDayRecordsKey)
        }
    }

    private func saveDayCovers() {
        if let data = try? JSONEncoder().encode(dayCovers) {
            defaults.set(data, forKey: dayCoversKey)
        }
    }

    private func saveEveningReflections() {
        if let data = try? JSONEncoder().encode(eveningReflections) {
            defaults.set(data, forKey: eveningReflectionsKey)
        }
    }

    private func saveHiddenTimeline() {
        let encoded = hiddenTimelineByDay.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: hiddenTimelineKey)
        }
    }

    private func todayKey() -> String {
        LifeLogArchiveLogic.dayKey(Date())
    }
}
