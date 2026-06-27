import SwiftUI

/// ホーム：あいさつ・デイリーブリーフ・今日の予定・対応中タスク・アプリ概要。
/// Mac ハブの /api/dashboard から取得（薄いクライアント）。
struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var loading = false

    private var d: DashboardData { appState.dashboard }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                greeting

                if !d.brief.isEmpty {
                    card(title: "デイリーブリーフ", systemImage: "sparkles") {
                        Text(d.brief)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        if d.briefAt > 0 {
                            Text(briefTime).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                card(title: "今日の予定", systemImage: "calendar", count: d.events.count) {
                    if d.events.isEmpty {
                        emptyLine("今日の予定はありません")
                    } else {
                        ForEach(d.events.prefix(6)) { e in eventRow(e) }
                    }
                }

                card(title: "対応中のタスク", systemImage: "checklist", count: d.tasks.count) {
                    if d.tasks.isEmpty {
                        emptyLine("未着手/対応中のタスクはありません")
                    } else {
                        ForEach(d.tasks.prefix(6)) { t in taskRow(t) }
                    }
                }

                card(title: "アプリ", systemImage: "hammer", count: d.apps.count) {
                    if d.apps.isEmpty {
                        emptyLine("アプリはまだありません")
                    } else {
                        ForEach(d.apps.prefix(6)) { a in appRow(a) }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("ダッシュボード")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.fetchDashboard() }
        .task { await appState.fetchDashboard() }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greetingText).font(.system(.title2, weight: .bold))
            Text("今日のまとめ").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var greetingText: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "おはようございます"
        case 11..<17: return "こんにちは"
        default: return "こんばんは"
        }
    }

    private var briefTime: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M月d日 HH:mm 更新"
        return f.string(from: Date(timeIntervalSince1970: d.briefAt))
    }

    private func eventRow(_ e: ScheduleEvent) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(e.isGoogle ? Color.red : Color.accentColor).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(e.timeLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if e.isGoogle { Image(systemName: "g.circle").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func taskRow(_ t: WorkTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: t.status.icon).font(.system(size: 13)).foregroundStyle(t.status.color)
            Text(t.title).font(.system(size: 13)).lineLimit(1)
            Spacer()
            if let emoji = t.assigneeEmoji { Text(emoji).font(.caption) }
        }
    }

    private func appRow(_ a: AppProject) -> some View {
        HStack(spacing: 10) {
            Text(a.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            Text(a.status.title).font(.caption2)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(a.status.color.opacity(0.15)).foregroundStyle(a.status.color).cornerRadius(6)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
    }

    @ViewBuilder
    private func card<Content: View>(title: String, systemImage: String, count: Int? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(.tint)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let count = count, count > 0 {
                    Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
