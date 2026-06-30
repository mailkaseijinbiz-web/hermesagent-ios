import WidgetKit
import SwiftUI

// MARK: - Deep links

private func appURL(_ id: String) -> URL {
    URL(string: "hermesagent://app/\(id)") ?? URL(string: "hermesagent://apps")!
}
private let appsListURL = URL(string: "hermesagent://apps")!

private func statusColor(_ s: String) -> Color {
    switch s {
    case "building": return .orange
    case "done":     return .green
    default:         return .secondary   // "idea"
    }
}
private func statusTitle(_ s: String) -> String {
    switch s {
    case "building": return "開発中"
    case "done":     return "完成"
    default:         return "構想"
    }
}

// MARK: - Timeline

struct AppsEntry: TimelineEntry {
    let date: Date
    let connected: Bool
    let apps: [AppSnapshot]
}

struct AppsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AppsEntry {
        AppsEntry(date: Date(), connected: true, apps: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (AppsEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AppsEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }

    private func entry() -> AppsEntry {
        let snap = SharedStore.snapshot()
        return AppsEntry(date: Date(), connected: snap.connected, apps: snap.apps)
    }

    static let sample: [AppSnapshot] = [
        AppSnapshot(id: "h", name: "健康管理", status: "done", assigneeEmoji: "🩺", hasURL: true),
        AppSnapshot(id: "t", name: "タスクボード", status: "building", assigneeEmoji: "👩‍💻", hasURL: true),
        AppSnapshot(id: "n", name: "メモ", status: "idea", assigneeEmoji: "📝", hasURL: false)
    ]
}

// MARK: - Views

struct AppsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AppsEntry

    var body: some View {
        switch family {
        case .systemSmall: smallView
        default: listView(limit: family == .systemLarge ? 6 : 3)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 13, weight: .light))
            Text("アプリ").font(.system(size: 15, weight: .semibold))
            Spacer()
            Circle().fill(entry.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
        }
    }

    // Small — count + tap-through to the apps list.
    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 13, weight: .light))
                Spacer()
                Circle().fill(entry.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
            }
            Spacer()
            Text("\(entry.apps.count)").font(.system(size: 34, weight: .bold))
            Text("アプリ").font(.system(size: 13, weight: .semibold))
            Text("タップで一覧").font(.system(size: 10, weight: .light)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(appsListURL)
    }

    // Medium / Large — each app is its own tap target (deep-links open in-app).
    private func listView(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.apps.isEmpty {
                Spacer(minLength: 2)
                Text(entry.connected ? "アプリがありません" : "未接続")
                    .font(.system(size: 12, weight: .light)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(entry.apps.prefix(limit)) { a in appLink(a) }
                }
                Spacer(minLength: 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private func appLink(_ a: AppSnapshot) -> some View {
        Link(destination: appURL(a.id)) {
            HStack(spacing: 8) {
                Circle().fill(statusColor(a.status)).frame(width: 7, height: 7)
                if !a.assigneeEmoji.isEmpty { Text(a.assigneeEmoji).font(.system(size: 13)) }
                Text(a.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: a.hasURL ? "globe" : "hammer")
                    .font(.system(size: 11)).foregroundStyle(a.hasURL ? Color.accentColor : .secondary)
            }
        }
    }
}

// MARK: - Widget

struct HermesAppsWidget: Widget {
    let kind = "HermesAppsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AppsProvider()) { entry in
            AppsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Hermes アプリ")
        .description("開発したアプリを一覧表示。タップでアプリ内ブラウザで開きます。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
