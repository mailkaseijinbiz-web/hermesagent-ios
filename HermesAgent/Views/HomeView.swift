import SwiftUI
import Charts

// MARK: - HomeView (Moves スタイル・ライフログタイムライン)

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var health  = HealthManager.shared
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var photos  = PhotosManager.shared
    @ObservedObject private var photoLog = PhotoLogStore.shared
    @ObservedObject private var lifeLog  = LifeLogStore.shared

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
            homeBackgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let syncError = appState.lifeLogSyncError {
                        lifeLogSyncErrorBanner(syncError)
                    }
                    scopePicker
                    if scope != .day {
                        dateNavigationHeader
                    }
                    scopeContent
                    Spacer(minLength: 100)
                }
            }
            .scrollContentBackground(.hidden)
            .contentShape(Rectangle())
            .simultaneousGesture(dateSwipeGesture)

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
        .task(id: homeLoadKey) {
            await loadHomeData()
        }
        .task(id: weekTaskKey) {
            await loadWeekStepsIfNeeded()
        }
        .task(id: monthSyncKey) {
            guard scope == .month else { return }
            await appState.syncLifeLogFromMac(for: monthPickerDay)
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
                let memo = lifeLog.addMemo(text)
                Task {
                    await appState.pushMemoToMac(memo)
                    await appState.recordWeightFromMemo(text: text, memoId: memo.id, at: memo.time)
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
        .sheet(isPresented: $appState.showEveningReflection, onDismiss: {
            appState.eveningReflectionEditing = nil
        }) {
            EveningReflectionFlow(
                appState: appState,
                lifeLog: lifeLog,
                timelineItems: timelineItems(for: selectedDate),
                trigger: appState.eveningReflectionTrigger,
                editingReflection: appState.eveningReflectionEditing
            )
        }
    }

    private var homeBackgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.16, green: 0.14, blue: 0.22),
                    Color(red: 0.11, green: 0.11, blue: 0.16),
                    Color.purple.opacity(0.14),
                    Color.blue.opacity(0.08),
                    Color(red: 0.10, green: 0.10, blue: 0.14),
                ]
                : [
                    Color(red: 0.96, green: 0.94, blue: 0.90),
                    Color(red: 0.99, green: 0.97, blue: 0.94),
                    Color.orange.opacity(0.04),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var dateSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.3 else { return }
                if value.translation.width < -60 {
                    shiftSelectedDate(by: 1)
                } else if value.translation.width > 60 {
                    shiftSelectedDate(by: -1)
                }
            }
    }

    private var canGoForwardDay: Bool {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: HomeDateHelpers.startOfDay(selectedDate)) else {
            return false
        }
        return tomorrow <= HomeDateHelpers.startOfDay(Date())
    }

    private func shiftSelectedDate(by direction: Int) {
        let next = HomeDateHelpers.navigate(selectedDate, scope: scope, direction: direction)
        if scope == .day, direction > 0 {
            let today = HomeDateHelpers.startOfDay(Date())
            if next > today { return }
        }
        selectedDate = next
        syncMonthPickerDay()
    }

    private var weekTaskKey: String {
        let days = HomeDateHelpers.weekDays(containing: selectedDate)
        guard let first = days.first, let last = days.last else { return "" }
        return "\(HomeDateHelpers.dayKey(first))-\(HomeDateHelpers.dayKey(last))"
    }

    private var monthSyncKey: String {
        "\(scope.rawValue)-\(HomeDateHelpers.dayKey(monthPickerDay))"
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
                shiftSelectedDate(by: -1)
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
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                shiftSelectedDate(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var scopeContent: some View {
        switch scope {
        case .day:
            HomeDayContentView(
                selectedDate: selectedDate,
                isViewingToday: isViewingToday,
                canGoForwardDay: canGoForwardDay,
                dayMetrics: dayMetrics,
                timelineItems: timelineItems(for: selectedDate),
                appState: appState,
                health: health,
                location: location,
                photos: photos,
                lifeLog: lifeLog,
                onEditMemo: { editingMemo = $0 },
                onPreviousDay: { shiftSelectedDate(by: -1) },
                onNextDay: { shiftSelectedDate(by: 1) },
                onJumpToToday: {
                    selectedDate = HomeDateHelpers.jumpToToday()
                    monthPickerDay = selectedDate
                }
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
        _ = lifeLog.macMemoCache
        _ = lifeLog.macActivityCache
        _ = lifeLog.macDayRecordCache
        _ = lifeLog.macSyncRevision
        return lifeLog.timeline(for: date, visits: location.visits(on: date))
    }

    private func lifeLogSyncErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                appState.lifeLogSyncError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

    private var homeLoadKey: String {
        HomeDateHelpers.dayKey(selectedDate)
    }

    private func loadHomeData() async {
        await health.loadTrends()
        await loadWeekStepsIfNeeded()
        await photos.syncNow()
        await refreshServer()
        _ = await appState.syncLifeLogFromMac(for: selectedDate)
        dayMetrics = await appState.dayHealthMetrics(for: selectedDate)
    }

    private func refresh() async {
        await health.loadTrends()
        await loadWeekStepsIfNeeded()
        await photos.syncNow()
        await refreshServer()
        _ = await appState.syncLifeLogFromMac(for: selectedDate)
        dayMetrics = await appState.dayHealthMetrics(for: selectedDate)
    }

    private func refreshServer() async {
        await appState.fetchDashboard()
        if isViewingToday {
            await appState.fetchIntention()
            await appState.fetchLifelogSummary(forceRefresh: true)
        }
        await appState.fetchEmployees()
        await appState.fetchApps()
    }
}

// MARK: - Day View

private struct HomeDayContentView: View {
    let selectedDate: Date
    let isViewingToday: Bool
    let canGoForwardDay: Bool
    let dayMetrics: DayHealthMetrics
    let timelineItems: [LifeLogItem]
    @ObservedObject var appState: AppState
    @ObservedObject var health: HealthManager
    @ObservedObject var location: LocationManager
    @ObservedObject var photos: PhotosManager
    @ObservedObject var lifeLog: LifeLogStore
    let onEditMemo: (LifeLogMemo) -> Void
    let onPreviousDay: () -> Void
    let onNextDay: () -> Void
    let onJumpToToday: () -> Void

    @State private var zoomPhoto: PhotoLogEntry?
    @State private var isRegeneratingOneLiner = false
    @State private var editingVisit: VisitEntry?
    @State private var visitEditName = ""

    private var mobilityTotals: MobilityTotals {
        MobilityAnalyzer.analyze(visits: location.visits(on: selectedDate))
    }

    private var macLocationSummary: String? {
        if let mac = lifeLog.macDayRecord(on: selectedDate), mac.hasLocations {
            return mac.locations
        }
        if isViewingToday {
            let local = location.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return local.isEmpty ? nil : local
        }
        return nil
    }

    private var coverItem: LifeLogItem? {
        lifeLog.resolveCover(in: timelineItems, for: selectedDate)
    }

    var body: some View {
        Group {
            LifeLogBookPage(
                date: selectedDate,
                isToday: isViewingToday,
                canGoForward: canGoForwardDay,
                onPreviousDay: onPreviousDay,
                onNextDay: onNextDay,
                onJumpToToday: onJumpToToday
            ) {
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
                }

                if showsEveningReflectionBanner {
                    eveningReflectionBanner
                }

                if let cover = coverItem {
                    LifeLogBookCoverHero(
                        item: cover,
                        title: isViewingToday ? "今日の表紙" : "この日の表紙"
                    ) {
                        lifeLog.clearDayCover(for: selectedDate)
                    }
                } else if !timelineItems.isEmpty {
                    LifeLogBookHint(message: "記録を長押しして「\(isViewingToday ? "今日" : "この日")の表紙」に選べます")
                }

                if dayMetrics.steps > 0 || dayMetrics.sleepHours > 0 || dayMetrics.restingHR > 0 {
                    LifeLogBookStatsRow(
                        steps: dayMetrics.steps,
                        sleepHours: dayMetrics.sleepHours,
                        restingHR: dayMetrics.restingHR
                    )
                }

                eveningReflectionBookSections
                if isViewingToday {
                    if lifeLog.hasCompletedEveningReflection() {
                        eveningEditButton
                    } else {
                        eveningReflectButton
                    }
                }

                bookContextSections

                if timelineItems.isEmpty {
                    emptyTimelineBook
                } else {
                    Text("\(isViewingToday ? "今日" : "この日")のできごと · \(timelineItems.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    timelineSection
                }
            }
        }
        .fullScreenCover(item: $zoomPhoto) { entry in
            PhotoZoomViewer(entry: entry)
        }
        .sheet(item: $editingVisit) { visit in
            NavigationStack {
                Form {
                    Section("場所の名称") {
                        TextField("名称", text: $visitEditName)
                    }
                }
                .navigationTitle("場所を編集")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { editingVisit = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            location.updateVisitName(id: visit.id, on: selectedDate, to: visitEditName)
                            editingVisit = nil
                        }
                        .disabled(visitEditName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
            .onAppear { visitEditName = visit.name }
        }
    }

    private var showsLocationInTimeline: Bool {
        timelineItems.contains { item in
            switch item {
            case .visit: return true
            case .macSnapshot(let label, _, _): return label == "外出"
            default: return false
            }
        }
    }

    private var hasMobilityInTimeline: Bool {
        timelineItems.contains { if case .mobility = $0 { return true }; return false }
    }

    @ViewBuilder
    private var bookContextSections: some View {
        if let summary = macLocationSummary, !showsLocationInTimeline {
            VStack(alignment: .leading, spacing: 4) {
                Text("外出")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.system(size: 15, design: .serif))
                    .lineSpacing(4)
            }
        }
        let totals = mobilityTotals
        if !totals.isEmpty, !hasMobilityInTimeline {
            VStack(alignment: .leading, spacing: 6) {
                Text("移動")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if totals.walkSeconds >= 60 {
                    mobilityRow(icon: "figure.walk", label: "徒歩",
                                duration: totals.walkSeconds, meters: totals.walkMeters, color: .green)
                }
                if totals.bikeSeconds >= 60 {
                    mobilityRow(icon: "bicycle", label: "自転車",
                                duration: totals.bikeSeconds, meters: totals.bikeMeters, color: .blue)
                }
                if totals.trainSeconds >= 60 {
                    mobilityRow(icon: "tram.fill", label: "電車",
                                duration: totals.trainSeconds, meters: totals.trainMeters, color: .indigo)
                }
            }
        }
    }

    private var showsEveningReflectionBanner: Bool {
        isViewingToday
            && !lifeLog.hasCompletedEveningReflection()
            && Calendar.current.component(.hour, from: Date()) >= 18
    }

    private var eveningReflectionBanner: some View {
        Button {
            appState.trackProductMetric(name: "evening_reflect.banner_tapped")
            appState.openEveningReflection(trigger: "banner")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LifeLogBookPalette.accentWarm)
                VStack(alignment: .leading, spacing: 2) {
                    Text("今夜の振り返り")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("今日いちばん残したい記録を選びましょう")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LifeLogBookPalette.accentWarm.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var eveningReflectionBookSections: some View {
        if let reflection = lifeLog.eveningReflection(on: selectedDate) {
            let oneLinerTitle = isViewingToday ? "今日のひとこと" : "この日のひとこと"
            let pickedTitle = isViewingToday ? "今日選んだ記録" : "選んだ記録"
            LifeLogBookAside(title: oneLinerTitle, bodyText: reflection.oneLiner) {
                if isViewingToday,
                   reflection.aiSource == "fallback",
                   appState.isConnected {
                    Button {
                        Task { await regenerateEveningOneLiner(reflection) }
                    } label: {
                        if isRegeneratingOneLiner {
                            ProgressView()
                                .scaleEffect(0.75)
                        } else {
                            Text("AIで言い換える")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRegeneratingOneLiner)
                }
            }
            LifeLogBookCompactAside(
                title: pickedTitle,
                primaryText: reflection.pickedLabel,
                secondaryText: reflection.feelingText.isEmpty ? nil : reflection.feelingText
            )
            if let aiReflection = reflection.aiReflection, !aiReflection.isEmpty {
                LifeLogBookAside(title: "Hermesの振り返り", bodyText: aiReflection) {
                    Text("AI")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.secondary)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        } else if isViewingToday, let line = LifeLogOneLiner.compose(items: timelineItems, metrics: dayMetrics) {
            LifeLogBookAside(title: "今日のひとこと", bodyText: line)
        }
    }

    private func regenerateEveningOneLiner(_ reflection: DayEveningReflection) async {
        guard appState.isConnected else { return }
        isRegeneratingOneLiner = true
        defer { isRegeneratingOneLiner = false }
        if let result = try? await appState.apiClient.generateEveningReflection(
            pickedLabel: reflection.pickedLabel,
            pickedDetail: reflection.pickedDetail,
            feelingText: reflection.feelingText
        ), !result.oneLiner.isEmpty {
            lifeLog.updateEveningReflectionOneLiner(
                for: selectedDate,
                oneLiner: result.oneLiner,
                aiSource: "mac",
                aiReflection: result.aiReflection
            )
            appState.trackProductMetric(name: "evening_reflect.regenerated")
            if let updated = lifeLog.eveningReflection(on: selectedDate) {
                await appState.syncEveningReflectionToMac(updated, for: selectedDate)
            }
        }
    }

    private var eveningEditButton: some View {
        Button {
            if let reflection = lifeLog.eveningReflection(on: selectedDate) {
                appState.openEveningReflection(trigger: "edit", editing: reflection)
            }
        } label: {
            Label("振り返りを編集", systemImage: "pencil")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(LifeLogBookPalette.accentWarm)
    }

    private var eveningReflectButton: some View {
        Button {
            appState.openEveningReflection(trigger: "home")
        } label: {
            Label("今夜振り返る", systemImage: "moon.stars")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(LifeLogBookPalette.accentWarm)
    }

    private var emptyTimelineBook: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 32))
                .foregroundStyle(LifeLogBookPalette.accentWarm.opacity(0.7))
            Text("まだ記録がありません")
                .font(.system(size: 16, weight: .semibold, design: .serif))
            Text("スマホを持ち歩くだけで、写真・場所・メモがこのページに集まります。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if isViewingToday && !location.enabled {
                Button { location.setEnabled(true) } label: {
                    Label("位置情報の記録をオン", systemImage: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
            if isViewingToday && !photos.enabled {
                Button { photos.setEnabled(true) } label: {
                    Label("写真の記録をオン", systemImage: "photo.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
            } else if isViewingToday && photos.enabled && !photos.authorized {
                Button { Task { await photos.requestAuthAndLoad() } } label: {
                    Label("写真ライブラリを許可", systemImage: "photo.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func mobilityRow(icon: String, label: String, duration: TimeInterval, meters: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 14, weight: .medium))
            Spacer()
            Text(MobilityTotals.formatDuration(duration))
                .font(.system(size: 14, weight: .semibold))
            Text(MobilityTotals.formatDistance(meters))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var timelineSection: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timelineItems.enumerated()), id: \.element.id) { idx, item in
                TimelineRow(
                    item: item,
                    isLast: idx == timelineItems.count - 1,
                    allowSetCover: true,
                    onSetCover: { lifeLog.setDayCover(item, for: selectedDate) },
                    onDelete: { lifeLog.deleteTimelineItem(item, for: selectedDate) },
                    onEditVisit: {
                        if case .visit(let v, _) = item {
                            visitEditName = v.name
                            editingVisit = v
                        }
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    switch item {
                    case .memo(let m):
                        if m.isEditableOnDevice { onEditMemo(m) }
                    case .photo(let p): zoomPhoto = p
                    default: break
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 24)
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
        let visits = location.significantVisits(on: day)
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
        let hasActivity = lifeLog.hasActivity(on: day, visitCount: visitCount)
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
            visits: location.significantVisits(on: monthPickerDay)
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
        let visitCount = location.significantVisits(from: range.start, to: range.end).count
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
    var allowSetCover: Bool = false
    var onSetCover: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEditVisit: (() -> Void)? = nil

    @State private var expandedMacSummary = false

    private let timeColWidth: CGFloat = 48
    private let dotSize: CGFloat      = 10
    private let lineWidth: CGFloat    = 2
    private let railWidth: CGFloat    = 14

    var body: some View {
        switch item {
        case .photo(let p):
            mediaRow(timeStr: timeStr) {
                PhotoThumbnailView(localIdentifier: p.id, mediaKind: p.mediaKind, fillWidth: true)
                    .frame(maxWidth: .infinity)
            }
        case .memo(let m) where m.hasMacImages:
            mediaRow(timeStr: timeStr) {
                if let first = m.imageNames?.first {
                    MacMemoImageView(fileName: first, fillWidth: true)
                        .frame(maxWidth: .infinity)
                }
                if let names = m.imageNames, names.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(names.dropFirst(), id: \.self) { name in
                                MacMemoImageView(fileName: name, side: 72)
                            }
                        }
                    }
                }
                mediaCaption(kind: m.timelineLabel, detail: m.timelineDetail)
            }
        default:
            standardRow
        }
    }

    private func mediaRow<Content: View>(timeStr: String, @ViewBuilder body: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeStr)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.65))
                .frame(width: timeColWidth, alignment: .trailing)
                .padding(.top, 4)
            timelineRail
            VStack(alignment: .leading, spacing: 8) {
                body()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, rowBottomPadding)
        .modifier(TimelineItemContextMenuModifier(
            allowSetCover: allowSetCover,
            onSetCover: onSetCover,
            canEditVisit: onEditVisit != nil,
            onEditVisit: onEditVisit,
            onDelete: onDelete
        ))
    }

    private func mediaCaption(kind: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineKindBadge(text: kind, tone: .orange)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var standardRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeStr)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.65))
                .frame(width: timeColWidth, alignment: .trailing)
                .padding(.top, 4)
            timelineRail
            contentView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, rowBottomPadding)
        .modifier(TimelineItemContextMenuModifier(
            allowSetCover: allowSetCover,
            onSetCover: onSetCover,
            canEditVisit: onEditVisit != nil,
            onEditVisit: onEditVisit,
            onDelete: onDelete
        ))
    }

    private var rowBottomPadding: CGFloat { isLast ? 16 : 6 }

    private var timelineRail: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(dotColor)
                .frame(width: dotSize, height: dotSize)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                .padding(.top, 4)
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: lineWidth)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 4)
            }
        }
        .frame(width: railWidth)
    }

    @ViewBuilder
    private var contentView: some View {
        switch item {
        case .visit(let v, let dur):
            VStack(alignment: .leading, spacing: 4) {
                TimelineKindBadge(text: "場所", tone: .accent)
                Text(v.name)
                    .font(.system(size: 16, weight: .semibold))
                if let d = dur, d > 60 {
                    Text(durationLabel(d))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .timelineCard()

        case .mobility(let m):
            VStack(alignment: .leading, spacing: 4) {
                TimelineKindBadge(text: m.label, tone: mobilityTone(m.mode))
                Text(m.detail)
                    .font(.system(size: 16, weight: .semibold))
            }
            .timelineCard()

        case .memo(let m):
            VStack(alignment: .leading, spacing: 6) {
                if let kg = WeightMemoParser.parse(m.text) {
                    TimelineKindBadge(text: WeightMemoParser.displayLabel(kg: kg), tone: .teal)
                } else if m.source == "mac" || m.mediaKind != nil {
                    TimelineKindBadge(
                        text: m.timelineLabel,
                        tone: m.mediaKind == "image" || m.mediaKind == "video" ? .orange : .neutral
                    )
                }
                if !m.timelineDetail.isEmpty {
                    Text(m.source == "mac" ? m.timelineDetail : m.text)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if m.editedAt != nil {
                    Text("編集済み").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .timelineCard()

        case .macSnapshot(let label, let detail, _):
            VStack(alignment: .leading, spacing: 6) {
                TimelineKindBadge(text: label, tone: label == "写真" ? .orange : .neutral)
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .timelineCard()

        case .mac(let a):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: a.kind == "hermes" ? "brain.head.profile" : "desktopcomputer")
                        .font(.system(size: 13))
                        .foregroundStyle(a.kind == "hermes" ? Color.purple : Color.secondary)
                    TimelineKindBadge(
                        text: a.kind == "hermes" ? "Hermes" : "作業",
                        tone: a.kind == "hermes" ? .purple : .neutral
                    )
                }
                Text(MacWorkFocus.workTitle(for: a))
                    .font(.system(size: 15, weight: .semibold))
                    .lineSpacing(3)
                    .lineLimit(3)
                if let subtitle = MacWorkFocus.subtitle(for: a) {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(durationLabel(a.duration))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .timelineCard(tint: a.kind == "hermes" ? Color.purple.opacity(0.06) : nil)

        case .macSummary(let s):
            macSummaryView(s)

        case .photo:
            EmptyView()
        }
    }

    @ViewBuilder
    private func macSummaryView(_ s: MacActivitySummary) -> some View {
        let visibleApps = expandedMacSummary ? s.apps : Array(s.apps.prefix(3))
        let hermes = s.hasHermes

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13))
                    .foregroundStyle(hermes ? Color.purple : Color.secondary)
                TimelineKindBadge(text: "Mac作業", tone: hermes ? .purple : .neutral)
            }

            ForEach(Array(visibleApps.enumerated()), id: \.offset) { _, app in
                HStack(spacing: 4) {
                    if app.kind == "hermes" {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(app.workTitle) · \(MacActivitySummarizer.formatDuration(app.totalDuration))")
                            .font(.system(size: 14))
                            .foregroundStyle(app.kind == "hermes" ? Color.purple : .primary)
                            .lineLimit(2)
                        if !app.toolName.isEmpty, app.workTitle != app.toolName {
                            Text(app.toolName)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("合計 \(MacActivitySummarizer.formatDuration(s.totalDuration))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if s.rawEntryCount > s.apps.count {
                    Text("\(s.rawEntryCount)件を要約")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            if s.apps.count > 3 {
                Text(expandedMacSummary ? "タップで折りたたむ" : "タップですべて表示")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .timelineCard(tint: hermes ? Color.purple.opacity(0.06) : nil)
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
        case .mobility(let m):
            switch m.mode {
            case .walk: return .green
            case .bike: return .blue
            case .train: return .indigo
            }
        case .memo:                return Color.secondary
        case .mac(let a):          return a.kind == "hermes" ? Color.purple : Color(.systemGray3)
        case .macSummary(let s):   return s.hasHermes ? Color.purple : Color(.systemGray3)
        case .photo:               return .orange
        case .macSnapshot(let label, _, _):
            return label == "写真" ? .orange : Color.accentColor
        }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins)分" }
        let h = mins / 60; let m = mins % 60
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }

    private func mobilityTone(_ mode: MobilityMode) -> TimelineBadgeTone {
        switch mode {
        case .walk: return .teal
        case .bike: return .accent
        case .train: return .purple
        }
    }
}

private struct TimelineItemContextMenuModifier: ViewModifier {
    let allowSetCover: Bool
    let onSetCover: (() -> Void)?
    var canEditVisit: Bool = false
    var onEditVisit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.contextMenu {
            if allowSetCover {
                Button {
                    onSetCover?()
                } label: {
                    Label("表紙にする", systemImage: "book.closed")
                }
            }
            if canEditVisit {
                Button {
                    onEditVisit?()
                } label: {
                    Label("名称を編集", systemImage: "pencil")
                }
            }
            if onDelete != nil {
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
    }
}

private enum TimelineBadgeTone {
    case accent, orange, teal, purple, neutral

    var foreground: Color {
        switch self {
        case .accent: return Color.accentColor
        case .orange: return .orange
        case .teal: return .teal
        case .purple: return .purple
        case .neutral: return .secondary
        }
    }

    var background: Color { foreground.opacity(0.12) }
}

private struct TimelineKindBadge: View {
    let text: String
    let tone: TimelineBadgeTone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.background)
            .clipShape(Capsule())
    }
}

private extension View {
    func timelineCard(tint: Color? = nil) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(tint ?? Color(.secondarySystemBackground))
            .cornerRadius(12)
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
