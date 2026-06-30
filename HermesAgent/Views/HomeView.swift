import SwiftUI
import Charts

// MARK: - HomeView (Moves スタイル・ライフログタイムライン)

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var health  = HealthManager.shared
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var lifeLog  = LifeLogStore.shared
    @ObservedObject private var usage   = AppUsageTracker.shared

    // カード表示トグル（AppStorage で端末永続）
    @AppStorage("homeCard_intention") private var showIntention = true
    @AppStorage("homeCard_graph")    private var showGraph    = true
    @AppStorage("homeCard_health")   private var showHealth   = true
    @AppStorage("homeCard_tasks")    private var showTasks    = true

    @State private var showMemoInput   = false
    @State private var showCardSettings = false
    @State private var editingMemo: LifeLogMemo? = nil

    private var d: DashboardData { appState.dashboard }

    // タイムラインアイテム（訪問 + メモ を時系列マージ）
    private var timelineItems: [LifeLogItem] {
        lifeLog.timeline(visits: location.todayVisits)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    dateHeader
                    if showIntention { intentionSection }
                    if showHealth { healthStrip }
                    if showGraph  { graphBadge }

                    Divider().padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)

                    if timelineItems.isEmpty {
                        emptyTimeline
                    } else {
                        timelineSection
                    }

                    if showTasks { tasksStrip }

                    Spacer(minLength: 100)
                }
            }

            // FAB: メモ追加
            Button { showMemoInput = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            }
            .padding(.trailing, 20).padding(.bottom, 28)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { appState.showDrawer = true } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .regular))
                }
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("Hermes").font(.system(.headline, weight: .semibold))
                    Circle()
                        .fill(appState.isConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button { showCardSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .light))
                    }
                    Button { appState.openNewChat() } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .light))
                    }
                }
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: appState.isConnected) { _, up in
            if up { Task { await refreshServer() } }
        }
        .sheet(isPresented: $showMemoInput) {
            MemoInputSheet { text in
                lifeLog.addMemo(text)
            }
        }
        .sheet(item: $editingMemo) { memo in
            MemoEditSheet(memo: memo) { newText in
                lifeLog.updateMemo(id: memo.id, text: newText)
            } onDelete: {
                lifeLog.deleteMemo(id: memo.id)
            }
        }
        .sheet(isPresented: $showCardSettings) { cardSettingsSheet }
    }

    // MARK: - 意図カード

    private var intentionSection: some View {
        IntentionCardsSection(
            vitalHint: appState.intentionToday.vitalHint,
            cards: appState.intentionToday.cards,
            isLoading: appState.isLoadingIntention,
            onConfirm: { card in Task { await appState.confirmIntention(card) } },
            onDismiss: { card in Task { await appState.dismissIntention(card) } },
            onRegenerate: { Task { await appState.regenerateIntention() } }
        )
        .padding(.top, 4)
    }

    // MARK: - ヘッダー

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(todayDateString)
                .font(.system(size: 22, weight: .bold))
            Text(greetingPhrase)
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    // MARK: - ヘルスストリップ（コンパクト）

    private var healthStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                healthChip("figure.walk",       "\(health.todaySteps)",        "歩", .green)
                healthChip("flame.fill",         "\(health.todayActiveEnergy)", "kcal", .orange)
                if health.todayRestingHR > 0 {
                    healthChip("heart.fill",     "\(health.todayRestingHR)",   "bpm", .red)
                }
                if health.todaySleepHours > 0 {
                    healthChip("bed.double.fill", String(format: "%.1f", health.todaySleepHours), "h", .indigo)
                }
                healthChip("apps.iphone", usage.todayMinutes > 0 ? "\(usage.todayMinutes)" : "—", "分", .purple)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func healthChip(_ icon: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(value).font(.system(size: 13, weight: .semibold))
            Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.08)).cornerRadius(20)
    }

    // MARK: - 頭の中グラフバッジ

    private var graphBadge: some View {
        NavigationLink(destination: SelfGraphView()) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 13)).foregroundStyle(.purple)
                Text("頭の中を見る")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.purple)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.purple.opacity(0.07)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.15), lineWidth: 0.5))
            .padding(.horizontal, 16).padding(.top, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - タイムライン

    private var emptyTimeline: some View {
        VStack(spacing: 14) {
            Image(systemName: "mappin.circle")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.4))
            Text("まだ記録がありません")
                .font(.system(size: 16, weight: .semibold))
            Text("移動すると場所が自動で記録されます。\n右下の＋でメモを追加できます。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !location.enabled {
                Button { location.setEnabled(true) } label: {
                    Label("位置情報の記録をオンにする", systemImage: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.14)).foregroundStyle(.tint)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 16)
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timelineItems.enumerated()), id: \.element.id) { idx, item in
                TimelineRow(
                    item: item,
                    isLast: idx == timelineItems.count - 1
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if case .memo(let m) = item { editingMemo = m }
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - タスクストリップ（コンパクト）

    private var tasksStrip: some View {
        let active = d.tasks.filter { $0.status == .doing || $0.status == .todo }
        return Group {
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().padding(.horizontal, 16)
                    HStack {
                        Image(systemName: "checklist").font(.system(size: 13)).foregroundStyle(.tint)
                        Text("タスク").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(active.count)件").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(active.prefix(6)) { t in
                                HStack(spacing: 5) {
                                    Image(systemName: t.status.icon)
                                        .font(.system(size: 11))
                                        .foregroundStyle(t.status.color)
                                    Text(t.title).font(.system(size: 13)).lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.05)).cornerRadius(16)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 6).padding(.bottom, 8)
            }
        }
    }

    // MARK: - カスタマイズシート

    private var cardSettingsSheet: some View {
        NavigationStack {
            List {
                Section("表示する要素") {
                    Toggle(isOn: $showIntention) { Label("意図カード", systemImage: "sparkle") }
                    Toggle(isOn: $showHealth) { Label("健康ストリップ", systemImage: "heart.fill") }
                    Toggle(isOn: $showGraph)  { Label("頭の中グラフ", systemImage: "circle.hexagongrid.fill") }
                    Toggle(isOn: $showTasks)  { Label("タスクストリップ", systemImage: "checklist") }
                }
                Section("位置情報") {
                    Toggle(isOn: Binding(
                        get: { location.enabled },
                        set: { location.setEnabled($0) }
                    )) { Label("移動の自動記録", systemImage: "location.fill") }
                }
            }
            .navigationTitle("ホームのカスタマイズ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { showCardSettings = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private func refresh() async {
        await health.loadTrends()
        await refreshServer()
    }

    private func refreshServer() async {
        await appState.fetchDashboard()
        await appState.fetchIntention()
        await appState.fetchEmployees()
        await appState.fetchApps()
        // Mac アクティビティをフェッチしてライフログに統合
        if let entries = try? await appState.apiClient.fetchMacActivity() {
            lifeLog.macActivities = entries
        }
    }

    private var todayDateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        return f.string(from: Date())
    }

    private var greetingPhrase: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return "おはようございます"
        case 11..<17: return "こんにちは"
        default: return "こんばんは"
        }
    }
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let item: LifeLogItem
    let isLast: Bool

    private let timeColWidth: CGFloat = 46
    private let dotSize: CGFloat      = 11
    private let lineWidth: CGFloat    = 2

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 時刻カラム
            Text(timeStr)
                .font(.system(size: 11, weight: .light, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: timeColWidth, alignment: .trailing)
                .padding(.top, 1)

            // ドット + 縦線
            VStack(spacing: 0) {
                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)
                    .overlay(
                        Circle().stroke(Color(.systemBackground), lineWidth: 1.5)
                    )
                    .padding(.horizontal, (30 - dotSize) / 2 + 2)

                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: lineWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, (30 - lineWidth) / 2 + 2)
                }
            }
            .frame(width: 34)

            // コンテンツ
            contentView
                .padding(.leading, 6)
                .padding(.bottom, isLast ? 8 : 28)

            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var contentView: some View {
        switch item {
        case .visit(let v, let dur):
            VStack(alignment: .leading, spacing: 3) {
                Text(v.name)
                    .font(.system(size: 15, weight: .semibold))
                if let d = dur, d > 60 {
                    Text(durationLabel(d))
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 1)

        case .memo(let m):
            VStack(alignment: .leading, spacing: 2) {
                Text(m.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if m.editedAt != nil {
                    Text("編集済み").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.top, 1)

        case .mac(let a):
            HStack(spacing: 6) {
                Image(systemName: a.kind == "hermes" ? "brain.head.profile" : "desktopcomputer")
                    .font(.system(size: 12))
                    .foregroundStyle(a.kind == "hermes" ? Color.purple : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if a.kind == "hermes" {
                        Text("\(a.appName): \(a.label)")
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2)
                    } else {
                        Text(a.appName)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        if let wt = a.windowTitle, !wt.isEmpty {
                            Text(wt)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Text(durationLabel(a.duration))
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(a.kind == "hermes"
                        ? Color.purple.opacity(0.07)
                        : Color.primary.opacity(0.04))
            .cornerRadius(10)
            .padding(.top, 1)
        }
    }

    private var timeStr: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: item.time)
    }

    private var dotColor: Color {
        switch item {
        case .visit:               return Color.accentColor
        case .memo:                return Color.secondary
        case .mac(let a):          return a.kind == "hermes" ? Color.purple : Color(.systemGray3)
        }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins)分" }
        let h = mins / 60; let m = mins % 60
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }
}

// MARK: - Memo Input Sheet

struct MemoInputSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("今この瞬間、何を考えていますか？")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .frame(minHeight: 120, maxHeight: 280)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .focused($focused)

                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("メモを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        onSave(t)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Memo Edit Sheet

struct MemoEditSheet: View {
    let memo: LifeLogMemo
    let onSave: (String) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(memo: LifeLogMemo, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.memo = memo
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: memo.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .frame(minHeight: 120, maxHeight: 280)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .focused($focused)

                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("メモを削除", systemImage: "trash")
                        .font(.system(size: 14))
                }
                .padding(.horizontal, 20)

                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("メモを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        onSave(t)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
    }
}
