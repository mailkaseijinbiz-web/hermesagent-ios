import SwiftUI
import QuickLook

/// 社員の詳細管理（概要 / タスク / 成果物 / ファイル）。Mac ハブ経由でデータ取得。
/// ワークスペースのパスは端末ローカルのため iOS には出さない（フォルダ名と一覧のみ・読み取り専用）。
struct EmployeeDetailView: View {
    @EnvironmentObject private var appState: AppState
    let employeeId: String
    @State private var tab: Tab = .overview

    // Files tab state
    @State private var previewURL: URL?
    @State private var downloadingPath: String?
    @State private var browseStack: [(dirName: String, path: String, files: [EmployeeFile])] = []
    @State private var browseFiles: [EmployeeFile] = []
    @State private var browseLoading = false

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
        .quickLookPreview($previewURL)
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
            VStack(alignment: .leading, spacing: 0) {
                if let blurb = emp?.blurb, !blurb.isEmpty {
                    Text(blurb)
                        .font(.system(.body))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    Divider().padding(.vertical, 12)
                }

                overviewBulletRow("未着手 \(appState.employeeTasks.filter { $0.status == .todo }.count) 件")
                overviewBulletRow("対応中 \(appState.employeeTasks.filter { $0.status == .doing }.count) 件")
                overviewBulletRow("完了 \(appState.employeeTasks.filter { $0.status == .done }.count) 件")
                overviewBulletRow("成果物 \(appState.employeeArtifacts.count) 件")
                overviewBulletRow("ファイル \(appState.employeeFiles.count) 件")

                if let m = emp?.model, !m.isEmpty {
                    overviewBulletRow("モデル \(m)")
                }
                if appState.employeeHasWorkspace {
                    overviewBulletRow("作業フォルダ \(appState.employeeWorkspaceName)")
                }
            }
            .padding(16)
        }
    }

    private func overviewBulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("・")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.system(.body))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
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

    // MARK: Files

    private var filesTab: some View {
        List {
            if !appState.employeeHasWorkspace {
                Text("作業フォルダが設定されていません")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                // パンくずリスト（ルート + スタック）
                if !browseStack.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Button(appState.employeeWorkspaceName) { popToRoot() }
                                    .font(.caption).foregroundStyle(Color.accentColor)
                                ForEach(browseStack.indices, id: \.self) { i in
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    let isLast = i == browseStack.count - 1
                                    Button(browseStack[i].dirName) { popTo(i) }
                                        .font(.caption)
                                        .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                let displayFiles = browseStack.isEmpty ? appState.employeeFiles : browseFiles
                let sectionTitle = browseStack.last?.dirName ?? appState.employeeWorkspaceName

                Section(sectionTitle) {
                    if browseLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if displayFiles.isEmpty {
                        Text("ファイルがありません").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(displayFiles) { f in
                        fileRow(f)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: tab) { _, newTab in
            if newTab == .files { resetBrowse() }
        }
    }

    @ViewBuilder
    private func fileRow(_ f: EmployeeFile) -> some View {
        let isDownloading = downloadingPath == f.displayPath
        Button {
            Task { await openItem(f) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if f.isDir {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Image(systemName: fileIcon(f.name))
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    if isDownloading {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .frame(width: 28)

                Text(f.name).lineLimit(1).foregroundStyle(.primary)
                Spacer()
                if f.isDir {
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(f.sizeLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDownloading)
    }

    private func openItem(_ f: EmployeeFile) async {
        guard f.displayPath.isEmpty == false else { return }
        if f.isDir {
            browseLoading = true
            do {
                let resp = try await appState.apiClient.fetchEmployeeDir(
                    employeeId: employeeId, path: f.displayPath)
                browseStack.append((dirName: f.name, path: f.displayPath, files: resp.files))
                browseFiles = resp.files
            } catch {}
            browseLoading = false
        } else {
            downloadingPath = f.displayPath
            do {
                let url = try await appState.apiClient.downloadEmployeeFile(
                    employeeId: employeeId, path: f.displayPath)
                previewURL = url
            } catch {}
            downloadingPath = nil
        }
    }

    private func popToRoot() {
        browseStack.removeAll()
        browseFiles = []
    }

    private func popTo(_ index: Int) {
        browseFiles = browseStack[index].files
        browseStack = Array(browseStack.prefix(index + 1))
    }

    private func resetBrowse() {
        browseStack.removeAll()
        browseFiles = []
        downloadingPath = nil
    }

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":                         return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "mp4", "mov", "avi":           return "video"
        case "mp3", "wav", "m4a":           return "music.note"
        case "zip", "tar", "gz":            return "doc.zipper"
        case "swift", "py", "js", "ts", "rb", "sh": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt":                   return "doc.text"
        default:                            return "doc"
        }
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
