import Foundation

/// 夜の振り返り — ユーザーが確定した「今日のひとこと」+ 任意の AI 振り返り。
struct DayEveningReflection: Codable, Equatable {
    var pickedItemId: String
    var pickedLabel: String
    var pickedDetail: String
    var feelingText: String
    var oneLiner: String
    var aiReflection: String?
    var completedAt: Date
    var aiSource: String
    var feedbackThumb: String?
    var feedbackComment: String?
}

enum EveningReflectionLogic {
    static func fallbackOneLiner(pickedLabel: String, feeling: String) -> String {
        let label = pickedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let feel = feeling.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { return feel }
        if feel.isEmpty { return label }
        return "\(label)。\(feel)"
    }

    static func fallbackAiReflection(pickedLabel: String, feeling: String, dayHint: String? = nil) -> String {
        let label = pickedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let feel = feeling.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences: [String] = []
        if !feel.isEmpty, !label.isEmpty {
            sentences.append("\(label)のとき、「\(feel)」と感じた一日。")
        } else if !label.isEmpty {
            sentences.append("\(label)が印象に残った一日。")
        } else if !feel.isEmpty {
            sentences.append("\(feel)")
        }
        if let hint = dayHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            sentences.append(hint)
        }
        return sentences.joined(separator: " ")
    }
}

extension LifeLogItem {
    var isPickableForReflection: Bool {
        switch self {
        case .macSummary: return false
        default: return true
        }
    }

    var reflectionLabel: String {
        switch self {
        case .visit(let v, _): return v.name
        case .mobility(let m): return m.label
        case .memo(let m): return m.timelineLabel
        case .mac(let a): return MacWorkFocus.workTitle(for: a)
        case .macSummary: return "Mac作業"
        case .photo(let p): return p.label.isEmpty ? "写真" : p.label
        case .macSnapshot(let label, _, _): return label
        }
    }

    var reflectionDetail: String {
        switch self {
        case .visit(let v, let dur):
            if let d = dur, d >= 60 {
                return MobilityTotals.formatDuration(d)
            }
            return v.name
        case .mobility(let m): return m.detail
        case .memo(let m): return m.timelineDetail
        case .mac(let a):
            return MacWorkFocus.subtitle(for: a) ?? MacActivitySummarizer.formatDuration(a.duration)
        case .macSummary(let s):
            return s.apps.prefix(2).map(\.workTitle).joined(separator: " · ")
        case .photo(let p): return p.label
        case .macSnapshot(_, let detail, _): return detail
        }
    }
}
