import Foundation
import Combine

/// Hermes アプリ自身のフォアグラウンド滞在時間をその日ごとに蓄積する。
/// ScenePhase の active/background トリガーで onForeground()/onBackground() を呼ぶ。
@MainActor
final class AppUsageTracker: ObservableObject {
    static let shared = AppUsageTracker()

    @Published var todayMinutes: Int = 0

    private var foregroundStart: Date?
    private let udKey = "hermesAppUsageByDate"

    init() { loadToday() }

    func onForeground() {
        foregroundStart = Date()
    }

    func onBackground() {
        guard let start = foregroundStart else { return }
        accumulate(seconds: Date().timeIntervalSince(start))
        foregroundStart = nil
    }

    /// アプリ終了時など明示的に保存したいとき
    func flush() { onBackground(); foregroundStart = Date() }

    func loadToday() {
        let dict = storedDict()
        todayMinutes = Int((dict[todayKey()] ?? 0) / 60)
    }

    // MARK: - Private

    private func accumulate(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        var dict = storedDict()
        let key = todayKey()
        dict[key] = (dict[key] ?? 0) + seconds
        // 8日以上前のデータを削除
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            .map { dateKey($0) } ?? ""
        dict = dict.filter { $0.key >= cutoff }
        UserDefaults.standard.set(dict, forKey: udKey)
        todayMinutes = Int((dict[key] ?? 0) / 60)
    }

    private func storedDict() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: udKey) as? [String: Double]) ?? [:]
    }

    private func todayKey() -> String { dateKey(Date()) }

    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
