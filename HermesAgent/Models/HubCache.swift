import Foundation

extension Notification.Name {
    /// GETがネットワーク失敗でキャッシュから応答した（オフライン表示のトリガ）。
    static let hubServedFromCache = Notification.Name("hubServedFromCache")
    /// GETがライブ応答に成功した（オフライン表示の解除）。
    static let hubServedLive = Notification.Name("hubServedLive")
}

/// ハブGET応答のディスクキャッシュ。圏外・Mac未達でも最終取得データで動けるようにする。
/// 値の鮮度は呼び出し側で判断できるよう保存時刻も返す。
actor HubCache {
    static let shared = HubCache()

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("HubCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func fileURL(for path: String) -> URL {
        // パス＋クエリをファイル名に安全に写像（衝突しない一方向でよい）
        let safe = path.map { ch -> Character in
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.".contains(ch) ? ch : "_"
        }
        let name = String(safe) + "-\(abs(path.hashValue))"
        return dir.appendingPathComponent(name + ".json")
    }

    func save(_ data: Data, for path: String) {
        try? data.write(to: fileURL(for: path), options: .atomic)
    }

    func load(for path: String) -> (data: Data, savedAt: Date)? {
        let url = fileURL(for: path)
        guard let data = try? Data(contentsOf: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return (data, mtime)
    }
}
