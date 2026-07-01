import Foundation
import SwiftUI

// MARK: - Schedule

/// A calendar event, mirrored from the Mac hub (local + Google merged). Google events
/// carry a "gcal:" id prefix and are read-only from mobile.
struct ScheduleEvent: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var detail: String = ""
    var date: Double                 // epoch seconds
    var allDay: Bool = true
    var assigneeId: String? = nil
    var source: String? = nil        // "local" | "google"
    var createdAt: Double = 0
    var updatedAt: Double = 0

    var isGoogle: Bool { source == "google" || id.hasPrefix("gcal:") }
    var day: Date { Date(timeIntervalSince1970: date) }

    var timeLabel: String {
        if allDay { return "終日" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "HH:mm"
        return f.string(from: day)
    }
}

// MARK: - Tasks

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case todo, doing, done
    var id: String { rawValue }
    var title: String { self == .todo ? "未着手" : (self == .doing ? "対応中" : "完了") }
    var icon: String { self == .todo ? "circle" : (self == .doing ? "circle.lefthalf.filled" : "checkmark.circle.fill") }
    var color: Color { self == .todo ? .secondary : (self == .doing ? .orange : .green) }
}

struct WorkTask: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var detail: String = ""
    var assigneeId: String? = nil
    var status: TaskStatus = .todo
    var assigneeName: String? = nil
    var assigneeEmoji: String? = nil
    var createdAt: Double = 0
    var updatedAt: Double = 0
}

// MARK: - Apps

enum AppStatus: String, Codable, CaseIterable, Identifiable {
    case idea, building, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .idea: return "構想"
        case .building: return "開発中"
        case .done: return "完成"
        }
    }
    var color: Color {
        switch self {
        case .idea: return .secondary
        case .building: return .orange
        case .done: return .green
        }
    }
}

struct AppProject: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var detail: String = ""
    var status: AppStatus = .idea
    var previewURL: String = ""
    var runCommand: String = ""
    var folderName: String = ""      // display-only (folderPath is device-local, never synced)
    var isRunning: Bool = false
    var assigneeId: String? = nil
    var assigneeName: String? = nil
    var assigneeEmoji: String? = nil
    var createdAt: Double = 0
    var updatedAt: Double = 0

    var canLaunch: Bool { !runCommand.trimmingCharacters(in: .whitespaces).isEmpty || !previewURL.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Artifacts

enum ArtifactKind: String, Codable, CaseIterable, Identifiable {
    case note, file, link
    var id: String { rawValue }
    var title: String {
        switch self {
        case .note: return "メモ"
        case .file: return "ファイル"
        case .link: return "リンク"
        }
    }
    var icon: String {
        switch self {
        case .note: return "note.text"
        case .file: return "doc"
        case .link: return "link"
        }
    }
}

struct Artifact: Identifiable, Codable, Equatable {
    let id: String
    var employeeId: String
    var title: String
    var kind: ArtifactKind
    var body: String = ""            // note→markdown, link→URL; file→empty (device-local)
    var createdAt: Double = 0
    var updatedAt: Double = 0
}

// MARK: - Employee files (read-only listing)

struct EmployeeFile: Identifiable, Codable, Equatable {
    var name: String
    var isDir: Bool
    var size: Int
    var modified: Double
    var path: String?          // workspace ルートからの相対パス (Mac が付与)
    var id: String { path ?? name }

    var displayPath: String { path ?? name }

    var sizeLabel: String {
        if isDir { return "" }
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(size), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(size) B" : String(format: "%.1f %@", v, units[i])
    }
}

// MARK: - Gmail

struct GmailThreadSummary: Identifiable, Codable, Equatable {
    let id: String
    var subject: String
    var from: String
    var snippet: String
    var hasUnread: Bool
    var messageCount: Int
    var lastDate: String

    var senderName: String {
        if let r = from.range(of: "<") { return String(from[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return from
    }
    var date: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: lastDate) ?? { let g = ISO8601DateFormatter(); return g.date(from: lastDate) }()
    }
    var relativeDate: String {
        guard let d = date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨日" }
        let f = DateFormatter(); f.dateFormat = "M/d"; return f.string(from: d)
    }
}

struct GmailMessageDTO: Identifiable, Codable, Equatable {
    let id: String
    var from: String
    var subject: String
    var date: String
    var isUnread: Bool
    var snippet: String
    var body: String

    var senderName: String {
        if let r = from.range(of: "<") { return String(from[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return from
    }
    var displayDate: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = f.date(from: date) ?? { let g = ISO8601DateFormatter(); return g.date(from: date) }()
        guard let d = parsed else { return "" }
        let out = DateFormatter(); out.locale = Locale(identifier: "ja_JP"); out.dateFormat = "M月d日 HH:mm"
        return out.string(from: d)
    }
}

struct GmailThreadDetail: Identifiable, Codable, Equatable {
    let id: String
    var subject: String
    var from: String
    var messages: [GmailMessageDTO]
}

// MARK: - Personal profile (好きなもの・目標・価値観: AIの助言の基準)

struct PersonalProfile: Codable, Equatable {
    var likes = ""    // 好きなもの（例: サウナ）
    var goals = ""    // めざしたいこと・目標（例: 健康）
    var values = ""   // 大事にしている価値観
    var notes = ""    // その他メモ（AIに知っておいてほしいこと）
}

// MARK: - Self-model（自分をPCのように: 頭のメモリ割り当て＋稼働時間）

struct ResourceAllocation: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""     // 領域（例: 仕事 / 健康 / 家族 / 学習）
    var percent: Int = 0      // 頭のメモリ割り当て（0-100）
}

struct SelfModel: Codable, Equatable {
    var allocations: [ResourceAllocation] = []
    var workStartHour: Int = 9       // 稼働開始（時）
    var workEndHour: Int = 18        // 稼働終了（時）
    var targetFocusHours: Double = 0 // 1日の目標集中時間（0=未設定）

    var totalPercent: Int { allocations.reduce(0) { $0 + $1.percent } }
}

// MARK: - Dashboard

struct IntentionAction: Codable, Equatable {
    var type: String
    var taskTitle: String?
    var taskId: String?
    var employeeRole: String?
    var chatPrompt: String?
    var collectionItemId: String? = nil
}

struct IntentionCard: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var icon: String
    var kind: String
    var action: IntentionAction
    var rationale: String? = nil
}

struct IntentionToday: Codable, Equatable {
    var vitalHint: String = ""
    var vitalityMode: String = "steady"
    var cards: [IntentionCard] = []
    var generatedAt: Double = 0
    var selectedId: String?
    var dismissedIds: [String] = []
}

struct DashboardData: Codable, Equatable {
    var brief: String = ""
    var briefAt: Double = 0
    var events: [ScheduleEvent] = []
    var tasks: [WorkTask] = []
    var apps: [AppProject] = []
}
