import SwiftUI

/// 「ニュース」ページ。開いている会話の最新アシスタント出力を構造化（カード/要約/タイムライン/テーブル）して表示。
struct NewsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var mode: OutputViewMode = .news

    private var entries: [NewsEntry] { appState.latestAssistantEntries }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if entries.isEmpty {
                    emptyState
                } else {
                    Picker("", selection: $mode) {
                        ForEach(OutputViewMode.structuredCases) { m in
                            Label(m.label, systemImage: m.icon).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if let emp = appState.activeEmployee {
                        HStack(spacing: 6) {
                            Text(emp.emoji)
                            Text(emp.name).font(.system(.subheadline, weight: .semibold))
                            Text("·  \(entries.count)件").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    StructuredOutputContainer(entries: entries, mode: mode)
                }
            }
            .padding(16)
        }
        .navigationTitle("ニュース")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper").font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("まだニュースがありません")
                .font(.system(.subheadline, weight: .semibold))
            Text("リサーチャー社員に「AI Techニュースを収集して」と話しかけると、収集結果がここにまとまります。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}
