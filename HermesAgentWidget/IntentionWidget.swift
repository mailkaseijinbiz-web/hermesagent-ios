import WidgetKit
import SwiftUI

private func intentionURL(_ id: String) -> URL {
    URL(string: "hermesagent://intention/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!
}
private let homeURL = URL(string: "hermesagent://home")!

struct IntentionEntry: TimelineEntry {
    let date: Date
    let snap: IntentionWidgetSnapshot
}

struct IntentionProvider: TimelineProvider {
    func placeholder(in context: Context) -> IntentionEntry {
        IntentionEntry(date: Date(), snap: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (IntentionEntry) -> Void) {
        completion(IntentionEntry(date: Date(), snap: SharedStore.intentionSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IntentionEntry>) -> Void) {
        let entry = IntentionEntry(date: Date(), snap: SharedStore.intentionSnapshot())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static let sample = IntentionWidgetSnapshot(
        vitalHint: "睡眠 7.2h · 安定",
        vitalityMode: "steady",
        cards: [
            IntentionCardSnapshot(id: "s1", title: "今日の1つ", subtitle: "資料を30分", icon: "checklist", kind: "focus"),
            IntentionCardSnapshot(id: "s2", title: "軽く回復", subtitle: "散歩15分", icon: "leaf.fill", kind: "recover")
        ],
        updatedAt: Date().timeIntervalSince1970
    )
}

struct IntentionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: IntentionEntry

    private var card: IntentionCardSnapshot? { entry.snap.cards.first }

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryInline:
            accessoryView
        default:
            smallView
        }
    }

    private var accessoryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let c = card {
                Text(c.title).font(.headline).lineLimit(1)
                Text(c.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("いまの意図").font(.headline)
                Text(entry.snap.vitalHint.isEmpty ? "Hermesを開く" : entry.snap.vitalHint)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(card.map { intentionURL($0.id) } ?? homeURL)
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkle").font(.system(size: 11))
                Text("いまの意図").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            if let c = card {
                HStack(spacing: 8) {
                    Image(systemName: c.icon).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(c.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } else {
                Text("タップして開く")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !entry.snap.vitalHint.isEmpty {
                Text(entry.snap.vitalHint)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(12)
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(card.map { intentionURL($0.id) } ?? homeURL)
    }
}

struct HermesIntentionWidget: Widget {
    let kind = "HermesIntentionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IntentionProvider()) { entry in
            IntentionWidgetView(entry: entry)
        }
        .configurationDisplayName("いまの意図")
        .description("バイタルに基づく今日の行動候補。タップで選べます。")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}
