import SwiftUI

/// Mobile automations (cron) management — list / create / pause-resume / delete,
/// backed by the Mac's /api/cron endpoints.
struct AutomationsView: View {
    @EnvironmentObject var appState: AppState

    @State private var schedule = ""
    @State private var prompt = ""
    @State private var name = ""
    @State private var deliver = "local"
    @State private var noAgent = false
    @State private var creating = false

    private var canCreate: Bool {
        !schedule.trimmingCharacters(in: .whitespaces).isEmpty && !creating
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
                TextField("スケジュール (例: 0 9 * * *, 30m, every 2h)", text: $schedule)
                    .autocorrectionDisabled()
                TextField("プロンプト (例: 今日の天気を調べて送信)", text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
                TextField("タスク名 (任意)", text: $name)
                TextField("配信先 (例: local, telegram, line:ID)", text: $deliver)
                    .autocorrectionDisabled()
                Toggle("LLMを介さずスクリプト実行 (--no-agent)", isOn: $noAgent)

                Button {
                    Task {
                        creating = true
                        let ok = await appState.createCron(schedule: schedule, prompt: prompt,
                                                           name: name, deliver: deliver, script: "", noAgent: noAgent)
                        creating = false
                        if ok { schedule = ""; prompt = ""; name = "" }
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
