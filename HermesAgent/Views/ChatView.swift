import SwiftUI
import PhotosUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @State private var inputText: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var showOfflineAlert = false
    @State private var showSessions = false
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

            // Messages area — tap anywhere here to dismiss the keyboard
            Group {
                if appState.messages.isEmpty {
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
        .navigationTitle("チャット")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .light))
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSessions = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 15, weight: .regular))
                        if let config = appState.serverConfig, let model = config.model {
                            Text(formatModelName(model))
                                .font(.system(.caption2, weight: .light))
                                .lineLimit(1)
                        }
                    }
                }
            }

        }
        .sheet(isPresented: $showSessions) {
            NavigationStack { SessionListView() }
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

            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.secondary.opacity(0.6))

            Text("何を作りましょうか？")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)

            Text("メッセージを入力してください")
                .font(.system(.subheadline, weight: .light))
                .foregroundStyle(.tertiary)

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
                        MessageBubbleView(message: message)
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

    private var streamingIndicator: some View {
        HStack(spacing: 16) {
            // Role label column
            VStack {
                Text("Hermes")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(width: 52, alignment: .leading)

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
    let message: ChatMessage

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
        HStack(alignment: .top, spacing: 16) {
            // Role label column
            VStack {
                Text(roleLabel)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(roleColor)
                Spacer()
            }
            .frame(width: 52, alignment: .leading)

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
                    Text(message.content)
                        .font(.system(.body, weight: .light))
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(messageBackground)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "あなた"
        case .assistant: return "Hermes"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .secondary
        }
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

#Preview {
    NavigationStack {
        ChatView()
    }
    .environmentObject(AppState())
}
