import WidgetKit
import SwiftUI

// MARK: - Timeline

struct HermesEntry: TimelineEntry {
    let date: Date
    let connected: Bool
    let titles: [String]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> HermesEntry {
        HermesEntry(date: Date(), connected: true, titles: ["最近のチャット", "test", "こんにちは", "画像の解析"])
    }

    func getSnapshot(in context: Context, completion: @escaping (HermesEntry) -> Void) {
        let snap = SharedStore.snapshot()
        completion(HermesEntry(date: Date(), connected: snap.connected, titles: snap.titles))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HermesEntry>) -> Void) {
        let snap = SharedStore.snapshot()
        let entry = HermesEntry(date: Date(), connected: snap.connected, titles: snap.titles)
        // Refresh roughly every 30 min; the app also nudges WidgetCenter on changes.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 16, weight: .light))
            Text("Hermes")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Circle()
                .fill(entry.connected ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer()
            Link(destination: URL(string: "hermesagent://newchat")!) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text("新規チャット").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.primary)
            }
        }
        .padding(12)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            Text("最近のチャット")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if entry.titles.isEmpty {
                Spacer()
                Text(entry.connected ? "セッションがありません" : "未接続")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(entry.titles.prefix(7), id: \.self) { title in
                        Link(destination: URL(string: "hermesagent://open")!) {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(title)
                                    .font(.system(size: 13, weight: .light))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
            }

            Link(destination: URL(string: "hermesagent://newchat")!) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text("新規チャット").font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.primary)
            }
        }
        .padding(16)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if entry.titles.isEmpty {
                Text(entry.connected ? "セッションがありません" : "未接続")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.titles.prefix(3), id: \.self) { title in
                        Link(destination: URL(string: "hermesagent://open")!) {
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(title)
                                    .font(.system(size: 12, weight: .light))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }

            Spacer()

            Link(destination: URL(string: "hermesagent://newchat")!) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text("新規チャット").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.primary)
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

// MARK: - Widget

struct HermesAgentWidget: Widget {
    let kind = "HermesAgentWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HermesAgentWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Hermes Agent")
        .description("接続状態と最近のチャット。タップで開きます。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct HermesAgentWidgetBundle: WidgetBundle {
    var body: some Widget {
        HermesAgentWidget()
    }
}
