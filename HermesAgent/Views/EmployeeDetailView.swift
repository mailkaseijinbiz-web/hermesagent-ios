import SwiftUI

/// 社員の詳細管理（概要 / タスク / 成果物 / ファイル）。Mac ハブ経由でデータ取得。
/// ワークスペースのパスは端末ローカルのため iOS には出さない（フォルダ名と一覧のみ・読み取り専用）。
struct EmployeeDetailView: View {
    @EnvironmentObject private var appState: AppState
    let employeeId: String
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "概要", tasks = "タスク", artifacts = "成果物", files = "ファイル"
        var id: String { rawValue }
    }

    private var emp: MobileEmployee? { appState.employees.first { $0.id == employeeId } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)

            switch tab {
            case .overview:  overviewTab
            case .tasks:     tasksTab
            case .artifacts: artifactsTab
            case .files:     filesTab
            }
        }
        .navigationTitle(emp?.name ?? "社員")
        .navigationBarTitleDisplayMode(.inline)
        .task { await appState.fetchEmployeeDetail(employeeId) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: emp?.accent ?? "888888").opacity(0.18)).frame(width: 46, height: 46)
                Text(emp?.emoji ?? "👤").font(.system(size: 22))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(emp?.name ?? "—").font(.system(.headline))
                Text(emp?.roleTitle ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.switchEmployee(employeeId)
            } label: {
                Label("話す", systemImage: "bubble.left").font(.caption)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: Overview
    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    stat("未着手", appState.employeeTasks.filter { $0.status == .todo }.count, .secondary)
                    stat("対応中", appState.employeeTasks.filter { $0.status == .doing }.count, .orange)
                    stat("完了", appState.employeeTasks.filter { $0.status == .done }.count, .green)
                }
                HStack(spacing: 10) {
                    stat("成果物", appState.employeeArtifacts.count, .accentColor)
                    stat("ファイル", appState.employeeFiles.count, .blue)
                }
                if let m = emp?.model, !m.isEmpty {
                    infoRow("モデル", m)
                }
                if appState.employeeHasWorkspace {
                    infoRow("作業フォルダ", appState.employeeWorkspaceName)
                }
            }
            .padding(16)
        }
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(n)").font(.system(.title2, weight: .bold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(Color.primary.opacity(0.04)).cornerRadius(12)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption).lineLimit(1)
        }
        .padding(12).background(Color.primary.opacity(0.04)).cornerRadius(10)
    }

    // MARK: Tasks
    @State private var newTaskTitle = ""
    private var tasksTab: some View {
        List {
            Section {
                HStack {
                    TextField("新しいタスク", text: $newTaskTitle)
                    Button {
                        let t = newTaskTitle.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        newTaskTitle = ""
                        Task { await appState.createTask(title: t, assigneeId: employeeId) }
                    } label: { Image(systemName: "plus.circle.fill") }
                    .disabled(newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(TaskStatus.allCases) { status in
                let items = appState.employeeTasks.filter { $0.status == status }
                if !items.isEmpty {
                    Section(status.title) {
                        ForEach(items) { t in
                            HStack {
                                Image(systemName: t.status.icon).foregroundStyle(t.status.color)
                                Text(t.title)
                                Spacer()
                                Menu {
                                    ForEach(TaskStatus.allCases) { s in
                                        Button(s.title) { Task { await appState.setTaskStatus(t.id, s, employeeId: employeeId) } }
                                    }
                                    Divider()
                                    Button(role: .destructive) { Task { await appState.deleteTask(t.id, employeeId: employeeId) } } label: { Text("削除") }
                                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Artifacts
    @State private var showArtifactEditor = false
    private var artifactsTab: some View {
        List {
            if appState.employeeArtifacts.isEmpty {
                Text("成果物はまだありません").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(appState.employeeArtifacts) { a in
                HStack(spacing: 10) {
                    Image(systemName: a.kind.icon).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(.subheadline).lineLimit(1)
                        if a.kind != .file, !a.body.isEmpty {
                            Text(a.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if a.kind == .link, !a.body.isEmpty {
                        Button { if let u = URL(string: a.body) { UIApplication.shared.open(u) } } label: {
                            Image(systemName: "arrow.up.right.square")
                        }.buttonStyle(.borderless)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { Task { await appState.deleteArtifact(a.id, employeeId: employeeId) } } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showArtifactEditor = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showArtifactEditor) {
            NavigationStack { ArtifactEditSheet(employeeId: employeeId).environmentObject(appState) }
        }
    }

    // MARK: Files (read-only)
    private var filesTab: some View {
        List {
            if !appState.employeeHasWorkspace {
                Text("作業フォルダが設定されていません").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Section(appState.employeeWorkspaceName) {
                    if appState.employeeFiles.isEmpty {
                        Text("ファイルがありません").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(appState.employeeFiles) { f in
                        HStack {
                            Image(systemName: f.isDir ? "folder.fill" : "doc")
                                .foregroundStyle(f.isDir ? Color.accentColor : .secondary)
                            Text(f.name).lineLimit(1)
                            Spacer()
                            if !f.isDir { Text(f.sizeLabel).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct ArtifactEditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let employeeId: String

    @State private var kind: ArtifactKind = .note
    @State private var title = ""
    @State private var body_ = ""

    var body: some View {
        Form {
            Picker("種類", selection: $kind) {
                Text("メモ").tag(ArtifactKind.note)
                Text("リンク").tag(ArtifactKind.link)
            }
            TextField("タイトル", text: $title)
            TextField(kind == .link ? "URL" : "内容", text: $body_, axis: .vertical).lineLimit(3...8)
        }
        .navigationTitle("成果物を追加")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    Task {
                        await appState.addArtifact(employeeId: employeeId, title: title, kind: kind, body: body_)
                        dismiss()
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && body_.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
