import SwiftUI

/// Gmail 受信トレイ（Mac ハブ経由）。スレッド一覧 → タップで本文。作成して送信も可能。
struct GmailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var search = ""
    @State private var selected: GmailThreadSummary? = nil
    @State private var showCompose = false

    private var filtered: [GmailThreadSummary] {
        guard !search.isEmpty else { return appState.gmailThreads }
        let q = search.lowercased()
        return appState.gmailThreads.filter {
            $0.subject.lowercased().contains(q) || $0.from.lowercased().contains(q) || $0.snippet.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if appState.gmailThreads.isEmpty && !appState.isLoadingGmail {
                Text("受信トレイは空です（または Google 未接続）")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(filtered) { t in
                NavigationLink {
                    GmailThreadView(summary: t).environmentObject(appState)
                } label: { row(t) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .navigationTitle("Gmail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .overlay {
            if appState.isLoadingGmail && appState.gmailThreads.isEmpty { ProgressView() }
        }
        .sheet(isPresented: $showCompose) {
            NavigationStack { GmailComposeView().environmentObject(appState) }
        }
        .task { await appState.fetchGmail() }
        .refreshable { await appState.fetchGmail() }
    }

    private func row(_ t: GmailThreadSummary) -> some View {
        HStack(spacing: 10) {
            Circle().fill(t.hasUnread ? Color.accentColor : .clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(t.senderName).font(.system(size: 13, weight: t.hasUnread ? .semibold : .regular)).lineLimit(1)
                    Spacer()
                    Text(t.relativeDate).font(.caption2).foregroundStyle(.secondary)
                }
                Text(t.subject).font(.system(size: 13, weight: t.hasUnread ? .medium : .regular)).lineLimit(1)
                Text(t.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct GmailThreadView: View {
    @EnvironmentObject private var appState: AppState
    let summary: GmailThreadSummary
    @State private var detail: GmailThreadDetail?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(detail?.subject ?? summary.subject)
                    .font(.system(.title3, weight: .semibold))
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if let messages = detail?.messages {
                    ForEach(messages) { m in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(Color.accentColor.opacity(0.2)).frame(width: 30, height: 30)
                                    Text(String(m.senderName.prefix(1)).uppercased())
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tint)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.senderName).font(.system(size: 13, weight: .semibold))
                                    Text(m.displayDate).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            Text(m.body.isEmpty ? m.snippet : m.body)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        Divider()
                    }
                }
            }
        }
        .navigationTitle("メール")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            detail = await appState.loadGmailThread(summary.id)
            loading = false
        }
    }
}

struct GmailComposeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var subject = ""
    @State private var body_ = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("宛先", text: $to).keyboardType(.emailAddress).autocapitalization(.none)
                TextField("件名", text: $subject)
            }
            Section {
                TextField("本文", text: $body_, axis: .vertical).lineLimit(6...20)
            }
            if let error = error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle("新規メッセージ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sending = true; error = nil
                    Task {
                        let ok = await appState.sendGmail(to: to, subject: subject, body: body_)
                        sending = false
                        if ok { dismiss() } else { error = "送信に失敗しました" }
                    }
                } label: {
                    if sending { ProgressView() } else { Text("送信") }
                }
                .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            }
        }
    }
}
