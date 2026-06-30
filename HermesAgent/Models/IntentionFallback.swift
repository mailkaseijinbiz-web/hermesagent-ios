import Foundation

/// On-device intention cards when the Mac hub is unreachable.
enum IntentionFallback {

    static func build(
        sleepHours: Double,
        steps: Int,
        exerciseMinutes: Int,
        mindfulMinutes: Int,
        restingHR: Int,
        locationSummary: String,
        likes: String,
        goals: String,
        pendingTasks: [WorkTask],
        dismissedKinds: [String] = []
    ) -> IntentionToday {
        let mode = vitalityMode(sleep: sleepHours, exercise: exerciseMinutes, mindful: mindfulMinutes)
        let hint = hintLine(sleep: sleepHours, steps: steps, exercise: exerciseMinutes,
                            mindful: mindfulMinutes, restingHR: restingHR, mode: mode)
        var cards: [IntentionCard] = []
        let hour = Calendar.current.component(.hour, from: Date())

        if (mode == "depleted" || mode == "recovering"), !dismissedKinds.contains("recover") {
            cards.append(IntentionCard(
                id: "local-recover", title: "軽く回復", subtitle: hour >= 18 ? "早めに休む" : "散歩15分",
                icon: "leaf.fill", kind: "recover",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        } else if let top = pendingTasks.first, !dismissedKinds.contains("focus") {
            cards.append(IntentionCard(
                id: "local-focus-\(top.id)", title: "今日の1つ", subtitle: top.title,
                icon: "checklist", kind: "focus",
                action: IntentionAction(type: "markTask", taskTitle: nil, taskId: top.id,
                                       employeeRole: "engineer", chatPrompt: nil)
            ))
        }

        if likes.contains("サウナ"), !dismissedKinds.contains("explore") {
            cards.append(IntentionCard(
                id: "local-sauna", title: "サウナで整える", subtitle: "好きなことを",
                icon: "flame.fill", kind: "explore",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        } else if !locationSummary.isEmpty, !dismissedKinds.contains("explore") {
            cards.append(IntentionCard(
                id: "local-out", title: "外の空気", subtitle: "いまの足あとから",
                icon: "figure.walk", kind: "explore",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        }

        if !dismissedKinds.contains("rest") {
            cards.append(IntentionCard(
                id: "local-rest", title: "今日は休む", subtitle: "無理しない",
                icon: "moon.fill", kind: "rest",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        }

        let filtered = cards.filter { !dismissedKinds.contains($0.kind) }
        return IntentionToday(
            vitalHint: hint + "（オフライン）",
            vitalityMode: mode,
            cards: Array(filtered.prefix(3)),
            generatedAt: Date().timeIntervalSince1970
        )
    }

    private static func vitalityMode(sleep: Double, exercise: Int, mindful: Int) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if sleep > 0 && sleep < 5 { return exercise >= 20 ? "recovering" : "depleted" }
        if sleep > 0 && sleep < 6, hour < 11 { return "recovering" }
        if sleep >= 7, hour >= 9, hour < 16, exercise >= 30 { return "peak" }
        if hour >= 22 || hour < 6 { return "recovering" }
        if mindful >= 10 { return "steady" }
        return "steady"
    }

    private static func hintLine(sleep: Double, steps: Int, exercise: Int, mindful: Int,
                                 restingHR: Int, mode: String) -> String {
        var parts: [String] = []
        if sleep > 0 { parts.append(String(format: "睡眠 %.1fh", sleep)) }
        if restingHR > 0 { parts.append("安静 \(restingHR)bpm") }
        if exercise > 0 { parts.append("運動 \(exercise)分") }
        if mindful > 0 { parts.append("マインドフル \(mindful)分") }
        if steps > 0 { parts.append("\(steps)歩") }
        let label: String = {
            switch mode {
            case "depleted": return "消耗気味"
            case "recovering": return "回復モード"
            case "peak": return "集中向き"
            default: return "安定"
            }
        }()
        return parts.isEmpty ? label : parts.joined(separator: " · ") + " — \(label)"
    }
}
