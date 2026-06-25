import Foundation

/// On-device offline cache of the session list and per-session message history,
/// stored as JSON files. Lets iOS show history instantly and while the Mac is off.
enum LocalCache {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("HermesCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private static func safe(_ id: String) -> String {
        id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? String($0) : "_" }.joined()
    }

    // MARK: - Sessions

    // Encrypt cache at rest (readable only while the device is unlocked once).
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]

    static func saveSessions(_ sessions: [Session]) {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: url("sessions.json"), options: writeOptions)
        }
    }

    static func loadSessions() -> [Session] {
        guard let data = try? Data(contentsOf: url("sessions.json")),
              let list = try? JSONDecoder().decode([Session].self, from: data) else { return [] }
        return list
    }

    // MARK: - Messages

    static func saveMessages(_ sessionId: String, _ messages: [CachedMessage]) {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: url("msgs_\(safe(sessionId)).json"), options: writeOptions)
        }
    }

    static func loadMessages(_ sessionId: String) -> [CachedMessage] {
        guard let data = try? Data(contentsOf: url("msgs_\(safe(sessionId)).json")),
              let list = try? JSONDecoder().decode([CachedMessage].self, from: data) else { return [] }
        return list
    }

    static func deleteMessages(_ sessionId: String) {
        try? FileManager.default.removeItem(at: url("msgs_\(safe(sessionId)).json"))
    }

    /// Drop cached message files for sessions no longer present on the server.
    static func reconcileDeleted(keeping ids: Set<String>) {
        let safeKeep = Set(ids.map { "msgs_\(safe($0)).json" })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasPrefix("msgs_") && !safeKeep.contains(f) {
            try? FileManager.default.removeItem(at: url(f))
        }
    }
}
