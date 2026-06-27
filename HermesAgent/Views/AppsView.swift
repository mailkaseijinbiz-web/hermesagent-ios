import SwiftUI

/// アプリ案件一覧。Mac ハブの /api/apps から取得・作成・編集・削除。
/// 起動/開発などのネイティブ操作は Mac 専用のため iOS では行わない（一覧・管理のみ）。
struct AppsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editing: AppProject? = nil
    @State private var showCreate = false

    var body: some View {
        List {
            if appState.apps.isEmpty {
                Section {
                    Text("アプリはまだありません").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(appState.apps) { a in
                Button { editing = a } label: { row(a) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { Task { await appState.deleteApp(a.id) } } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("アプリ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack { AppEditSheet(existing: nil).environmentObject(appState) }
        }
        .sheet(item: $editing) { a in
            NavigationStack { AppEditSheet(existing: a).environmentObject(appState) }
        }
        .task { await appState.fetchApps() }
        .refreshable { await appState.fetchApps() }
    }

    private func row(_ a: AppProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(a.name).font(.system(.subheadline, weight: .semibold))
                Spacer()
                Text(a.status.title).font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(a.status.color.opacity(0.15)).foregroundStyle(a.status.color).cornerRadius(6)
            }
            if !a.detail.isEmpty {
                Text(a.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                if let emoji = a.assigneeEmoji, let name = a.assigneeName {
                    Text("\(emoji) \(name)").font(.caption2).foregroundStyle(.secondary)
                }
                if !a.folderName.isEmpty {
                    Label(a.folderName, systemImage: "folder").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppEditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existing: AppProject?

    @State private var name: String
    @State private var detail: String
    @State private var status: AppStatus
    @State private var assigneeId: String?
    @State private var previewURL: String
    @State private var runCommand: String

    init(existing: AppProject?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _detail = State(initialValue: existing?.detail ?? "")
        _status = State(initialValue: existing?.status ?? .idea)
        _assigneeId = State(initialValue: existing?.assigneeId)
        _previewURL = State(initialValue: existing?.previewURL ?? "")
        _runCommand = State(initialValue: existing?.runCommand ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("名前", text: $name)
                TextField("説明", text: $detail, axis: .vertical).lineLimit(2...5)
            }
            Section {
                Picker("ステータス", selection: $status) {
                    ForEach(AppStatus.allCases) { s in Text(s.title).tag(s) }
                }
                if !appState.employees.isEmpty {
                    Picker("担当", selection: $assigneeId) {
                        Text("なし").tag(String?.none)
                        ForEach(appState.sortedEmployees) { e in Text("\(e.emoji) \(e.name)").tag(String?.some(e.id)) }
                    }
                }
            }
            Section("詳細") {
                TextField("プレビューURL", text: $previewURL)
                TextField("起動コマンド", text: $runCommand)
            }
        }
        .navigationTitle(existing == nil ? "アプリを追加" : "アプリを編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        Task {
            if let a = existing {
                let fields: [String: Any] = ["name": name, "detail": detail, "status": status.rawValue,
                                             "previewURL": previewURL, "runCommand": runCommand,
                                             "assigneeId": assigneeId ?? NSNull()]
                await appState.updateApp(a.id, fields: fields)
            } else {
                await appState.createApp(name: name, detail: detail, assigneeId: assigneeId,
                                         previewURL: previewURL, runCommand: runCommand)
            }
            dismiss()
        }
    }
}
