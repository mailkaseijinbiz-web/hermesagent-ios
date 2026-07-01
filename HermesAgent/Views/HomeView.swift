import SwiftUI
import Charts

// MARK: - HomeView (Moves スタイル・ライフログタイムライン)

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var health  = HealthManager.shared
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var photos  = PhotosManager.shared
    @ObservedObject private var photoLog = PhotoLogStore.shared
    @ObservedObject private var lifeLog  = LifeLogStore.shared
    @ObservedObject private var usage   = AppUsageTracker.shared

    @State private var selectedDate = HomeDateHelpers.startOfDay(Date())
    @State private var scope: HomeTimeScope = .day
    @State private var monthPickerDay = HomeDateHelpers.startOfDay(Date())
    @State private var dayMetrics = DayHealthMetrics.empty
    @State private var weekStepMap: [String: Int] = [:]

    @State private var showMemoInput   = false
    @State private var editingMemo: LifeLogMemo? = nil

    private var isViewingToday: Bool {
        HomeDateHelpers.isToday(selectedDate)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    scopePicker
                    dateNavigationHeader
                    scopeContent
                    Spacer(minLength: 100)
                }
            }

            if isViewingToday && scope == .day {
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
                Button { appState.openNewChat() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .regular))
                }
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .task(id: selectedDate) {
            dayMetrics = await health.metrics(for: selectedDate)
        }
        .task(id: weekTaskKey) {
            await loadWeekStepsIfNeeded()
        }
        .onChange(of: appState.isConnected) { _, up in
            if up { Task { await refreshServer() } }
        }
        .onChange(of: scope) { _, newScope in
            if newScope == .month {
                monthPickerDay = selectedDate
            }
            if newScope == .week {
                Task { await loadWeekStepsIfNeeded() }
            }
        }
        .sheet(isPresented: $showMemoInput) {
            MemoInputSheet { text in
                lifeLog.addMemo(text)
                if let memo = lifeLog.todayMemos.last {
                    Task { await appState.recordWeightFromMemo(text: text, memoId: memo.id, at: memo.time) }
                }
            }
        }
        .sheet(item: $editingMemo) { memo in
            MemoEditSheet(memo: memo) { newText in
                lifeLog.updateMemo(id: memo.id, text: newText)
                Task { await appState.recordWeightFromMemo(text: newText, memoId: memo.id, at: memo.time) }
            } onDelete: {
                lifeLog.deleteMemo(id: memo.id)
            }
        }
    }

    private var weekTaskKey: String {
        let days = HomeDateHelpers.weekDays(containing: selectedDate)
        guard let first = days.first, let last = days.last else { return "" }
        return "\(HomeDateHelpers.dayKey(first))-\(HomeDateHelpers.dayKey(last))"
    }

    // MARK: - Scope picker

    private var scopePicker: some View {
        Picker("表示", selection: $scope) {
            ForEach(HomeTimeScope.allCases) { s in
                Text(s.label).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Date navigation

    private var dateNavigationHeader: some View {
        HStack(spacing: 12) {
            Button {
                selectedDate = HomeDateHelpers.navigate(selectedDate, scope: scope, direction: -1)
                syncMonthPickerDay()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Button {
                selectedDate = HomeDateHelpers.jumpToToday()
                monthPickerDay = selectedDate
            } label: {
                VStack(alignment: .center, spacing: 2) {
                    Text(HomeDateHelpers.headerTitle(for: selectedDate, scope: scope))
                        .font(.system(size: scope == .day ? 22 : 18, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(HomeDateHelpers.greeting(for: selectedDate))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                selectedDate = HomeDateHelpers.navigate(selectedDate, scope: scope, direction: 1)
                syncMonthPickerDay()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var scopeContent: some View {
        switch scope {
        case .day:
            HomeDayContentView(
                selectedDate: selectedDate,
                isViewingToday: isViewingToday,
                dayMetrics: dayMetrics,
                timelineItems: timelineItems(for: selectedDate),
                appState: appState,
                health: health,
                location: location,
                photos: photos,
                usage: usage,
                onEditMemo: { editingMemo = $0 }
            )
        case .week:
            HomeWeekContentView(
                selectedDate: selectedDate,
                weekStepMap: weekStepMap,
                onSelectDay: { day in
                    selectedDate = day
                    scope = .day
                }
            )
        case .month:
            HomeMonthContentView(
                selectedDate: selectedDate,
                monthPickerDay: $monthPickerDay,
                onSelectDay: { day in
                    selectedDate = day
                    scope = .day
                }
            )
        case .year:
            HomeYearContentView(
                selectedDate: selectedDate,
                onSelectMonth: { monthDate in
                    selectedDate = monthDate
                    monthPickerDay = monthDate
                    scope = .month
                }
            )
        }
    }

    // MARK: - Helpers

    private func timelineItems(for date: Date) -> [LifeLogItem] {
        _ = photoLog.todayEntries   // subscribe to photo timeline updates
        return lifeLog.timeline(for: date, visits: location.visits(on: date))
    }

    private func syncMonthPickerDay() {
        if scope == .month {
            monthPickerDay = selectedDate
        }
    }

    private func loadWeekStepsIfNeeded() async {
        guard scope == .week else { return }
        let days = HomeDateHelpers.weekDays(containing: selectedDate)
        guard let first = days.first, let last = days.last else { return }
        let steps = await health.steps(from: first, to: last)
        var map: [String: Int] = [:]
        for d in steps {
            map[HomeDateHelpers.dayKey(d.date)] = d.steps
        }
        weekStepMap = map
    }

    private func refresh() async {
        await health.loadTrends()
        dayMetrics = await health.metrics(for: selectedDate)
        await loadWeekStepsIfNeeded()
        await photos.syncNow()
        await refreshServer()
    }

    private func refreshServer() async {
        await appState.fetchDashboard()
        if isViewingToday {
            await appState.fetchIntention()
            await appState.fetchLifelogSummary()
        }
        await appState.fetchEmployees()
        await appState.fetchApps()
        if let entries = try? await appState.apiClient.fetchMacActivity() {
            lifeLog.macActivities = entries
        }
    }
}

// MARK: - Day View

private struct HomeDayContentView: View {
    let selectedDate: Date
    let isViewingToday: Bool
    let dayMetrics: DayHealthMetrics
    let timelineItems: [LifeLogItem]
    @ObservedObject var appState: AppState
    @ObservedObject var health: HealthManager
    @ObservedObject var location: LocationManager
    @ObservedObject var photos: PhotosManager
    @ObservedObject var usage: AppUsageTracker
    let onEditMemo: (LifeLogMemo) -> Void

    @State private var timelineExpanded = false

    var body: some View {
        Group {
            if isViewingToday {
                IntentionCardsSection(
                    vitalHint: appState.intentionToday.vitalHint,
                    vitalityMode: appState.intentionToday.vitalityMode,
                    cards: appState.intentionToday.cards,
                    isLoading: appState.isLoadingIntention,
                    isOffline: !appState.isConnected,
                    onConfirm: { card in Task { await appState.confirmIntention(card) } },
                    onDismiss: { card in Task { await appState.dismissIntention(card) } },
                    onRegenerate: { Task { await appState.regenerateIntention() } }
                )
                .padding(.top, 4)
            }

            dayHealthStrip

            if isViewingToday {
                lifelogSummarySection
            }

            Divider().padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)

            if timelineItems.isEmpty {
                emptyTimeline
            } else if isViewingToday {
                DisclosureGroup(isExpanded: $timelineExpanded) {
                    timelineSection
                } label: {
                    Text("今日の記録 (\(timelineItems.count))")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16)
                }
            } else {
                timelineSection
            }
        }
    }

    private var dayHealthStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                healthChip("figure.walk", dayMetrics.steps > 0 ? "\(dayMetrics.steps)" : "—", "歩", .green)
                healthChip("flame.fill", dayMetrics.activeEnergy > 0 ? "\(dayMetrics.activeEnergy)" : "—", "kcal", .orange)
                if dayMetrics.restingHR > 0 {
                    healthChip("heart.fill", "\(dayMetrics.restingHR)", "bpm", .red)
                }
                if dayMetrics.sleepHours > 0 {
                    healthChip("bed.double.fill", String(format: "%.1f", dayMetrics.sleepHours), "h", .indigo)
                }
                if dayMetrics.bodyMassKg > 0 {
                    healthChip("scalemass.fill", String(format: "%.1f", dayMetrics.bodyMassKg), "kg", .teal)
                }
                if isViewingToday {
                    healthChip("apps.iphone", usage.todayMinutes > 0 ? "\(usage.todayMinutes)" : "—", "分", .purple)
                }
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

    @ViewBuilder
    private var lifelogSummarySection: some View {
        if appState.isLoadingLifelogSummary && appState.lifelogSummary.isEmpty {
            lifelogSummaryCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("要約を読み込み中…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        } else if !appState.lifelogSummary.isEmpty, isViewingToday,
                  Calendar.current.isDateInToday(Date(timeIntervalSince1970: appState.lifelogSummaryAt)) {
            lifelogSummaryCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.lifelogSummary)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if appState.lifelogSummaryAt > 0 {
                        Text(lifelogSummaryTimeLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func lifelogSummaryCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("今日の要約", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(Color.purple.opacity(0.05))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.15), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var lifelogSummaryTimeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: appState.lifelogSummaryAt)) + " に生成"
    }

    private var emptyTimeline: some View {
        VStack(spacing: 14) {
            Image(systemName: "mappin.circle")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.4))
            Text("まだ記録がありません")
                .font(.system(size: 16, weight: .semibold))
            Text(isViewingToday
                 ? "移動すると場所が自動で記録されます。\n写真の記録をオンにすると撮影もタイムラインに載ります。\n右下の＋でメモを追加できます。"
                 : "この日の記録はありません。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if isViewingToday && !location.enabled {
                Button { location.setEnabled(true) } label: {
                    Label("位置情報の記録をオンにする", systemImage: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.14)).foregroundStyle(.tint)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if isViewingToday && !photos.enabled {
                Button { photos.setEnabled(true) } label: {
                    Label("写真の記録をオンにする", systemImage: "photo.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.14)).foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else if isViewingToday && photos.enabled && !photos.authorized {
                Button { Task { await photos.requestAuthAndLoad() } } label: {
                    Label("写真ライブラリへのアクセスを許可", systemImage: "photo.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.14)).foregroundStyle(.orange)
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
                TimelineRow(item: item, isLast: idx == timelineItems.count - 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if case .memo(let m) = item { onEditMemo(m) }
                    }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Week View

private struct HomeWeekContentView: View {
    let selectedDate: Date
    let weekStepMap: [String: Int]
    let onSelectDay: (Date) -> Void

    @ObservedObject private var lifeLog = LifeLogStore.shared
    @ObservedObject private var location = LocationManager.shared

    private var weekDays: [Date] {
        HomeDateHelpers.weekDays(containing: selectedDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(weekDays, id: \.timeIntervalSince1970) { day in
                weekDayRow(day)
                if day != weekDays.last {
                    Divider().padding(.leading, 72)
                }
            }
        }
        .padding(.top, 8)
    }

    private func weekDayRow(_ day: Date) -> some View {
        let key = HomeDateHelpers.dayKey(day)
        let memos = lifeLog.memos(on: day)
        let visits = location.visits(on: day)
        let steps = weekStepMap[key] ?? 0
        let isToday = HomeDateHelpers.isToday(day)

        return Button {
            onSelectDay(day)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 2) {
                    Text(weekdayLabel(day))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isToday ? Color.accentColor : .secondary)
                    Text(dayNumberLabel(day))
                        .font(.system(size: 20, weight: isToday ? .bold : .semibold))
                        .foregroundStyle(isToday ? Color.accentColor : .primary)
                }
                .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        if steps > 0 {
                            Label("\(steps)歩", systemImage: "figure.walk")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if !memos.isEmpty {
                            Label("\(memos.count)メモ", systemImage: "note.text")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if !visits.isEmpty {
                            Label("\(visits.count)場所", systemImage: "mappin")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if steps == 0 && memos.isEmpty && visits.isEmpty {
                            Text("記録なし")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let preview = memos.last?.text {
                        Text(preview)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func weekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "E"
        return f.string(from: date)
    }

    private func dayNumberLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: date)
    }
}

// MARK: - Month View

private struct HomeMonthContentView: View {
    let selectedDate: Date
    @Binding var monthPickerDay: Date
    let onSelectDay: (Date) -> Void

    @ObservedObject private var lifeLog = LifeLogStore.shared
    @ObservedObject private var location = LocationManager.shared

    private let weekdaySymbols = ["月", "火", "水", "木", "金", "土", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            weekdayHeader
            calendarGrid
            Divider().padding(.horizontal, 16)
            dayPreview
        }
        .padding(.top, 8)
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(weekdaySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
    }

    private var calendarGrid: some View {
        let cells = HomeDateHelpers.daysInMonth(for: selectedDate)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                if let day = cell {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func dayCell(_ day: Date) -> some View {
        let visitCount = location.visitCount(on: day)
        let memoCount = lifeLog.memoCount(on: day)
        let photoCount = PhotoLogStore.shared.entryCount(on: day)
        let hasActivity = memoCount > 0 || visitCount > 0 || photoCount > 0
        let isSelected = HomeDateHelpers.isSameDay(day, monthPickerDay)
        let isToday = HomeDateHelpers.isToday(day)

        return Button {
            monthPickerDay = day
        } label: {
            VStack(spacing: 3) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 15, weight: isSelected || isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : .primary))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                Circle()
                    .fill(hasActivity ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }

    private var dayPreview: some View {
        let items = lifeLog.timeline(
            for: monthPickerDay,
            visits: location.visits(on: monthPickerDay)
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dayPreviewTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("日ビュー") { onSelectDay(monthPickerDay) }
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 16)

            if items.isEmpty {
                Text("記録なし")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { idx, item in
                        TimelineRow(item: item, isLast: idx == min(items.count, 5) - 1)
                    }
                }
                if items.count > 5 {
                    Text("他 \(items.count - 5) 件")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var dayPreviewTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）"
        return f.string(from: monthPickerDay)
    }
}

// MARK: - Year View

private struct HomeYearContentView: View {
    let selectedDate: Date
    let onSelectMonth: (Date) -> Void

    @ObservedObject private var lifeLog = LifeLogStore.shared
    @ObservedObject private var location = LocationManager.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(HomeDateHelpers.monthNames(for: selectedDate), id: \.month) { entry in
                monthTile(entry.date, month: entry.month)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func monthTile(_ monthDate: Date, month: Int) -> some View {
        let range = HomeDateHelpers.monthRange(for: monthDate)
        let memoCount = lifeLog.memos(from: range.start, to: range.end).count
        let visitCount = location.visits(from: range.start, to: range.end).count
        let total = memoCount + visitCount

        return Button {
            onSelectMonth(monthDate)
        } label: {
            VStack(spacing: 6) {
                Text("\(month)月")
                    .font(.system(size: 16, weight: .semibold))
                if total > 0 {
                    Text("\(total)件")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let item: LifeLogItem
    let isLast: Bool

    @State private var expandedMacSummary = false

    private let timeColWidth: CGFloat = 46
    private let dotSize: CGFloat      = 11
    private let lineWidth: CGFloat    = 2

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(timeStr)
                .font(.system(size: 11, weight: .light, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: timeColWidth, alignment: .trailing)
                .padding(.top, 1)

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
                if let kg = WeightMemoParser.parse(m.text) {
                    Label(WeightMemoParser.displayLabel(kg: kg), systemImage: "scalemass.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.teal)
                }
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

        case .macSummary(let s):
            macSummaryView(s)

        case .photo(let p):
            HStack(spacing: 6) {
                Image(systemName: p.mediaKind == "video" ? "video.fill" : "photo.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.mediaKind == "video" ? "動画" : "写真")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    Text(p.label)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(10)
            .padding(.top, 1)
        }
    }

    @ViewBuilder
    private func macSummaryView(_ s: MacActivitySummary) -> some View {
        let visibleApps = expandedMacSummary ? s.apps : Array(s.apps.prefix(3))
        let hermes = s.hasHermes

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12))
                    .foregroundStyle(hermes ? Color.purple : Color.secondary)
                Text("Mac作業")
                    .font(.system(size: 14, weight: .semibold))
            }

            ForEach(Array(visibleApps.enumerated()), id: \.offset) { _, app in
                HStack(spacing: 4) {
                    if app.kind == "hermes" {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.purple)
                    }
                    Text("\(app.appName) · \(MacActivitySummarizer.formatDuration(app.totalDuration))")
                        .font(.system(size: 13))
                        .foregroundStyle(app.kind == "hermes" ? Color.purple : .primary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                Text("合計 \(MacActivitySummarizer.formatDuration(s.totalDuration))")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.secondary)
                if s.rawEntryCount > s.apps.count {
                    Text("\(s.rawEntryCount)件を要約")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hermes ? Color.purple.opacity(0.07) : Color.primary.opacity(0.04))
        .cornerRadius(10)
        .padding(.top, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard s.apps.count > 3 else { return }
            expandedMacSummary.toggle()
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
        case .macSummary(let s):   return s.hasHermes ? Color.purple : Color(.systemGray3)
        case .photo:               return .orange
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
                Text("体重は「65.2kg」「体重 65.2」のように書くと Health に記録されます")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
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
