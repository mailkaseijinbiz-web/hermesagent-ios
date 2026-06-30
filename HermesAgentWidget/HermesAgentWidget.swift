import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit

// MARK: - Color(hex:)

private extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(red: Double((v & 0xFF0000) >> 16) / 255,
                      green: Double((v & 0x00FF00) >> 8) / 255,
                      blue: Double(v & 0x0000FF) / 255)
        } else {
            self.init(.gray)
        }
    }
}

// MARK: - Deep links

private func employeeURL(_ id: String) -> URL {
    URL(string: "hermesagent://employee/\(id)") ?? URL(string: "hermesagent://open")!
}
private let newChatURL = URL(string: "hermesagent://newchat")!
private let openURL = URL(string: "hermesagent://open")!

// MARK: - Timeline

struct HermesEntry: TimelineEntry {
    let date: Date
    let connected: Bool
    let titles: [String]
    let employees: [EmployeeSnapshot]
    /// The employee this widget instance shows: the configured one, or the active one.
    let selected: EmployeeSnapshot?
    /// The configured employee id (known from the widget config even when the roster
    /// snapshot hasn't been published yet) — so a configured tile still deep-links right.
    let configuredId: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HermesEntry {
        HermesEntry(date: Date(), connected: true, titles: ["最近のチャット", "test"],
                    employees: Self.sample, selected: Self.sample.first, configuredId: nil)
    }

    func snapshot(for configuration: SelectEmployeeIntent, in context: Context) async -> HermesEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectEmployeeIntent, in context: Context) async -> Timeline<HermesEntry> {
        let entry = entry(for: configuration)
        // Refresh roughly every 30 min; the app also nudges WidgetCenter on changes.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func entry(for configuration: SelectEmployeeIntent) -> HermesEntry {
        let snap = SharedStore.snapshot()
        // Configured employee for THIS instance wins; otherwise track the active one.
        let configuredId = configuration.employee?.id
        let selected: EmployeeSnapshot?
        if let id = configuredId {
            selected = snap.employees.first { $0.id == id }
        } else {
            selected = snap.activeEmployee
        }
        return HermesEntry(date: Date(), connected: snap.connected,
                           titles: snap.titles, employees: snap.employees,
                           selected: selected, configuredId: configuredId)
    }

    static let sample: [EmployeeSnapshot] = [
        EmployeeSnapshot(id: "m", name: "マネージャー", emoji: "🧑‍💼", roleTitle: "マネージャー", accent: "7F77DD", model: "claude-sonnet-4.5"),
        EmployeeSnapshot(id: "e", name: "エンジニア", emoji: "👩‍💻", roleTitle: "エンジニア", accent: "378ADD", model: "openai/gpt-4o-mini"),
        EmployeeSnapshot(id: "r", name: "リサーチャー", emoji: "🔬", roleTitle: "リサーチャー", accent: "1D9E75", model: "gemini-3.5-flash")
    ]
}

// MARK: - Views

struct HermesAgentWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: HermesEntry

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .systemLarge: largeView
        default: mediumView
        }
    }

    // Header: brand (or selected employee) + connection dot.
    private var header: some View {
        HStack(spacing: 6) {
            if let e = entry.selected {
                Text(e.emoji).font(.system(size: 15))
                Text(e.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            } else {
                Image(systemName: "person.2.fill").font(.system(size: 13, weight: .light))
                Text("社員").font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            Circle().fill(entry.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
        }
    }

    // MARK: Small — one employee card (whole tile taps through to their chat)

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Circle().fill(entry.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
            }
            Spacer()
            if let e = entry.selected {
                Text(e.emoji).font(.system(size: 34))
                Text(e.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(e.roleTitle).font(.system(size: 11, weight: .light)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Image(systemName: "person.2.fill").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Text("社員を選択").font(.system(size: 13, weight: .medium))
                Text("長押し→編集").font(.system(size: 10, weight: .light)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .containerBackground(for: .widget) { accentBackground }
        // Prefer the resolved employee; fall back to the configured id so a configured
        // tile still deep-links correctly before the roster snapshot lands.
        .widgetURL((entry.selected?.id ?? entry.configuredId).map { employeeURL($0) } ?? newChatURL)
    }

    // MARK: Medium — selected employee + a couple of roster shortcuts

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.employees.isEmpty {
                emptyRosterMessage
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rosterToShow.prefix(3)) { e in employeeLink(e, compact: true) }
                }
            }
            Spacer(minLength: 2)
            newChatLink(size: 12)
        }
        .padding(14)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    // MARK: Large — full roster, each linking to its own chat

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            Text("社員ごとに会話").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)

            if entry.employees.isEmpty {
                Spacer(); emptyRosterMessage.frame(maxWidth: .infinity, alignment: .center); Spacer()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rosterToShow.prefix(6)) { e in employeeLink(e, compact: false) }
                }
                Spacer(minLength: 4)
            }

            newChatLink(size: 13, filled: true)
        }
        .padding(16)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    // MARK: - Pieces

    /// Roster ordered with the selected employee first (so the configured one leads).
    private var rosterToShow: [EmployeeSnapshot] {
        guard let sel = entry.selected else { return entry.employees }
        return [sel] + entry.employees.filter { $0.id != sel.id }
    }

    private func employeeLink(_ e: EmployeeSnapshot, compact: Bool) -> some View {
        Link(destination: employeeURL(e.id)) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color(hex: e.accent).opacity(0.18))
                        .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                    Text(e.emoji).font(.system(size: compact ? 12 : 14))
                }
                Text(e.name)
                    .font(.system(size: compact ? 12 : 13, weight: entry.selected?.id == e.id ? .semibold : .light))
                    .foregroundStyle(.primary).lineLimit(1)
                if !compact {
                    Text(e.roleTitle).font(.system(size: 10, weight: .light)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
    }

    private func newChatLink(size: CGFloat, filled: Bool = false) -> some View {
        Link(destination: newChatURL) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                Text("新規チャット").font(.system(size: size, weight: .medium))
            }
            .frame(maxWidth: filled ? .infinity : nil)
            .padding(.vertical, filled ? 9 : 0)
            .background(filled ? Color(.secondarySystemBackground) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.primary)
        }
    }

    private var emptyRosterMessage: some View {
        Text(entry.connected ? "社員がいません" : "未接続")
            .font(.system(size: 12, weight: .light)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var accentBackground: some View {
        if let e = entry.selected {
            LinearGradient(colors: [Color(hex: e.accent).opacity(0.22), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            Color(.systemBackground)
        }
    }
}

// MARK: - Widget

struct HermesAgentWidget: Widget {
    let kind = "HermesAgentWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectEmployeeIntent.self, provider: Provider()) { entry in
            HermesAgentWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Hermes 社員")
        .description("AI社員ごとの表示。長押し→編集で表示する社員を選べます。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Live Activity (Dynamic Island)

struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            // ロック画面 / バナー表示
            HStack(spacing: 12) {
                Text(context.attributes.employeeEmoji).font(.system(size: 28))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(context.attributes.employeeName)
                            .font(.system(.subheadline, weight: .semibold))
                        if context.state.isStreaming {
                            ThinkingDotsView()
                        }
                    }
                    if !context.state.toolLabel.isEmpty {
                        Text(context.state.toolLabel)
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(.secondary)
                    } else if !context.state.preview.isEmpty {
                        Text(context.state.preview)
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(14)
            .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                // 展開時
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.employeeEmoji).font(.system(size: 32)).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isStreaming {
                        ThinkingDotsView().padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.employeeName)
                            .font(.system(.subheadline, weight: .semibold))
                        if !context.state.toolLabel.isEmpty {
                            Text(context.state.toolLabel)
                                .font(.system(size: 13, weight: .light))
                                .foregroundStyle(.secondary)
                        } else if !context.state.preview.isEmpty {
                            Text(context.state.preview)
                                .font(.system(size: 13, weight: .light))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                Text(context.attributes.employeeEmoji).font(.system(size: 16))
            } compactTrailing: {
                if context.state.isStreaming {
                    ThinkingDotsView()
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                }
            } minimal: {
                Text(context.attributes.employeeEmoji).font(.system(size: 14))
            }
            .widgetURL(URL(string: "hermesagent://open"))
        }
    }
}

// 3点アニメーション（WidgetKit はアニメーションが使えないため静的表示）
private struct ThinkingDotsView: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
            }
        }
    }
}

@main
struct HermesAgentWidgetBundle: WidgetBundle {
    var body: some Widget {
        HermesAgentWidget()
        HermesIntentionWidget()
        HermesAppsWidget()
        HermesStockWidget()
        HermesLiveActivity()
    }
}
