import SwiftUI

/// Mobile automations (cron) management — list / create / pause-resume / delete,
/// backed by the Mac's /api/cron endpoints.
struct AutomationsView: View {
    @EnvironmentObject var appState: AppState

    @State private var schedule = ""
    @State private var prompt = ""
    @State private var name = ""
    @State private var deliverPlatform = "local"
    @State private var channelId = ""
    @State private var noAgent = false
    @State private var creating = false

    private struct SchedulePreset: Identifiable {
        let id: String
        let label: String
        let cron: String
    }

    private static let schedulePresets: [SchedulePreset] = [
        .init(id: "daily-9", label: "毎日 9:00", cron: "0 9 * * *"),
        .init(id: "weekdays-830", label: "平日 8:30", cron: "30 8 * * 1-5"),
        .init(id: "mon-10", label: "毎週月曜 10:00", cron: "0 10 * * 1"),
        .init(id: "hourly", label: "毎時", cron: "0 * * * *"),
        .init(id: "30m", label: "30分ごと", cron: "30m"),
    ]

    private struct DeliverOption: Identifiable {
        let id: String
        let label: String
        let value: String
    }

    private static let deliverOptions: [DeliverOption] = [
        .init(id: "local", label: "ローカル（アプリ内のみ）", value: "local"),
        .init(id: "origin", label: "送信元へ返信", value: "origin"),
        .init(id: "telegram", label: "Telegram", value: "telegram"),
        .init(id: "line", label: "LINE", value: "line"),
    ]

    private var canCreate: Bool {
        !schedule.trimmingCharacters(in: .whitespaces).isEmpty && !creating
    }

    private var deliverValue: String {
        switch deliverPlatform {
        case "telegram", "line":
            let id = channelId.trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? deliverPlatform : "\(deliverPlatform):\(id)"
        default:
            return deliverPlatform
        }
    }

    private var needsChannelId: Bool {
        deliverPlatform == "telegram" || deliverPlatform == "line"
    }

    var body: some View {
        List {
            if let banner = appState.cronJobErrorBanner {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(banner)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                        Button {
                            appState.cronJobErrorBanner = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("スケジュールされたタスク") {
                if appState.cronJobs.isEmpty {
                    Text(appState.isLoadingCron ? "読み込み中…" : "ジョブはありません")
                        .font(.system(.subheadline, weight: .light))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.cronJobs) { job in
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(job.isActive ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.name.isEmpty ? job.id : job.name)
                                    .font(.system(.body, weight: .medium))
                                Text("\(job.schedule) · \(job.deliver)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !job.nextRun.isEmpty {
                                    Text("次回: \(job.nextRun)").font(.caption2).foregroundStyle(.tertiary)
                                }
                                if let err = job.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !err.isEmpty {
                                    Text(truncatedCronError(err))
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { job.isActive },
                                set: { _ in Task { await appState.toggleCron(job) } }))
                                .labelsHidden()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await appState.deleteCron(job) }
                            } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                }
            }

            Section("新しいタスクを作成") {
                Menu {
                    ForEach(Self.schedulePresets) { preset in
                        Button(preset.label) { schedule = preset.cron }
                    }
                } label: {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text("プリセットから選ぶ")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                TextField("スケジュール (例: 0 9 * * *, 30m, every 2h)", text: $schedule)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                TextField("プロンプト (例: 今日の天気を調べて送信)", text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
                TextField("タスク名 (任意)", text: $name)

                Picker("配信先", selection: $deliverPlatform) {
                    ForEach(Self.deliverOptions) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)

                if needsChannelId {
                    TextField("チャンネルID (例: Uabc…)", text: $channelId)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                }

                Toggle("LLMを介さずスクリプト実行 (--no-agent)", isOn: $noAgent)

                Button {
                    Task {
                        creating = true
                        let ok = await appState.createCron(schedule: schedule, prompt: prompt,
                                                           name: name, deliver: deliverValue, script: "", noAgent: noAgent)
                        creating = false
                        if ok {
                            schedule = ""
                            prompt = ""
                            name = ""
                            deliverPlatform = "local"
                            channelId = ""
                        }
                    }
                } label: {
                    HStack {
                        if creating { ProgressView().controlSize(.small) }
                        Text("タスクを作成")
                    }
                }
                .disabled(!canCreate)
            }

            if !appState.isConnected {
                Text("Macに接続されていないため、操作できません。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .navigationTitle("オートメーション")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await appState.fetchCronJobs() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { await appState.fetchCronJobs() }
        .task { await appState.fetchCronJobs() }
    }

    private func truncatedCronError(_ err: String) -> String {
        let maxLen = 120
        guard err.count > maxLen else { return err }
        return String(err.prefix(maxLen)) + "…"
    }
}
