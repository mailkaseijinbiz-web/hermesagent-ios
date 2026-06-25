import SwiftUI
import Combine
import UIKit
import WidgetKit

// MARK: - Data Models

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    var imageData: Data?
    var serverId: Int64?
    let timestamp: Date
    var toolCalls: [ACPToolCall] = []   // ACP tool activity (rich relay)
    var thinking: String = ""           // ACP reasoning (collapsible)

    init(id: UUID = UUID(), role: MessageRole, content: String, imageData: Data? = nil, serverId: Int64? = nil, timestamp: Date = Date(), toolCalls: [ACPToolCall] = [], thinking: String = "") {
        self.id = id
        self.role = role
        self.content = content
        self.imageData = imageData
        self.serverId = serverId
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.thinking = thinking
    }

    enum MessageRole: String, Equatable {
        case user
        case assistant
    }
}

/// A scheduled automation (cron job), mirrored from the Mac via /api/cron.
struct CronJob: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let schedule: String
    let deliver: String
    let status: String
    let nextRun: String
    let script: String
    let lastRun: String
    var isActive: Bool { status == "active" }
}

// Persisted form for the on-device offline cache.
struct CachedMessage: Codable {
    let serverId: Int64?
    let role: String
    let content: String
}

struct Session: Identifiable, Codable {
    let id: String
    let title: String
    let preview: String
    let lastActive: String
    var source: String? = nil
    var messageCount: Int? = nil
    var lastMessageId: Int64? = nil

    var lastActiveDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: lastActive) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: lastActive)
    }

    var relativeTime: String {
        guard let date = lastActiveDate else { return lastActive }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ServerStatus: Codable {
    let status: String
    let provider: String?
    let model: String?
    let personality: String?
}

struct ServerConfig: Codable {
    let provider: String?
    let model: String?
    let personality: String?
}

struct SessionsResponse: Codable {
    let sessions: [Session]
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable { case chat, automations, settings }

    // Selected tab (chat / automations / settings). Sessions are reached via a sheet.
    @Published var selectedTab: Tab = .chat
    // Bumped when a push tap should scroll the open chat to its newest message.
    @Published var pushScrollToken = UUID()

    // Connection
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var connectionError: String?

    // Server info
    @Published var serverStatus: ServerStatus?
    @Published var serverConfig: ServerConfig?

    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var streamingContent: String = ""

    // Sessions
    @Published var sessions: [Session] = []
    @Published var currentSessionId: String?
    @Published var isLoadingSessions: Bool = false

    // Appearance
    @Published var preferredColorScheme: ColorScheme? = nil

    // API Client
    lazy var apiClient: APIClient = APIClient(appState: self)

    // Default to the Mac's stable Tailscale address so the app can connect
    // without scanning a QR or typing a URL (override in the connect screen).
    #if targetEnvironment(simulator)
    // The simulator shares the Mac's network — reach the local server via localhost
    // (it can't reach the Mac's own Tailscale IP).
    static let defaultServerURL = "http://127.0.0.1:9119"
    #else
    // Tailscale MagicDNS hostname (NOT a raw IP): it always resolves to the Mac's
    // current tailnet IP, so the connection survives IP changes and the user never
    // has to know or manage an address.
    static let defaultServerURL = "http://keitamac-mini.tailfc8906.ts.net:9119"
    #endif

    // Show the main UI (not the connect screen) when connected OR we have cached
    // sessions to browse offline.
    var canShowMain: Bool { isConnected || !sessions.isEmpty }

    private var eventsTask: Task<Void, Never>?
    private var lastSyncToken: String = ""

    init() {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        var resolved = (saved?.isEmpty == false) ? saved! : Self.defaultServerURL
        // Migrate older saves that pinned the raw tailnet IP to the stable MagicDNS
        // hostname, so the connection keeps working transparently if the IP changes.
        if resolved.contains("100.127.89.51") { resolved = Self.defaultServerURL }
        self.serverURL = resolved
        // Show cached sessions immediately (works offline / before connect).
        self.sessions = LocalCache.loadSessions()
    }

    /// Auto-connect on launch when we already have a server URL (skips QR/manual entry).
    func autoConnectIfPossible() async {
        guard !isConnected, !isConnecting, !serverURL.isEmpty else { return }
        await connect()
    }

    // MARK: - Push

    func setupPush() {
        PushManager.shared.registerHandler = { [weak self] in
            Task { await self?.registerPushTokenIfAvailable() }
        }
        // Tapping a notification jumps to that session at its newest message.
        PushManager.shared.openSessionHandler = { [weak self] sessionId in
            self?.openSessionFromPush(sessionId)
        }
        PushManager.shared.configure()
    }

    /// Open the session a push notification refers to, on the chat tab, scrolled
    /// to the newest message (the relevant position the push is about).
    func openSessionFromPush(_ sessionId: String) {
        selectedTab = .chat
        if currentSessionId != sessionId {
            switchSession(sessionId)
        } else {
            // Already open — just (re)sync so the new message is present.
            Task { await syncOpenSession(sessionId) }
        }
        pushScrollToken = UUID()   // nudge ChatView to scroll to the latest message
    }

    func registerPushTokenIfAvailable() async {
        guard isConnected, let token = PushManager.shared.deviceToken else { return }
        try? await apiClient.registerPushToken(token)
    }

    // MARK: - Actions

    func connect() async {
        guard !serverURL.isEmpty else {
            connectionError = "サーバーURLを入力してください"
            return
        }

        isConnecting = true
        connectionError = nil

        do {
            let status = try await apiClient.checkStatus()
            serverStatus = status
            isConnected = true

            // Fetch config and sessions after connecting
            async let configTask: () = fetchConfig()
            async let sessionsTask: () = fetchSessions()
            _ = await (configTask, sessionsTask)
            startEvents()
            startHealthMonitor()
            startPresenceReporting()
            await registerPushTokenIfAvailable()
        } catch {
            connectionError = connectionErrorMessage(for: error)
            isConnected = false
        }

        isConnecting = false
    }

    func disconnect() {
        stopEvents()
        stopHealthMonitor()
        stopPresenceReporting()
        isConnected = false
        serverStatus = nil
        serverConfig = nil
        messages = []
        sessions = []
        currentSessionId = nil
        connectionError = nil
        updateWidgetSnapshot()
    }

    // MARK: - Real-time sync (SSE)

    func startEvents() {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            var delay: UInt64 = 0
            while !Task.isCancelled {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self, self.isConnected else { break }
                // Force a fresh pull on every (re)connection — the change-token path
                // only fires on a NEW token, so a reconnect after the Mac restarted
                // (or after backgrounding) would otherwise leave the open session stale.
                await self.resyncNow()
                do {
                    for try await token in self.apiClient.eventsStream() {
                        delay = 0   // healthy stream → reset backoff
                        await self.handleChange(token: token)
                    }
                } catch {
                    // stream errored → reconnect with backoff
                }
                // Exponential backoff with jitter, capped at 30s.
                let base: UInt64 = delay == 0 ? 3_000_000_000 : min(delay * 2, 30_000_000_000)
                delay = base + UInt64.random(in: 0...500_000_000)
            }
            await MainActor.run { [weak self] in self?.eventsTask = nil }
        }
    }

    func stopEvents() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    // MARK: - Connection health (reflect whether the Mac server is actually up)

    private var healthTask: Task<Void, Never>?

    /// Poll the Mac server's liveness so `isConnected` mirrors reality: when the Mac
    /// mini's server stops (app closed/restarted) the phone shows offline within a few
    /// seconds; when it comes back, the phone reconnects + resyncs automatically.
    func startHealthMonitor() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let up = await self.apiClient.isServerUp()
                if up != self.isConnected {
                    self.isConnected = up
                    self.updateWidgetSnapshot()
                    if up {
                        // Server came back → reconnect the SSE stream and pull fresh state.
                        self.startEvents()
                        await self.fetchConfig()
                        await self.resyncNow()
                    } else {
                        // Server went down → drop the dead stream; keep showing cache.
                        self.stopEvents()
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopHealthMonitor() {
        healthTask?.cancel()
        healthTask = nil
    }

    // MARK: - Presence (suppress push for the session this device is viewing)

    private var presenceTask: Task<Void, Never>?

    /// While foregrounded, periodically tell the Mac which session is open here so it
    /// won't push that session's updates to this device (the user already sees them).
    func startPresenceReporting() {
        guard presenceTask == nil else { return }
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.reportPresence(active: true)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopPresenceReporting() {
        presenceTask?.cancel()
        presenceTask = nil
        Task { [weak self] in await self?.reportPresence(active: false) }
    }

    private func reportPresence(active: Bool) async {
        guard isConnected, let token = PushManager.shared.deviceToken else { return }
        await apiClient.reportPresence(token: token, sessionId: active ? currentSessionId : nil, active: active)
    }

    /// A change token arrived — pull what changed (session list + open session).
    private func handleChange(token: String) async {
        guard token != lastSyncToken else { return }
        lastSyncToken = token
        await fetchSessions()
        if let sid = currentSessionId {
            await syncOpenSession(sid)
        }
    }

    /// Unconditional refresh of the session list + open conversation (bypasses the
    /// change-token gate). Used on each SSE (re)connect and on foreground.
    func resyncNow() async {
        await fetchSessions()
        if let sid = currentSessionId {
            await syncOpenSession(sid)
        }
    }

    /// Refresh the currently-open session's messages from the server and reconcile.
    /// Safe full re-fetch (the open session is the simple, correct primitive); never
    /// replaces while a send is streaming, to avoid clobbering the in-flight turn.
    func syncOpenSession(_ sessionId: String) async {
        guard isConnected, !isStreaming else { return }
        do {
            let resp = try await apiClient.fetchSessionMessages(sessionId, after: nil)
            guard currentSessionId == sessionId, !isStreaming else { return }
            var serverMsgs = resp.messages.compactMap { m -> ChatMessage? in
                let role: ChatMessage.MessageRole = m.role == "user" ? .user : .assistant
                let content = role == .assistant ? stripNoiseLines(m.content) : m.content
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ChatMessage(role: role, content: content, serverId: m.id)
            }
            // The server (state.db) doesn't persist ACP tool cards / reasoning, so
            // re-attach them from the in-memory messages by content match — otherwise
            // the just-streamed cards vanish when this reconcile replaces the message.
            let activity = messages.filter { $0.role == .assistant && (!$0.toolCalls.isEmpty || !$0.thinking.isEmpty) }
            if !activity.isEmpty {
                for i in serverMsgs.indices where serverMsgs[i].role == .assistant {
                    if let m = activity.first(where: { Self.sameAssistantTurn($0.content, serverMsgs[i].content) }) {
                        serverMsgs[i].toolCalls = m.toolCalls
                        serverMsgs[i].thinking = m.thinking
                    }
                }
            }
            // Merge instead of blind-replace: keep trailing local-only bubbles (serverId==nil,
            // e.g. a just-sent turn the server hasn't persisted yet) that aren't already on the
            // server, so they don't flicker out. They drop off once the server has them.
            let serverContents = Set(serverMsgs.map { $0.content })
            let localPending = messages.filter { $0.serverId == nil && !serverContents.contains($0.content) }
            messages = serverMsgs + localPending
            LocalCache.saveMessages(sessionId, serverMsgs.map {
                CachedMessage(serverId: $0.serverId, role: $0.role == .user ? "user" : "assistant", content: $0.content)
            })
        } catch {
            // keep whatever is shown (cache) on failure
        }
    }

    /// Loose equality so re-attached ACP activity survives minor store/clean diffs.
    static func sameAssistantTurn(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    func fetchConfig() async {
        do {
            serverConfig = try await apiClient.fetchConfig()
        } catch {
            // Config fetch is non-critical
        }
    }

    func fetchSessions() async {
        isLoadingSessions = true
        do {
            let fresh = try await apiClient.fetchSessions()
            sessions = fresh
            LocalCache.saveSessions(fresh)
            // Drop cached histories for sessions deleted on the Mac (reconcile against
            // the authoritative table-backed list, never a partial/failed fetch).
            LocalCache.reconcileDeleted(keeping: Set(fresh.map { $0.id }))
        } catch {
            // offline / error: keep cached sessions
        }
        isLoadingSessions = false
        updateWidgetSnapshot()
    }

    // MARK: - Cron / automations

    @Published var cronJobs: [CronJob] = []
    @Published var isLoadingCron = false

    func fetchCronJobs() async {
        guard isConnected else { return }
        isLoadingCron = true
        do { cronJobs = try await apiClient.fetchCronJobs() } catch { /* keep current */ }
        isLoadingCron = false
    }

    func createCron(schedule: String, prompt: String, name: String, deliver: String, script: String, noAgent: Bool) async -> Bool {
        do {
            try await apiClient.createCronJob(schedule: schedule, prompt: prompt, name: name, deliver: deliver, script: script, noAgent: noAgent)
            await fetchCronJobs()
            return true
        } catch { return false }
    }

    func toggleCron(_ job: CronJob) async {
        try? await apiClient.toggleCronJob(id: job.id, paused: job.isActive)  // active → pause
        await fetchCronJobs()
    }

    func deleteCron(_ job: CronJob) async {
        try? await apiClient.deleteCronJob(id: job.id)
        await fetchCronJobs()
    }

    /// Publish a small snapshot to the App Group and refresh the Home Screen widget.
    func updateWidgetSnapshot() {
        SharedStore.save(connected: isConnected, sessionTitles: sessions.map { $0.title })
        WidgetCenter.shared.reloadAllTimelines()
    }

    func sendMessage(_ text: String, imageData: Data? = nil) async {
        // Fail closed when offline: never create an orphan bubble that a later sync erases.
        guard isConnected else {
            connectionError = "Macに接続されていません。送信できません。"
            return
        }
        messages.append(ChatMessage(role: .user, content: text, imageData: imageData))

        let placeholder = ChatMessage(role: .assistant, content: "")
        messages.append(placeholder)
        // Track by stable id (not index): a concurrent sync/reorder could shift indices.
        let assistantId = placeholder.id

        isStreaming = true
        streamingContent = ""
        var rawAccumulated = ""

        // Downscale + JPEG-encode to keep the upload small for the HTTP hop.
        let imageBase64 = imageData.flatMap { Self.downscaledJPEGBase64($0, maxDimension: 1536, quality: 0.7) }

        do {
            try await apiClient.sendChat(
                prompt: text, sessionId: currentSessionId, imageBase64: imageBase64,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self = self else { return }
                        rawAccumulated += chunk
                        self.streamingContent = rawAccumulated
                        let cleaned = self.parseResponseContent(rawAccumulated)
                        if let i = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            // Show only the cleaned reply; while it's empty (only noise/warnings)
                            // the bubble stays blank so the thinking indicator shows.
                            self.messages[i].content = cleaned
                        }
                    }
                },
                onThought: { [weak self] thought in
                    Task { @MainActor in
                        guard let self = self,
                              let i = self.messages.firstIndex(where: { $0.id == assistantId }) else { return }
                        self.messages[i].thinking += thought
                    }
                },
                onToolActivity: { [weak self] calls in
                    Task { @MainActor in
                        guard let self = self,
                              let i = self.messages.firstIndex(where: { $0.id == assistantId }) else { return }
                        self.messages[i].toolCalls = calls
                    }
                }
            )
        } catch {
            if let i = messages.firstIndex(where: { $0.id == assistantId }), messages[i].content.isEmpty {
                messages[i].content = "エラー: \(error.localizedDescription)"
            }
        }

        // Final parse pass — keep only the cleaned reply (no raw noise fallback).
        // If empty, syncOpenSession below replaces it with the canonical DB content.
        let finalRaw = rawAccumulated
        if let i = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[i].content = parseResponseContent(finalRaw)
        }

        isStreaming = false
        streamingContent = ""

        await fetchSessions()
        if currentSessionId == nil, let first = sessions.first {
            currentSessionId = first.id
        }
        // Pull the canonical persisted turn (gives the assistant msg its serverId)
        // and refresh the offline cache. SSE will also nudge this shortly.
        if let sid = currentSessionId {
            await syncOpenSession(sid)
        }
    }

    func switchSession(_ sessionId: String) {
        currentSessionId = sessionId
        // Cache-first: show history instantly and even while the Mac is unreachable.
        messages = LocalCache.loadMessages(sessionId).map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant, content: $0.content, serverId: $0.serverId)
        }
        Task { await syncOpenSession(sessionId) }
    }

    func newSession() {
        currentSessionId = nil
        messages = []
        Task {
            try? await apiClient.newSession()
        }
    }

    func deleteSession(_ sessionId: String) async {
        do {
            try await apiClient.deleteSession(sessionId)
            if currentSessionId == sessionId { newSession() }
            await fetchSessions()
        } catch {
            // deletion failure is surfaced only via UI if needed
        }
    }

    // MARK: - Content Parsing

    // Mirrors Mac's parseResponseText — strips Hermes CLI banners and ANSI codes
    func parseResponseContent(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        var inResponse = false
        var responseLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("⚕ Hermes") { inResponse = true; continue }
            if inResponse {
                if trimmed.hasPrefix("╰") || trimmed.contains("╯") { break }
                let isBorder = trimmed.range(of: #"^[╭╮╯╰─━⎼➖\s]+$"#, options: .regularExpression) != nil
                if isBorder && trimmed.replacingOccurrences(of: " ", with: "").count >= 10 { break }
                responseLines.append(line)
            }
        }

        var result = responseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result = stripANSI(result)

        if result.isEmpty && !raw.isEmpty {
            var fallback: [String] = []
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.hasPrefix("Query:"), !t.hasPrefix("Initializing agent..."),
                      !t.hasPrefix("Resume this session with:"), !t.hasPrefix("hermes --resume"),
                      !t.hasPrefix("Session:"), !t.hasPrefix("Duration:"), !t.hasPrefix("Messages:"),
                      !t.hasPrefix("↻ Resumed session"), !t.contains("⚕ Hermes"),
                      t.range(of: #"^[╭╮╯╰─━⎼➖\s]+$"#, options: .regularExpression) == nil
                else { continue }
                fallback.append(line)
            }
            result = stripANSI(fallback.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Drop CLI noise (warnings/spinners/status) so it never shows as the reply.
        result = stripNoiseLines(result)

        return result
    }

    /// Remove non-response CLI noise lines (warnings, vision/spinner/status output).
    func stripNoiseLines(_ text: String) -> String {
        let kept = text.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return true }
            if t.hasPrefix("Warning:") { return false }
            if t.contains("Unknown toolsets") { return false }
            if t.hasPrefix("Query:") { return false }
            if t.hasPrefix("Initializing agent") { return false }
            if t.hasPrefix("Resume this session") { return false }
            if t.hasPrefix("hermes --resume") { return false }
            if t.hasPrefix("Session:") || t.hasPrefix("Duration:") || t.hasPrefix("Messages:") { return false }
            if t.hasPrefix("↻") { return false }
            if t.hasPrefix("⚠") { return false }
            if t.contains("👁") || t.contains("vision analysis") { return false }
            if t.contains("⚕ Hermes") { return false }
            return true
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{1B}\[[0-9;]*[mGKHFJABCDn]"#, with: "", options: .regularExpression)
    }

    // MARK: - Helpers

    /// Downscale an image to fit `maxDimension` and return base64-encoded JPEG.
    static func downscaledJPEGBase64(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)?.base64EncodedString()
    }

    private func connectionErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost:
                return "サーバーが見つかりません"
            case .cannotConnectToHost:
                return "サーバーに接続できません"
            case .timedOut:
                return "接続がタイムアウトしました"
            case .notConnectedToInternet:
                return "インターネットに接続されていません"
            default:
                return "接続エラー: \(urlError.localizedDescription)"
            }
        }
        return "接続エラー: \(error.localizedDescription)"
    }
}
