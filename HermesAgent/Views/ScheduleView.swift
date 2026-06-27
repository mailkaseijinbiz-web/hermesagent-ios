import SwiftUI

/// カレンダー（月グリッド＋当日の予定）。Mac ハブの /api/calendar から取得・作成・削除。
/// Google 由来の予定は赤・読み取り専用。
struct ScheduleView: View {
    @EnvironmentObject private var appState: AppState
    @State private var month: Date = ScheduleView.startOfMonth(Date())
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var showEditor = false

    private let cal = Calendar.current
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdays = ["日", "月", "火", "水", "木", "金", "土"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                monthBar
                weekdayHeader
                grid
                Divider().opacity(0.5)
                dayEvents
            }
            .padding(16)
        }
        .navigationTitle("スケジュール")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                EventEditSheet(day: selectedDay).environmentObject(appState)
            }
        }
        .task { await appState.fetchCalendar(month: monthKey) }
        .onChange(of: month) { _, _ in Task { await appState.fetchCalendar(month: monthKey) } }
        .refreshable { await appState.fetchCalendar(month: monthKey) }
    }

    private var monthBar: some View {
        HStack(spacing: 16) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Text(monthTitle).font(.system(.headline)).frame(minWidth: 120)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
            Button("今日") { month = Self.startOfMonth(Date()); selectedDay = cal.startOfDay(for: Date()) }
                .font(.caption)
            Spacer()
        }
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Text(weekdays[i]).font(.caption2)
                    .foregroundStyle(i == 0 ? .red : (i == 6 ? .blue : .secondary))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                if let day = day { dayCell(day) } else { Color.clear.frame(height: 46) }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let isSel = cal.isDate(day, inSameDayAs: selectedDay)
        let has = !appState.events(on: day).isEmpty
        let wd = cal.component(.weekday, from: day)
        return VStack(spacing: 3) {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 13, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : (wd == 1 ? .red : (wd == 7 ? .blue : .primary)))
            Circle().fill(has ? Color.accentColor : .clear).frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity).frame(height: 46)
        .background(isSel ? Color.accentColor.opacity(0.15) : (isToday ? Color.primary.opacity(0.05) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = day }
    }

    private var dayEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dayTitle).font(.system(.subheadline, weight: .semibold))
                Spacer()
                Button { showEditor = true } label: { Label("追加", systemImage: "plus").font(.caption) }
            }
            let items = appState.events(on: selectedDay)
            if items.isEmpty {
                Text("この日の予定はありません").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ForEach(items) { e in eventRow(e) }
            }
        }
    }

    private func eventRow(_ e: ScheduleEvent) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(e.isGoogle ? Color.red : Color.accentColor).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(e.timeLabel).foregroundStyle(.secondary)
                    if !e.detail.isEmpty { Text("· \(e.detail)").foregroundStyle(.secondary).lineLimit(1) }
                    if e.isGoogle { Text("· Google").foregroundStyle(.secondary) }
                }
                .font(.caption2)
            }
            Spacer()
            if !e.isGoogle {
                Button(role: .destructive) {
                    Task { await appState.deleteEvent(e.id) }
                } label: { Image(systemName: "trash").font(.caption) }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03)).cornerRadius(10)
    }

    // helpers
    private var monthDays: [Date?] {
        let start = Self.startOfMonth(month)
        guard let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let leading = cal.component(.weekday, from: start) - 1
        var cells: [Date?] = Array(repeating: nil, count: max(0, leading))
        for d in range { cells.append(cal.date(byAdding: .day, value: d - 1, to: start)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
    private func shift(_ delta: Int) {
        if let m = cal.date(byAdding: .month, value: delta, to: month) { month = Self.startOfMonth(m) }
    }
    private var monthKey: String {
        let c = cal.dateComponents([.year, .month], from: month)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    private var monthTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年 M月"
        return f.string(from: month)
    }
    private var dayTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M月d日(E)"
        return f.string(from: selectedDay)
    }
    static func startOfMonth(_ d: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }
}

// MARK: - Event editor

struct EventEditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let day: Date

    @State private var title = ""
    @State private var detail = ""
    @State private var allDay = true
    @State private var time = Date()
    @State private var assigneeId: String? = nil
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("タイトル", text: $title)
                TextField("メモ", text: $detail)
            }
            Section {
                Toggle("終日", isOn: $allDay)
                if !allDay {
                    DatePicker("時刻", selection: $time, displayedComponents: .hourAndMinute)
                }
            }
            if !appState.employees.isEmpty {
                Section("担当") {
                    Picker("担当社員", selection: $assigneeId) {
                        Text("なし").tag(String?.none)
                        ForEach(appState.sortedEmployees) { e in
                            Text("\(e.emoji) \(e.name)").tag(String?.some(e.id))
                        }
                    }
                }
            }
        }
        .navigationTitle("予定を追加")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
    }

    private func save() {
        saving = true
        let cal = Calendar.current
        let base = cal.startOfDay(for: day)
        let date: Double
        if allDay {
            date = base.timeIntervalSince1970
        } else {
            let comps = cal.dateComponents([.hour, .minute], from: time)
            date = (cal.date(bySettingHour: comps.hour ?? 9, minute: comps.minute ?? 0, second: 0, of: base) ?? base).timeIntervalSince1970
        }
        Task {
            await appState.addEvent(title: title, date: date, allDay: allDay, detail: detail, assigneeId: assigneeId)
            dismiss()
        }
    }
}
