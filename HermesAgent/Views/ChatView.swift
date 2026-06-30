import SwiftUI
import PhotosUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @State private var inputText: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var showOfflineAlert = false
    @State private var showingSessionList = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").font(.system(size: 11))
                    Text("オフライン（キャッシュ表示中）").font(.system(size: 11, weight: .light))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Color(.secondarySystemBackground))
            }

            // 構造化表示の切替（解析可能な出力があるときだけ）
            if appState.hasStructurableOutput {
                OutputModePicker(mode: $appState.chatOutputMode)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            }

            // Messages area — tap anywhere here to dismiss the keyboard
            Group {
                if appState.chatOutputMode != .chat && appState.hasStructurableOutput {
                    ScrollView {
                        StructuredOutputContainer(entries: appState.latestAssistantEntries,
                                                  mode: appState.chatOutputMode)
                            .padding(16)
                    }
                } else if appState.messages.isEmpty {
                    welcomeView
                } else {
                    messageList
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isInputFocused = false
            }

            // Input area
            inputBar
        }
        .alert("未接続", isPresented: $showOfflineAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Macに接続されていません。メッセージを送信するには接続してください。")
        }
        .sheet(isPresented: $showingSessionList) {
            NavigationStack { SessionListView() }
                .environmentObject(appState)
        }
        // 左端からの右スワイプで画面を閉じる（push-back ジェスチャー）
        .simultaneousGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onEnded { v in
                    guard v.startLocation.x < 44,
                          v.translation.width > 70,
                          abs(v.translation.height) < abs(v.translation.width)
                    else { return }
                    appState.showingChat = false
                }
        )
        .navigationTitle("チャット")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Employee picker (company parity): talk as/to an AI employee.
            ToolbarItem(placement: .principal) {
                if !appState.employees.isEmpty {
                    Menu {
                        Button {
                            appState.switchEmployee(nil)
                        } label: {
                            Label("全体（社員なし）",
                                  systemImage: appState.activeEmployeeId == nil ? "checkmark" : "person.crop.circle.dashed")
                        }
                        Divider()
                        ForEach(appState.sortedEmployees) { e in
                            Button {
                                appState.switchEmployee(e.id)
                            } label: {
                                Label("\(e.emoji) \(e.name)（\(e.roleTitle)）",
                                      systemImage: appState.activeEmployeeId == e.id ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(appState.activeEmployee.map { "\($0.emoji) \($0.name)" } ?? "チャット")
                                .font(.system(.subheadline, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSessionList = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16, weight: .light))
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                Button {
                    appState.showingChat = false   // close the full-screen chat, back to the tabs
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                }
            }

        }
        .onChange(of: selectedPhoto) {
            Task {
                if let data = try? await selectedPhoto?.loadTransferable(type: Data.self) {
                    selectedImageData = data
                }
            }
        }
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 20) {
            Spacer()

            if let e = appState.activeEmployee {
                Text(e.emoji).font(.system(size: 52))
                Text(e.name)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.primary)
                Text(e.roleTitle)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.secondary)
                if !e.blurb.isEmpty {
                    Text(e.blurb)
                        .font(.system(.subheadline, weight: .light))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.secondary.opacity(0.6))

                Text("何を作りましょうか？")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)

                Text("メッセージを入力してください")
                    .font(.system(.subheadline, weight: .light))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.messages) { message in
                        MessageBubbleView(message: message, assistantName: assistantLabel,
                                          isLast: message.id == appState.messages.last?.id)
                            .id(message.id)
                    }

                    // Streaming indicator
                    if appState.isStreaming {
                        streamingIndicator
                            .id("streaming-indicator")
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: appState.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let lastMessage = appState.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: appState.messages.last?.content) {
                withAnimation(.easeOut(duration: 0.1)) {
                    if appState.isStreaming {
                        proxy.scrollTo("streaming-indicator", anchor: .bottom)
                    } else if let lastMessage = appState.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            // Push-tap: scroll to the newest message of the opened session.
            .onChange(of: appState.pushScrollToken) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)  // let messages load
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let last = appState.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: - Streaming Indicator

    /// Label shown for the assistant side of the conversation: the active employee's
    /// emoji + name when talking to one, otherwise the generic "Hermes".
    private var assistantLabel: String {
        appState.activeEmployee.map { "\($0.emoji) \($0.name)" } ?? "Hermes"
    }

    private var streamingIndicator: some View {
        HStack(spacing: 10) {
            StreamingDotsView()
                .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)

            // Selected image preview (with remove button)
            if let data = selectedImageData, let uiImage = UIImage(data: data) {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Button {
                            selectedImageData = nil
                            selectedPhoto = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 6, y: -6)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Image picker
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                // Text input
                TextField("メッセージを入力...", text: $inputText, axis: .vertical)
                    .font(.system(.body, weight: .light))
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
                    )
                    .onSubmit {
                        sendMessage()
                    }

                // Send button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Color.primary : Color(.tertiaryLabel))
                }
                .disabled(!canSend)
                .animation(.easeInOut(duration: 0.15), value: canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
    }

    // MARK: - Helpers

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || selectedImageData != nil) && !appState.isStreaming
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || selectedImageData != nil), !appState.isStreaming else { return }

        // Block when offline BEFORE clearing input, so nothing is lost.
        guard appState.isConnected else {
            showOfflineAlert = true
            return
        }

        let image = selectedImageData
        inputText = ""
        selectedImageData = nil
        selectedPhoto = nil
        Task {
            await appState.sendMessage(text, imageData: image)
        }
    }

    private func formatModelName(_ model: String) -> String {
        if let lastSlash = model.lastIndex(of: "/") {
            return String(model[model.index(after: lastSlash)...])
        }
        return model
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    @EnvironmentObject private var appState: AppState
    let message: ChatMessage
    /// Display name for the assistant column (active employee, or "Hermes").
    var assistantName: String = "Hermes"
    var isLast: Bool = false

    var body: some View {
        // Hide the bubble only when it has nothing at all (no text, image, tool
        // activity, or reasoning yet) so only the thinking indicator shows.
        if message.content.isEmpty && message.imageData == nil
            && message.toolCalls.isEmpty && message.thinking.isEmpty {
            EmptyView()
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack(alignment: .top, spacing: 0) {
            // Content
            VStack(alignment: .leading, spacing: 6) {
                // ACP reasoning (collapsible) + tool activity cards (rich relay).
                if message.role == .assistant && !message.thinking.isEmpty {
                    ReasoningView(text: message.thinking)
                }
                if !message.toolCalls.isEmpty {
                    ForEach(message.toolCalls) { call in
                        ToolCallCardView(call: call)
                    }
                }
                if let data = message.imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if !message.content.isEmpty {
                    MarkdownView(text: message.content)
                }

                // Quick-reply chips: tap to pick when the latest reply offers choices.
                if message.role == .assistant, isLast {
                    let choices = MD.choices(message.content)
                    if choices.count >= 2 {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(choices.enumerated()), id: \.offset) { idx, c in
                                Button {
                                    let text = MD.plainChoice(c)
                                    guard !appState.isStreaming, !text.isEmpty else { return }
                                    Task { await appState.sendMessage(text) }
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(idx + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.tint)
                                            .frame(width: 16)
                                        Text(MD.inline(c)).font(.system(size: 14)).foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(Color.accentColor.opacity(0.10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(appState.isStreaming)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(messageBackground)
    }

    @ViewBuilder
    private var messageBackground: some View {
        if message.role == .user {
            Color(.secondarySystemBackground)
                .opacity(0.5)
        } else {
            Color.clear
        }
    }
}

// MARK: - Tool Activity Card (rich relay)

/// One ACP tool invocation: kind icon, title, status, expandable command/result.
struct ToolCallCardView: View {
    let call: ACPToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if call.hasBody { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: call.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(call.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if call.status == "in_progress" || call.status == "pending" {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: call.statusSymbol)
                            .font(.system(size: 11))
                            .foregroundStyle(call.statusColor)
                    }
                    if call.hasBody {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(call.locations, id: \.self) { path in
                        Label(path, systemImage: "doc")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !call.input.isEmpty {
                        Text(call.input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !call.output.isEmpty {
                        if !call.input.isEmpty { Divider() }
                        Text(call.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(call.status == "failed" ? Color.red.opacity(0.85) : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
    }
}

/// Collapsible reasoning (agent_thought_chunk) shown above the reply.
struct ReasoningView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").font(.system(size: 10))
                    Text("思考").font(.system(size: 11, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).opacity(0.5)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Streaming Dots Animation

struct StreamingDotsView: View {
    @State private var animatingDots: [Bool] = [false, false, false]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(animatingDots[index] ? 0.8 : 0.25))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animatingDots[index] ? 1.15 : 0.85)
            }
        }
        .onAppear {
            for index in 0..<3 {
                withAnimation(
                    .easeInOut(duration: 0.5)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.15)
                ) {
                    animatingDots[index] = true
                }
            }
        }
    }
}

// MARK: - Markdown rendering (parity with the Mac app)

/// Lightweight markdown model: splits a reply into fenced code blocks vs prose, and
/// prose into block elements (headings, lists, quotes, tables, paragraphs). Inline
/// markdown (bold/italic/code/links) is rendered per block — `AttributedString`+`Text`
/// alone collapses block boundaries into one run.
enum MD {
    enum Segment { case text(String); case code(lang: String, body: String) }
    enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case ordered(marker: String, text: String)
        case quote(text: String)
        case table(header: [String], rows: [[String]])
        case paragraph(String)
    }

    /// Inline-only markdown, preserving whitespace/newlines within a block.
    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    /// Split a reply on ``` fences.
    static func segments(_ s: String) -> [Segment] {
        guard s.contains("```") else { return [.text(s)] }
        var segs: [Segment] = []; var inCode = false; var lang = ""; var buf: [String] = []
        func flushText() {
            let t = buf.joined(separator: "\n")
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segs.append(.text(t)) }
            buf.removeAll()
        }
        func flushCode() { segs.append(.code(lang: lang, body: buf.joined(separator: "\n"))); buf.removeAll(); lang = "" }
        for line in s.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flushCode(); inCode = false }
                else { flushText(); inCode = true
                    lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            } else { buf.append(line) }
        }
        if inCode { flushCode() } else { flushText() }
        return segs
    }

    static func isTableDelimiter(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        return t.allSatisfy { Set("|:- ").contains($0) }
    }

    static func tableCells(_ raw: String) -> [String] {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []; var para: [String] = []
        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            para.removeAll()
        }
        let lines = s.components(separatedBy: "\n"); var i = 0
        while i < lines.count {
            let raw = lines[i]; let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushPara(); i += 1; continue }
            if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                flushPara()
                let header = tableCells(line); var rows: [[String]] = []; var j = i + 2
                while j < lines.count {
                    let l = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty, l.contains("|") else { break }
                    rows.append(tableCells(l)); j += 1
                }
                out.append(.table(header: header, rows: rows)); i = j; continue
            }
            if let h = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushPara()
                let hashes = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level: min(max(hashes, 1), 6), text: String(line[h.upperBound...]))); i += 1; continue
            }
            if let q = line.range(of: #"^>\s?"#, options: .regularExpression) {
                flushPara(); out.append(.quote(text: String(line[q.upperBound...]))); i += 1; continue
            }
            if let b = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flushPara(); out.append(.bullet(text: String(line[b.upperBound...]))); i += 1; continue
            }
            if let o = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushPara()
                let marker = String(line[line.startIndex..<line.index(before: o.upperBound)]).trimmingCharacters(in: .whitespaces)
                out.append(.ordered(marker: marker, text: String(line[o.upperBound...]))); i += 1; continue
            }
            para.append(raw); i += 1
        }
        flushPara()
        return out
    }

    private static let choiceCues = ["？", "?", "どちら", "どれ", "いずれ", "選んで", "選択", "ご希望", "教えていただけ"]

    /// Trailing run of numbered/bulleted items, treated as selectable choices — but only
    /// when the reply prompts a choice. Returns the choice texts (≥2) or [].
    static func choices(_ content: String) -> [String] {
        guard choiceCues.contains(where: { content.contains($0) }) else { return [] }
        var lastRun: [String] = []; var run: [String] = []
        for block in blocks(content) {
            switch block {
            case .ordered(_, let t): run.append(t)
            case .bullet(let t): run.append(t)
            default: if run.count >= 2 { lastRun = run }; run.removeAll()
            }
        }
        if run.count >= 2 { lastRun = run }
        return lastRun
    }

    /// Plain text for sending a chosen option (strip emphasis/code markers).
    static func plainChoice(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Entry point: renders a message body with fenced code blocks + block-level prose.
struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MD.segments(text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t): MDProseView(text: t)
                case .code(let lang, let body): MDCodeBlockView(language: lang, code: body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MDProseView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MD.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(MD.inline(t))
                        .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                        .foregroundStyle(.primary).textSelection(.enabled)
                case .bullet(let t): row("•", t)
                case .ordered(let m, let t): row(m, t)   // marker already includes "." or ")"
                case .quote(let t):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                        Text(MD.inline(t)).font(.system(size: 15, weight: .light)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                case .table(let header, let rows): MDTableView(header: header, rows: rows)
                case .paragraph(let t):
                    Text(MD.inline(t)).font(.system(.body, weight: .light)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ l: Int) -> CGFloat { l == 1 ? 22 : (l == 2 ? 19 : (l == 3 ? 17 : 16)) }

    private func row(_ marker: String, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker).font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
            Text(MD.inline(t)).font(.system(.body, weight: .light)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct MDTableView: View {
    let header: [String]; let rows: [[String]]
    private var cols: Int { max(header.count, rows.map { $0.count }.max() ?? 0) }
    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { ForEach(0..<cols, id: \.self) { c in cell(c < header.count ? header[c] : "", header: true) } }
            ForEach(rows.indices, id: \.self) { r in
                GridRow { ForEach(0..<cols, id: \.self) { c in cell(c < rows[r].count ? rows[r][c] : "", header: false) } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator).opacity(0.6), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func cell(_ s: String, header: Bool) -> some View {
        Text(MD.inline(s))
            .font(.system(size: 13, weight: header ? .semibold : .regular))
            .foregroundStyle(.primary).multilineTextAlignment(.leading).textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(header ? Color.primary.opacity(0.06) : Color.clear)
            .overlay(Rectangle().stroke(Color(.separator).opacity(0.5), lineWidth: 0.5))
    }
}

struct MDCodeBlockView: View {
    let language: String; let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "コピー済み" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
                    .textSelection(.enabled).padding(10)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator).opacity(0.5), lineWidth: 0.5))
    }
}

#Preview {
    NavigationStack {
        ChatView()
    }
    .environmentObject(AppState())
}
