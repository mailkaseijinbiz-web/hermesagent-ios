import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingCreate = false
    @State private var newTitle = ""
    @State private var newAssigneeId: String? = nil
    @FocusState private var createFocused: Bool

    @State private var editingTask: WorkTask?
    @State private var editTitle = ""
    @State private var editStatus: TaskStatus = .todo

    private var grouped: [(TaskStatus, [WorkTask])] {
        TaskStatus.allCases.compactMap { status in
            let items = appState.allTasks.filter { $0.status == status }
            return items.isEmpty ? nil : (status, items)
        }
    }

    var body: some View {
        ZStack {
            tasksBackgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summarySection
                    ForEach(grouped, id: \.0) { status, tasks in
                        statusSection(status: status, tasks: tasks)
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
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
        .sheet(item: $editingTask) { task in
            editSheet(task)
        }
        .refreshable { await appState.fetchTasks() }
        .task { await appState.fetchTasks() }
    }

    // MARK: - Background

    private var tasksBackgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.14, green: 0.16, blue: 0.22),
                    Color(red: 0.11, green: 0.11, blue: 0.16),
                    Color.blue.opacity(0.12),
                    Color.green.opacity(0.08),
                    Color(red: 0.10, green: 0.10, blue: 0.14),
                ]
                : [
                    Color(.systemBackground),
                    Color.blue.opacity(0.04),
                    Color.green.opacity(0.04),
                    Color(.systemGroupedBackground),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Sections

    private var summarySection: some View {
        tasksCard(title: "タスク一覧", systemImage: "checklist", color: .blue, titleSize: 20) {
            HStack(spacing: 16) {
                ForEach(TaskStatus.allCases) { status in
                    let count = appState.allTasks.filter { $0.status == status }.count
                    VStack(spacing: 4) {
                        Text("\(count)")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(status.color)
                        Text(status.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            if appState.allTasks.isEmpty {
                emptyLine("タスクはまだありません")
            }

            Button { showingCreate = true } label: {
                Label("タスクを追加", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.blue.opacity(0.14)).foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func statusSection(status: TaskStatus, tasks: [WorkTask]) -> some View {
        tasksCard(title: status.title, systemImage: status.icon, color: status.color) {
            VStack(spacing: 6) {
                ForEach(tasks) { task in
                    taskRow(task)
                }
            }
        }
    }

    // MARK: - Task row

    private func taskRow(_ task: WorkTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.status.icon)
                .font(.system(size: 18))
                .foregroundStyle(task.status.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(task.status.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(task.status.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(task.status.color.opacity(0.12))
                        .cornerRadius(4)
                    if let emoji = task.assigneeEmoji, let name = task.assigneeName {
                        Text("\(emoji) \(name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(task.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                    .strikethrough(task.status == .done, color: .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill).cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture { openEditor(for: task) }
        .contextMenu {
            Button { openEditor(for: task) } label: {
                Label("編集", systemImage: "pencil")
            }
            Menu {
                ForEach(TaskStatus.allCases) { s in
                    Button {
                        Task { await appState.setTaskStatus(task.id, s) }
                    } label: {
                        Label(s.title, systemImage: s.icon)
                    }
                    .disabled(s == task.status)
                }
            } label: {
                Label("状態を変更", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button(role: .destructive) {
                Task { await appState.deleteTask(task.id) }
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - Edit sheet

    private func openEditor(for task: WorkTask) {
        editTitle = task.title
        editStatus = task.status
        editingTask = task
    }

    private func editSheet(_ task: WorkTask) -> some View {
        NavigationStack {
            Form {
                Section("タスク名") {
                    TextField("タスク名", text: $editTitle, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("状態") {
                    Picker("状態", selection: $editStatus) {
                        ForEach(TaskStatus.allCases) { s in
                            Label(s.title, systemImage: s.icon).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if let emoji = task.assigneeEmoji, let name = task.assigneeName {
                    Section("担当") {
                        Text("\(emoji) \(name)")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        let id = task.id
                        editingTask = nil
                        Task { await appState.deleteTask(id) }
                    } label: {
                        Label("タスクを削除", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("タスクを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { editingTask = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let title = editTitle
                        let status = editStatus
                        let id = task.id
                        editingTask = nil
                        Task { await appState.updateTask(id, title: title, status: status) }
                    }
                    .disabled(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Create sheet

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("タスク名", text: $newTitle, axis: .vertical)
                        .lineLimit(1...4)
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
        .presentationDetents([.medium, .large])
    }

    // MARK: - Card shell (NewsView と同系)

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.72)
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.08)
    }

    @ViewBuilder
    private func tasksCard<Content: View>(title: String, systemImage: String,
                                          color: Color = .accentColor,
                                          titleSize: CGFloat = 16,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: titleSize * 0.85))
                    .foregroundStyle(color)
                Text(title).font(.system(size: titleSize, weight: .semibold))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) { content() }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(cardStroke, lineWidth: 0.5))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { TasksView() }
        .environmentObject(AppState())
}
