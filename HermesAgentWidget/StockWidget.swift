import WidgetKit
import SwiftUI

// MARK: - Timeline

struct StockEntry: TimelineEntry {
    let date: Date
    let stocks: [StockSnapshot]
    let connected: Bool
}

struct StockProvider: TimelineProvider {
    func placeholder(in context: Context) -> StockEntry {
        StockEntry(date: Date(), stocks: Self.sample, connected: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (StockEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StockEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }

    private func entry() -> StockEntry {
        let snap = SharedStore.snapshot()
        return StockEntry(date: Date(), stocks: snap.stocks, connected: snap.connected)
    }

    static let sample: [StockSnapshot] = [
        StockSnapshot(ticker: "SPCX", label: "Space Exploration", price: "165.55", change: "+12.30", changePercent: "+8.04%", isPositive: true),
        StockSnapshot(ticker: "GOOG", label: "Alphabet C", price: "351.64", change: "+17.80", changePercent: "+5.06%", isPositive: true)
    ]
}

// MARK: - Views

struct StockWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StockEntry

    var body: some View {
        switch family {
        case .systemSmall: smallView
        default: listView
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)
            Text("株価").font(.system(size: 15, weight: .semibold))
            Spacer()
            Circle().fill(entry.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
        }
    }

    // Small — 最初の1銘柄のみ
    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 13)).foregroundStyle(.green)
                Spacer()
                Circle().fill(entry.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
            }
            Spacer()
            if let s = entry.stocks.first {
                Text(s.ticker).font(.system(size: 16, weight: .bold))
                Text(s.price).font(.system(size: 20, weight: .semibold))
                Text(s.changePercent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(s.isPositive ? .green : .red)
            } else {
                Text(entry.connected ? "データなし" : "未接続")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "hermesagent://news") ?? URL(string: "hermesagent://open")!)
    }

    // Medium / Large — 全銘柄リスト
    private var listView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.stocks.isEmpty {
                Spacer(minLength: 2)
                Text(entry.connected ? "株価データなし" : "未接続")
                    .font(.system(size: 12, weight: .light)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
            } else {
                VStack(spacing: 6) {
                    ForEach(entry.stocks.prefix(family == .systemLarge ? 6 : 3)) { s in
                        stockRow(s)
                    }
                }
                Spacer(minLength: 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "hermesagent://news") ?? URL(string: "hermesagent://open")!)
    }

    private func stockRow(_ s: StockSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.ticker).font(.system(size: 13, weight: .semibold))
                Text(s.label).font(.system(size: 10, weight: .light)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.price).font(.system(size: 13, weight: .bold))
                Text(s.changePercent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(s.isPositive ? .green : .red)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.04)).cornerRadius(8)
    }
}

// MARK: - Widget

struct HermesStockWidget: Widget {
    let kind = "HermesStockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StockProvider()) { entry in
            StockWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Hermes 株価")
        .description("保有銘柄の最新株価を表示します。ニュースタブで更新されます。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
