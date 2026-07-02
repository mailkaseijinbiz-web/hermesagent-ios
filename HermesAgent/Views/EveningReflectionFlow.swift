import SwiftUI

/// 夜の振り返り — 選ぶ → 1問 → AI/フォールバック → 確定 → フィードバック（v2: AI振り返り・編集）。
struct EveningReflectionFlow: View {
    @ObservedObject var appState: AppState
    @ObservedObject var lifeLog: LifeLogStore
    let timelineItems: [LifeLogItem]
    let trigger: String
    var editingReflection: DayEveningReflection?
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .pick
    @State private var pickedItem: LifeLogItem?
    @State private var feelingText = ""
    @State private var draftOneLiner = ""
    @State private var draftAiReflection = ""
    @State private var aiSource = "fallback"
    @State private var isGenerating = false
    @State private var feedbackThumb: String?
    @State private var feedbackComment = ""
    @State private var preserveCompletedAt = Date()

    private enum Step { case pick, feeling, draft, feedback }

    private var isEditing: Bool { editingReflection != nil }

    private var pickableItems: [LifeLogItem] {
        timelineItems.filter(\.isPickableForReflection)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .pick: pickStep
                case .feeling: feelingStep
                case .draft: draftStep
                case .feedback: feedbackStep
                }
            }
            .navigationTitle(isEditing ? "振り返りを編集" : "今夜の振り返り")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .onAppear {
            if let existing = editingReflection {
                prefill(from: existing)
                appState.trackProductMetric(name: "evening_reflect.reopened", props: ["trigger": trigger])
            } else {
                appState.trackProductMetric(name: "evening_reflect.started", props: ["trigger": trigger])
                if pickableItems.isEmpty {
                    step = .feeling
                }
            }
        }
    }

    private func prefill(from existing: DayEveningReflection) {
        feelingText = existing.feelingText
        draftOneLiner = existing.oneLiner
        draftAiReflection = existing.aiReflection ?? ""
        aiSource = existing.aiSource
        feedbackThumb = existing.feedbackThumb
        feedbackComment = existing.feedbackComment ?? ""
        preserveCompletedAt = existing.completedAt
        if let item = pickableItems.first(where: { $0.id == existing.pickedItemId }) {
            pickedItem = item
        }
        step = .draft
    }

    private var pickStep: some View {
        List {
            Section {
                Text("今日いちばん残したい記録を選んでください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("今日のできごと") {
                ForEach(pickableItems) { item in
                    Button {
                        pickedItem = item
                        appState.trackProductMetric(name: "evening_reflect.picked", props: [
                            "kind": reflectionKind(item),
                        ])
                        step = .feeling
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.reflectionLabel)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(item.reflectionDetail)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var feelingStep: some View {
        Form {
            if let item = pickedItem {
                Section("選んだ記録") {
                    Text(item.reflectionLabel)
                    Text(item.reflectionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("そのとき、どう感じましたか？") {
                TextField("1文で", text: $feelingText, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Button("次へ") {
                    Task { await generateDraft() }
                }
                .disabled(feelingText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
        }
        .overlay {
            if isGenerating {
                ProgressView("今日のひとことを考えています…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var draftStep: some View {
        Form {
            Section("今日のひとこと") {
                TextField("編集できます", text: $draftOneLiner, axis: .vertical)
                    .lineLimit(2...5)
                if aiSource == "fallback" && !appState.isConnected {
                    Text("Mac に接続すると AI がより自然な文を提案します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !draftAiReflection.isEmpty {
                Section {
                    HStack {
                        Text("Hermesの振り返り")
                            .font(.subheadline)
                        Spacer()
                        Text("AI")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(draftAiReflection)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                }
            }
            Section {
                Button(isEditing ? "更新して保存" : "この内容で保存") {
                    saveReflection()
                    if isEditing || feedbackThumb != nil {
                        dismiss()
                    } else {
                        step = .feedback
                    }
                }
                .disabled(draftOneLiner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var feedbackStep: some View {
        Form {
            Section("今夜の振り返り、どうでしたか？") {
                HStack(spacing: 24) {
                    feedbackButton(thumb: "up", icon: "hand.thumbsup")
                    feedbackButton(thumb: "down", icon: "hand.thumbsdown")
                }
                .frame(maxWidth: .infinity)
                TextField("コメント（任意）", text: $feedbackComment, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Button("完了") {
                    submitFeedback()
                    dismiss()
                }
            }
        }
    }

    private func feedbackButton(thumb: String, icon: String) -> some View {
        Button {
            feedbackThumb = thumb
        } label: {
            Image(systemName: icon + (feedbackThumb == thumb ? ".fill" : ""))
                .font(.system(size: 28))
                .foregroundStyle(feedbackThumb == thumb ? LifeLogBookPalette.accentWarm : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func generateDraft() async {
        isGenerating = true
        defer { isGenerating = false }
        appState.trackProductMetric(name: "evening_reflect.answered")

        let label = pickedItem?.reflectionLabel ?? editingReflection?.pickedLabel ?? "今日"
        let detail = pickedItem?.reflectionDetail ?? editingReflection?.pickedDetail ?? ""
        let feeling = feelingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let dayHint = LifeLogOneLiner.compose(items: timelineItems, metrics: DayHealthMetrics())

        if appState.isConnected,
           let result = try? await appState.apiClient.generateEveningReflection(
            pickedLabel: label,
            pickedDetail: detail,
            feelingText: feeling
           ), !result.oneLiner.isEmpty {
            draftOneLiner = result.oneLiner
            draftAiReflection = result.aiReflection ?? ""
            aiSource = "mac"
            appState.trackProductMetric(name: "evening_reflect.summary_generated", props: ["source": "mac"])
        } else {
            draftOneLiner = EveningReflectionLogic.fallbackOneLiner(pickedLabel: label, feeling: feeling)
            draftAiReflection = EveningReflectionLogic.fallbackAiReflection(
                pickedLabel: label,
                feeling: feeling,
                dayHint: dayHint
            )
            aiSource = "fallback"
            appState.trackProductMetric(name: "evening_reflect.summary_generated", props: ["source": "fallback"])
        }
        step = .draft
    }

    private func saveReflection() {
        let label = pickedItem?.reflectionLabel ?? editingReflection?.pickedLabel ?? "今日"
        let detail = pickedItem?.reflectionDetail ?? editingReflection?.pickedDetail ?? ""
        let reflection = DayEveningReflection(
            pickedItemId: pickedItem?.id ?? editingReflection?.pickedItemId ?? "none",
            pickedLabel: label,
            pickedDetail: detail,
            feelingText: feelingText.trimmingCharacters(in: .whitespacesAndNewlines),
            oneLiner: draftOneLiner.trimmingCharacters(in: .whitespacesAndNewlines),
            aiReflection: draftAiReflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : draftAiReflection.trimmingCharacters(in: .whitespacesAndNewlines),
            completedAt: isEditing ? preserveCompletedAt : Date(),
            aiSource: aiSource,
            feedbackThumb: feedbackThumb,
            feedbackComment: feedbackComment.isEmpty ? nil : feedbackComment
        )
        lifeLog.saveEveningReflection(reflection, for: Date())
        EveningReflectionScheduler.reschedule(completedToday: true)
        appState.refreshMorningReflectionSchedule()
        appState.trackProductMetric(
            name: isEditing ? "evening_reflect.reedited" : "evening_reflect.saved",
            props: ["source": aiSource]
        )
        Task {
            await appState.syncEveningReflectionToMac(reflection, for: Date())
        }
    }

    private func submitFeedback() {
        lifeLog.updateEveningReflectionFeedback(
            for: Date(),
            thumb: feedbackThumb,
            comment: feedbackComment.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var props: [String: String] = [:]
        if let thumb = feedbackThumb { props["thumb"] = thumb }
        if !feedbackComment.isEmpty { props["has_comment"] = "1" }
        appState.trackProductMetric(name: "evening_reflect.feedback", props: props)
    }

    private func reflectionKind(_ item: LifeLogItem) -> String {
        switch item {
        case .visit: return "visit"
        case .mobility: return "mobility"
        case .memo: return "memo"
        case .mac: return "mac"
        case .macSummary: return "mac_summary"
        case .photo: return "photo"
        case .macSnapshot: return "mac_snapshot"
        }
    }
}
