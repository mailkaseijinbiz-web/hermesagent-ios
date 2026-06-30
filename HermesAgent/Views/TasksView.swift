import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingCreate = false
    @State private var newTitle = ""
    @State private var newAssigneeId: String? = nil
    @FocusState private var createFocused: Bool

    private var grouped: [(TaskStatus, [WorkTask])] {
        TaskStatus.allCases.compactMap { status in
            let items = appState.allTasks.filter { $0.status == status }
            return items.isEmpty ? nil : (status, items)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if appState.allTasks.isEmpty {
                    emptyState
                } else {
                    ForEach(grouped, id: \.0) { status, tasks in
                        taskGroup(status: status, tasks: tasks)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("タスク")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .light))
                }
            }
        }
        .sheet(isPresented: $showingCreate) { createSheet }
        .refreshable { await appState.fetchTasks() }
        .task { await appState.fetchTasks() }
    }

    // MARK: - グループ

    private func taskGroup(status: TaskStatus, tasks: [WorkTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status.color)
                Text(status.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(tasks.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 2)

            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    taskRow(task)
                    if task.id != tasks.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    // MARK: - タスク行

    private func taskRow(_ task: WorkTask) -> some View {
        HStack(spacing: 12) {
            // ステータス切替ボタン
            Button {
                let next: TaskStatus = task.status == .todo ? .doing : (task.status == .doing ? .done : .todo)
                Task { await appState.setTaskStatus(task.id, next) }
            } label: {
                Image(systemName: task.status.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(task.status.color)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(.body, weight: .light))
                    .foregroundStyle(.primary)
                    .strikethrough(task.status == .done, color: .secondary)
                    .lineLimit(2)
                if let emoji = task.assigneeEmoji, let name = task.assigneeName {
                    Text("\(emoji) \(name)")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await appState.deleteTask(task.id) }
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - 空状態

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 60)
            Image(systemName: "checklist")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("タスクはありません")
                .font(.system(.title3, weight: .light))
                .foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 新規作成シート

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("タスク名", text: $newTitle)
                        .focused($createFocused)
                }
                if !appState.employees.isEmpty {
                    Section("担当") {
                        Picker("担当社員", selection: $newAssigneeId) {
                            Text("なし").tag(String?.none)
                            ForEach(appState.sortedEmployees) { e in
                                Text("\(e.emoji) \(e.name)").tag(String?.some(e.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("タスクを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        showingCreate = false
                        newTitle = ""
                        newAssigneeId = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("追加") {
                        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        showingCreate = false
                        newTitle = ""
                        let aid = newAssigneeId
                        newAssigneeId = nil
                        Task { await appState.createTask(title: title, assigneeId: aid) }
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { createFocused = true }
        }
    }
}

#Preview {
    NavigationStack { TasksView() }
        .environmentObject(AppState())
}
