import SwiftUI

struct NewsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    // 表示モード（AI ニュース）
    @State private var mode: OutputViewMode = .news

    // デイリーブリーフ編集
    @State private var briefDraft = ""
    @State private var editingBrief = false

    // 株価
    @State private var stocks: [StockQuote] = []
    @State private var stocksLoading = false
    @State private var stocksUpdated: Date? = nil

    // サウナニュース
    @State private var saunaNews: [SaunaNewsItem] = []
    @State private var saunaLoading = false

    private var d: DashboardData { appState.dashboard }
    private var entries: [NewsEntry] { appState.latestAssistantEntries }

    var body: some View {
        ZStack {
            newsBackgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    briefSection
                    reviewSection
                    stockSection
                    saunaSection
                    if !entries.isEmpty {
                        Divider().padding(.horizontal, 4)
                        aiSection
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("ニュース")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
        .refreshable { await loadAll() }
        .sheet(isPresented: $editingBrief) { briefEditorSheet }
    }

    private var newsBackgroundGradient: some View {
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
                    Color(.systemBackground),
                    Color.purple.opacity(0.05),
                    Color.orange.opacity(0.04),
                    Color.blue.opacity(0.03),
                    Color(.systemGroupedBackground),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - デイリーブリーフ

    private var briefSection: some View {
        newsCard(title: "今日の振り返り", systemImage: "sparkles", color: .accentColor, titleSize: 20) {
            if d.brief.isEmpty {
                emptyLine("まだ振り返りがありません")
                Button { Task { await appState.regenerateBrief() } } label: {
                    Label(appState.isRevisingBrief ? "生成中…" : "今日の振り返りを生成",
                          systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.14)).foregroundStyle(.tint)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(appState.isRevisingBrief)
            } else {
                NewsProseView(text: d.brief)
                HStack(spacing: 14) {
                    if d.briefAt > 0 {
                        Text(briefTime).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await appState.regenerateBrief() } } label: {
                        Label(appState.isRevisingBrief ? "生成中…" : "再生成",
                              systemImage: "arrow.clockwise")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).disabled(appState.isRevisingBrief)
                    Button { briefDraft = d.brief; editingBrief = true } label: {
                        Label("編集", systemImage: "pencil").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            }
        }
    }

    private var briefEditorSheet: some View {
        NavigationStack {
            TextEditor(text: $briefDraft)
                .font(.system(size: 14)).padding(12)
                .navigationTitle("デイリーブリーフを編集")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("キャンセル") { editingBrief = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            let text = briefDraft
                            editingBrief = false
                            Task { await appState.setBrief(text: text) }
                        }
                    }
                }
        }
    }

    private var briefTime: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm 更新"
        return f.string(from: Date(timeIntervalSince1970: d.briefAt))
    }

    private var reviewSection: some View {
        newsCard(title: "週次メタ認知レビュー", systemImage: "brain.head.profile", color: .purple) {
            if appState.weeklyReview.isEmpty {
                emptyLine("数日〜1週間データがたまると、行動パターンの気づきと来週への提案を作れます。")
                Button { Task { await appState.regenerateReview() } } label: {
                    Label(appState.isGeneratingReview ? "生成中…" : "今週のレビューを生成",
                          systemImage: "brain.head.profile")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.purple.opacity(0.14)).foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(appState.isGeneratingReview)
            } else {
                NewsProseView(text: appState.weeklyReview, context: .weeklyReview)
                HStack {
                    if appState.weeklyReviewAt > 0 {
                        Text(reviewTime).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await appState.regenerateReview() } } label: {
                        Label(appState.isGeneratingReview ? "生成中…" : "再生成",
                              systemImage: "arrow.clockwise")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).disabled(appState.isGeneratingReview)
                }
                .padding(.top, 12)
            }
        }
    }

    private var reviewTime: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm 更新"
        return f.string(from: Date(timeIntervalSince1970: appState.weeklyReviewAt))
    }

    // MARK: - 株価セクション

    private var stockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14)).foregroundStyle(.green)
                Text("ポートフォリオ").font(.system(size: 16, weight: .semibold))
                Spacer()
                if stocksLoading {
                    ProgressView().scaleEffect(0.7)
                } else if let date = stocksUpdated {
                    Text(timeLabel(date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if stocks.isEmpty && !stocksLoading {
                Text(appState.isConnected ? "株価データを取得できませんでした" : "未接続")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardFill).cornerRadius(12)
            } else {
                VStack(spacing: 6) {
                    ForEach(stocks) { q in stockRow(q) }
                }
            }
        }
    }

    private func stockRow(_ q: StockQuote) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(q.ticker).font(.system(size: 14, weight: .semibold))
                Text(q.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(q.price).font(.system(size: 15, weight: .bold))
                Text(q.changePercent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(q.isPositive ? .green : .red)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(cardFill).cornerRadius(12)
    }

    // MARK: - サウナニュースセクション

    private var saunaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🧖").font(.system(size: 15))
                Text("あなたへのニュース").font(.system(size: 16, weight: .semibold))
                Spacer()
                if saunaLoading { ProgressView().scaleEffect(0.7) }
            }
            if saunaNews.isEmpty && !saunaLoading {
                Text(appState.isConnected ? "サウナ情報を取得できませんでした" : "未接続")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardFill).cornerRadius(12)
            } else {
                VStack(spacing: 6) {
                    ForEach(saunaNews) { item in saunaRow(item) }
                }
            }
        }
    }

    private func saunaRow(_ item: SaunaNewsItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            saunaThumbnail(for: item)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let topic = item.topic, !topic.isEmpty {
                        Text(topic)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(4)
                    }
                    if let src = item.source, !src.isEmpty {
                        Text(src)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !item.date.isEmpty {
                        Text(item.date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill).cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: item.link) { UIApplication.shared.open(url) }
        }
    }

    private func saunaThumbnail(for item: SaunaNewsItem) -> some View {
        SaunaNewsThumbnailView(item: item)
    }

    // MARK: - AI ニュースセクション

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(OutputViewMode.structuredCases) { m in
                    Label(m.label, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let emp = appState.activeEmployee {
                HStack(spacing: 6) {
                    Text(emp.emoji)
                    Text(emp.name).font(.system(.subheadline, weight: .semibold))
                    Text("·  \(entries.count)件").font(.caption).foregroundStyle(.secondary)
                }
            }

            StructuredOutputContainer(entries: entries, mode: mode)
        }
    }

    // MARK: - Card shell

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.72)
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.08)
    }

    @ViewBuilder
    private func newsCard<Content: View>(title: String, systemImage: String,
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

    // MARK: - Data loading

    private func loadAll() async {
        async let s: () = loadStocks()
        async let n: () = loadSaunaNews()
        async let b: () = loadBriefAndReview()
        _ = await (s, n, b)
    }

    private func loadBriefAndReview() async {
        guard appState.isConnected else { return }
        await appState.fetchDashboard()
        await appState.fetchReview()
    }

    private func loadStocks() async {
        guard appState.isConnected else { return }
        stocksLoading = true
        if let q = try? await appState.apiClient.fetchStocks() {
            stocks = q
            stocksUpdated = Date()
            SharedStore.saveStocks(q.map {
                StockSnapshot(ticker: $0.ticker, label: $0.label, price: $0.price,
                              change: $0.change, changePercent: $0.changePercent,
                              isPositive: $0.isPositive)
            })
        }
        stocksLoading = false
    }

    private func loadSaunaNews() async {
        guard appState.isConnected else { return }
        saunaLoading = true
        if let items = try? await appState.apiClient.fetchSaunaNews() {
            saunaNews = items
        }
        saunaLoading = false
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm 更新"
        return f.string(from: d)
    }
}

private struct SaunaNewsThumbnailView: View {
    let item: SaunaNewsItem
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.purple.opacity(0.10),
                            Color.orange.opacity(0.08),
                            Color.blue.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: item.id) {
            image = await NewsThumbnailLoader.load(for: item)
        }
    }
}
