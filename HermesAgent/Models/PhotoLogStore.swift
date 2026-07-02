import Foundation
import Combine

/// One indexed photo/video on the lifelog timeline (metadata only — no image bytes stored here).
struct PhotoLogEntry: Codable, Identifiable, Equatable {
    var id: String          // PHAsset.localIdentifier
    var time: Date
    var label: String       // e.g. "シーン: 食事" / "ライフログ写真" / "動画 30秒"
    var mediaKind: String   // "image" | "video"
}

/// Persists today's indexed photo events for the iOS lifelog timeline (day-keyed archive).
@MainActor
final class PhotoLogStore: ObservableObject {
    static let shared = PhotoLogStore()

    @Published private(set) var todayEntries: [PhotoLogEntry] = []

    private let todayKey = "photoLogToday"
    private let dateKey = "photoLogDate"
    private let archiveKey = "photoLogArchive"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadToday()
    }

    func entries(on date: Date) -> [PhotoLogEntry] {
        rolloverIfNeeded()
        let key = dayKey(date)
        if key == dayKey(Date()) { return todayEntries }
        return loadArchive()[key] ?? []
    }

    func entryCount(on date: Date) -> Int { entries(on: date).count }

    /// Record a newly indexed asset (idempotent per asset id for today).
    func addEntry(id: String, time: Date, label: String, mediaKind: String) {
        rolloverIfNeeded()
        guard !todayEntries.contains(where: { $0.id == id }) else { return }
        todayEntries.append(PhotoLogEntry(id: id, time: time, label: label, mediaKind: mediaKind))
        todayEntries.sort { $0.time < $1.time }
        saveToday()
    }

    /// Replace caption after async analysis (e.g. Mac vision).
    func updateEntryLabel(id: String, label: String) {
        rolloverIfNeeded()
        guard let idx = todayEntries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todayEntries[idx].label = trimmed
        saveToday()
    }

    // MARK: - Persistence

    private func rolloverIfNeeded() {
        let today = dayKey(Date())
        let stored = defaults.string(forKey: dateKey)
        guard stored != today else { return }
        var archive = loadArchive()
        if let prev = stored, !todayEntries.isEmpty {
            var existing = archive[prev] ?? []
            existing.append(contentsOf: todayEntries)
            archive[prev] = existing.sorted { $0.time < $1.time }
        }
        todayEntries = []
        saveArchive(archive)
        defaults.set(today, forKey: dateKey)
        saveToday()
    }

    private func loadToday() {
        rolloverIfNeeded()
        guard let data = defaults.data(forKey: todayKey),
              let entries = try? JSONDecoder().decode([PhotoLogEntry].self, from: data) else { return }
        todayEntries = entries
    }

    private func saveToday() {
        if let data = try? JSONEncoder().encode(todayEntries) {
            defaults.set(data, forKey: todayKey)
        }
    }

    private func loadArchive() -> [String: [PhotoLogEntry]] {
        guard let data = defaults.data(forKey: archiveKey),
              let archive = try? JSONDecoder().decode([String: [PhotoLogEntry]].self, from: data) else {
            return [:]
        }
        return archive
    }

    private func saveArchive(_ archive: [String: [PhotoLogEntry]]) {
        if let data = try? JSONEncoder().encode(archive) {
            defaults.set(data, forKey: archiveKey)
        }
    }

    private func dayKey(_ date: Date) -> String {
        HomeDateHelpers.dayKey(date)
    }
}
