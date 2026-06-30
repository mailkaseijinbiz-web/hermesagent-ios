import SwiftUI
import Combine
import UIKit
import WidgetKit
import UserNotifications
import ActivityKit

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
    /// The AI employee that owns this chat (from the Mac's sessionOwner map); "" / nil = 全体.
    var employeeId: String? = nil

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

    // Selected tab (legacy; UI is now chat-centric with a side drawer).
    @Published var selectedTab: Tab = .chat
    // Claude-style left drawer (history + new chat + settings/automations).
    @Published var showDrawer = false

    // Bottom tab bar (footer): ホーム / 社員 / ニュース / アプリ.
    enum MainTab: Hashable { case home, employees, tasks, news, apps }
    @Published var tab: MainTab = .home

    // Secondary modal screens go through ONE enum-driven `.sheet(item:)` (multiple `.sheet`
    // modifiers on the same view collide). 社員/アプリ are tabs now, not sheets.
    enum ActiveSheet: Identifiable, Equatable {
        case settings, automations, profile, selfResources, apps
        case employee(String)
        case appWeb(AppProject)
        var id: String {
            switch self {
            case .settings:      return "settings"
            case .automations:   return "automations"
            case .profile:       return "profile"
            case .selfResources: return "selfResources"
            case .apps:          return "apps"
            case .employee(let eid): return "employee-\(eid)"
            case .appWeb(let a):     return "appWeb-\(a.id)"
            }
        }
    }
    @Published var activeSheet: ActiveSheet? = nil
    // Bumped when a push tap should scroll the open chat to its newest message.
    @Published var pushScrollToken = UUID()

    // TOP is a Mac-style dashboard (HomeView); the chat thread is a pushed leaf via
    // NavigationStack(.navigationDestination(isPresented:)).
    @Published var showingChat = false
    /// Prefill for ChatView when opening from an intention card deep link.
    @Published var pendingChatPrompt: String? = nil

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

    // Live Activity (Dynamic Island)
    private var liveActivity: Activity<HermesActivityAttributes>?

    // Sessions
    @Published var sessions: [Session] = []
    // AI employees (company parity) — fetched from the Mac hub.
    @Published var employees: [MobileEmployee] = []
    @Published var activeEmployeeId: String? = UserDefaults.standard.string(forKey: "activeEmployeeId") {
        didSet {
            UserDefaults.standard.set(activeEmployeeId, forKey: "activeEmployeeId")
            updateWidgetSnapshot()   // keep the per-employee widget in sync with the active pick
        }
    }
    var activeEmployee: MobileEmployee? { employees.first { $0.id == activeEmployeeId } }

    /// Sessions to show in the drawer/list: the active employee's chats (incl. the
    /// currently-open one, which may not be owned yet), or — when no employee is active
    /// (全体) — chats not owned by any employee. Mirrors the Mac hub's `visibleSessions`.
    var visibleSessions: [Session] {
        if let eid = activeEmployeeId {
            return sessions.filter { ($0.employeeId ?? "") == eid || $0.id == currentSessionId }
        }
        return sessions.filter { ($0.employeeId ?? "").isEmpty }
    }

    /// Employees ordered for display: マネージャー float to the top, everyone else keeps
    /// their existing order. Mirrors the Mac hub's ordering so both ends match.
    var sortedEmployees: [MobileEmployee] {
        employees.filter { $0.role == "manager" } + employees.filter { $0.role != "manager" }
    }
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
        if let cached = loadCachedIntention() {
            self.intentionToday = cached
            publishIntentionWidget()
        }
    }

    /// Auto-connect on launch when we already have a server URL (skips QR/manual entry).
    func autoConnectIfPossible() async {
        guard !isConnected, !isConnecting, !serverURL.isEmpty else { return }
        await connect()
    }

    // MARK: - Push

    func setupPush() {
        // Let the location/photos loggers push summaries through our authed API client.
        LocationManager.shared.apiClient = apiClient
        PhotosManager.shared.apiClient = apiClient
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
        showingChat = true   // surface the chat thread over the home dashboard
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

    /// Clear the app-icon badge: zero it locally and reset the Mac's per-device counter
    /// (the user is now looking at the app, so the "updates" indicator is consumed).
    func clearAppBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
        guard isConnected, let token = PushManager.shared.deviceToken else { return }
        Task { await apiClient.clearBadge(token: token) }
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
        await fetchEmployees()
        await fetchApps()        // keep the home tiles + apps widget fresh
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

    func fetchEmployees() async {
        do {
            let fresh = try await apiClient.fetchEmployees()
            employees = fresh
            // Drop a stale selection if that employee no longer exists on the Mac.
            // Start a fresh session too (the open one was scoped to the deleted
            // employee) — but never yank the session out from under an in-flight turn.
            if let aid = activeEmployeeId, !fresh.contains(where: { $0.id == aid }) {
                activeEmployeeId = nil
                if !isStreaming { newSession() }
            }
            updateWidgetSnapshot()   // publish the fresh roster to the per-employee widget
        } catch {
            // offline / not supported by an older Mac build → keep current roster
        }
    }

    /// Switch the active employee (or clear it with nil) and start a fresh conversation.
    /// The single funnel every picker goes through. No-op while a turn is streaming —
    /// switching mid-stream would wipe the in-flight session and orphan the response.
    func switchEmployee(_ id: String?) {
        guard !isStreaming else { return }
        activeEmployeeId = id
        newSession()
    }

    // MARK: - Employee-first navigation (home dashboard → chat thread)

    // MARK: - Employee unread badge tracking

    /// Last time the user viewed each employee (keyed by employee id). Persisted in UserDefaults.
    @Published var employeeLastViewed: [String: Date] = {
        guard let data = UserDefaults.standard.data(forKey: "employeeLastViewed"),
              let dict = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return dict
    }()

    func markEmployeeViewed(_ id: String) {
        employeeLastViewed[id] = Date()
        if let data = try? JSONEncoder().encode(employeeLastViewed) {
            UserDefaults.standard.set(data, forKey: "employeeLastViewed")
        }
    }

    /// Returns true when the employee's most recent session was updated after the user last viewed them.
    func hasUnreadActivity(_ empId: String) -> Bool {
        let recent = sessions.filter { ($0.employeeId ?? "") == empId }
            .compactMap { $0.lastActiveDate }
            .max()
        guard let sessionDate = recent else { return false }
        if let viewedDate = employeeLastViewed[empId] { return sessionDate > viewedDate }
        // Never viewed → show badge only if active within the last 24 h.
        return sessionDate > Date().addingTimeInterval(-86400)
    }

    /// Most recent session for a given employee (for the subtitle preview).
    func recentSession(for empId: String) -> Session? {
        sessions.filter { ($0.employeeId ?? "") == empId }
            .max(by: { ($0.lastActiveDate ?? .distantPast) < ($1.lastActiveDate ?? .distantPast) })
    }

    /// Switch to an employee (or 全体 with nil) and open the chat thread full-screen.
    /// This is the primary action on the home screen — tap a 社員, start talking.
    /// No-op while streaming (matches switchEmployee) so we don't open the wrong session.
    func talkTo(_ id: String?) {
        guard !isStreaming else { return }
        if let id { markEmployeeViewed(id) }
        activeEmployeeId = id
        // Open the most recent session for this employee (or nil-employee = 全体).
        // Fall back to a new session only when there's no history yet.
        if let latest = recentSession(for: id ?? "") {
            switchSession(latest.id)
        } else {
            newSession()
        }
        showingChat = true
    }

    /// Open an existing chat thread full-screen (history selection).
    func openThread(_ sessionId: String) {
        switchSession(sessionId)
        showingChat = true
    }

    /// Start a brand-new chat with the current employee and open it.
    func openNewChat() {
        newSession()
        showingChat = true
    }

    /// Pop back to the home dashboard from the chat thread.
    func goHome() {
        showingChat = false
    }

    // MARK: - Developed apps (open the previewURL in the in-app browser)

    /// Open a developed app's preview in the in-app WebView. Apps with no previewURL
    /// can't be opened yet — surface the apps screen so the user can set one.
    func openApp(_ app: AppProject) {
        if app.previewURL.trimmingCharacters(in: .whitespaces).isEmpty {
            activeSheet = .apps   // no preview URL yet → go to the Apps screen to set one
        } else {
            activeSheet = .appWeb(app)
        }
    }

    /// Open an app from a widget deep link (`hermesagent://app/<id>`). Resolves against
    /// the cached roster, fetching it first if the app isn't loaded yet.
    func openAppFromDeepLink(_ id: String?) {
        guard let id = id, !id.isEmpty, id != "/" else { return }
        if let a = apps.first(where: { $0.id == id }) { openApp(a); return }
        Task {
            await fetchApps()
            if let a = apps.first(where: { $0.id == id }) { openApp(a) }
        }
    }

    /// Activate an employee from a widget deep link (`hermesagent://employee/<id>`)
    /// and start a fresh conversation with them. Safe even before the roster loads —
    /// the selection resolves once `fetchEmployees()` returns. Rejects a path-less id
    /// (e.g. "/" from a malformed URL).
    func activateEmployeeFromDeepLink(_ id: String?) {
        guard let id = id, !id.isEmpty, id != "/" else { return }
        selectedTab = .chat
        talkTo(id)
    }

    // MARK: - Cron / automations

    @Published var cronJobs: [CronJob] = []
    @Published var isLoadingCron = false

    // MARK: - Structured output (News multi-mode) — chat-side

    /// Output view mode for the chat screen (チャット/ニュース/要約/タイムライン/テーブル). Persisted.
    @Published var chatOutputMode: OutputViewMode =
        OutputViewMode(rawValue: UserDefaults.standard.string(forKey: "chatOutputMode") ?? "") ?? .chat {
        didSet { UserDefaults.standard.set(chatOutputMode.rawValue, forKey: "chatOutputMode") }
    }
    private var _entriesKey: String = ""
    private var _entriesCache: [NewsEntry] = []

    /// Memoized parse of the latest non-empty assistant message in the open conversation.
    var latestAssistantEntries: [NewsEntry] {
        guard let last = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else {
            _entriesKey = ""; _entriesCache = []; return []
        }
        let key = last.id.uuidString + ":\(last.content.count)"
        if key == _entriesKey { return _entriesCache }
        _entriesKey = key
        _entriesCache = NewsParser.parse(last.content)
        return _entriesCache
    }
    var hasStructurableOutput: Bool { !latestAssistantEntries.isEmpty }

    // MARK: - Company data (Dashboard / Schedule / Apps / EmployeeDetail / Gmail)

    @Published var dashboard = DashboardData()
    @Published var intentionToday = IntentionToday()
    @Published var isLoadingIntention = false
    @Published var isRevisingBrief = false   // AIがデイリーブリーフを書き直し中
    @Published var personalProfile = PersonalProfile()   // 好きなもの・目標など（AI助言の基準）
    @Published var selfModel = SelfModel()   // 頭のメモリ割り当て＋稼働時間
    @Published var weeklyReview = ""         // 週次メタ認知レビュー
    @Published var weeklyReviewAt: Double = 0
    @Published var isGeneratingReview = false
    @Published var apps: [AppProject] = []
    @Published var allTasks: [WorkTask] = []
    @Published var employeeTasks: [WorkTask] = []        // for the open EmployeeDetail
    @Published var employeeArtifacts: [Artifact] = []    // for the open EmployeeDetail
    @Published var employeeFiles: [EmployeeFile] = []
    @Published var employeeWorkspaceName: String = ""
    @Published var employeeHasWorkspace: Bool = false

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

    /// Last payload pushed to the widget — used to skip redundant timeline reloads,
    /// which WidgetKit budgets (~tens/day). High-frequency callers (every SSE token,
    /// every send, every resync) would otherwise exhaust the budget and freeze the widget.
    private var lastWidgetSnapshot: SharedStore.Snapshot?
    private var lastIntentionWidget: IntentionWidgetSnapshot?

    /// Publish intention cards to the App Group for Lock Screen / Home Screen widgets.
    func publishIntentionWidget() {
        let cards = intentionToday.cards.map {
            IntentionCardSnapshot(id: $0.id, title: $0.title, subtitle: $0.subtitle,
                                  icon: $0.icon, kind: $0.kind)
        }
        let snap = IntentionWidgetSnapshot(
            vitalHint: intentionToday.vitalHint,
            vitalityMode: intentionToday.vitalityMode,
            cards: cards,
            updatedAt: intentionToday.generatedAt
        )
        SharedStore.saveIntention(snap)
        if snap != lastIntentionWidget {
            lastIntentionWidget = snap
            WidgetCenter.shared.reloadTimelines(ofKind: "HermesIntentionWidget")
        }
    }

    /// Widget deep link: confirm the intention card and open home.
    func confirmIntentionFromDeepLink(_ cardId: String) {
        tab = .home
        guard let card = intentionToday.cards.first(where: { $0.id == cardId }) else {
            Task { await fetchIntention() }
            return
        }
        Task { await confirmIntention(card) }
    }

    func updateWidgetSnapshot() {
        let snaps = sortedEmployees.map {
            EmployeeSnapshot(id: $0.id, name: $0.name, emoji: $0.emoji,
                             roleTitle: $0.roleTitle, accent: $0.accent, model: $0.model)
        }
        let appSnaps = apps.map {
            AppSnapshot(id: $0.id, name: $0.name, status: $0.status.rawValue,
                        assigneeEmoji: $0.assigneeEmoji ?? "", hasURL: !$0.previewURL.isEmpty)
        }
        var next = SharedStore.Snapshot()
        next.connected = isConnected
        next.titles = Array(sessions.map { $0.title }.prefix(8))   // match SharedStore.save's cap
        next.employees = snaps
        next.apps = appSnaps
        next.activeEmployeeId = activeEmployeeId

        // Always persist (so the widget reads fresh data when the system asks)…
        SharedStore.save(connected: next.connected,
                         sessionTitles: next.titles,
                         employees: next.employees,
                         apps: next.apps,
                         activeEmployeeId: next.activeEmployeeId)
        // …but only spend a reload when something the widget renders changed.
        if next != lastWidgetSnapshot {
            lastWidgetSnapshot = next
            WidgetCenter.shared.reloadAllTimelines()
        }
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
        startLiveActivity()

        // Downscale + JPEG-encode to keep the upload small for the HTTP hop.
        let imageBase64 = imageData.flatMap { Self.downscaledJPEGBase64($0, maxDimension: 1536, quality: 0.7) }

        do {
            try await apiClient.sendChat(
                prompt: text, sessionId: currentSessionId, imageBase64: imageBase64,
                employeeId: activeEmployeeId,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self = self else { return }
                        rawAccumulated += chunk
                        self.streamingContent = rawAccumulated
                        let cleaned = self.parseResponseContent(rawAccumulated)
                        if let i = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            self.messages[i].content = cleaned
                        }
                        self.updateLiveActivity(preview: String(cleaned.prefix(80)), toolLabel: "")
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
                        let label = calls.last(where: { $0.status == "in_progress" || $0.status == "pending" })?.title ?? ""
                        self.updateLiveActivity(preview: "", toolLabel: label)
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
        endLiveActivity()

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
        chatOutputMode = .chat   // 新しい会話を開いたら従来のチャット表示から
        // Cache-first: show history instantly and even while the Mac is unreachable.
        messages = LocalCache.loadMessages(sessionId).map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant, content: $0.content, serverId: $0.serverId)
        }
        Task { await syncOpenSession(sessionId) }
    }

    func newSession() {
        currentSessionId = nil
        messages = []
        chatOutputMode = .chat
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

// MARK: - Company data (Dashboard / Schedule / Apps / EmployeeDetail / Gmail)

extension AppState {
    // Dashboard
    func fetchDashboard() async {
        guard isConnected else { return }
        do { dashboard = try await apiClient.fetchDashboard() } catch { /* keep cache */ }
    }

    func fetchIntention() async {
        isLoadingIntention = true
        defer { isLoadingIntention = false }
        if isConnected {
            if let t = try? await apiClient.fetchIntention() {
                intentionToday = t
                cacheIntention(t)
                publishIntentionWidget()
                return
            }
        }
        if intentionToday.cards.isEmpty {
            intentionToday = localIntentionFallback()
            publishIntentionWidget()
        }
    }

    func regenerateIntention() async {
        guard !isLoadingIntention else { return }
        isLoadingIntention = true
        defer { isLoadingIntention = false }
        if isConnected, let t = try? await apiClient.regenerateIntention() {
            intentionToday = t
            cacheIntention(t)
            publishIntentionWidget()
        } else {
            intentionToday = localIntentionFallback()
            publishIntentionWidget()
        }
    }

    func confirmIntention(_ card: IntentionCard) async {
        if isConnected {
            _ = try? await apiClient.confirmIntention(id: card.id)
        } else {
            applyLocalConfirm(card)
        }
        if card.action.type == "chat" {
            if let role = card.action.employeeRole,
               let emp = employees.first(where: { $0.role == role }) {
                talkTo(emp.id)
            } else {
                openNewChat()
            }
            if let prompt = card.action.chatPrompt, !prompt.isEmpty {
                pendingChatPrompt = prompt
            }
        }
        if isConnected {
            await fetchIntention()
            await fetchDashboard()
            if card.action.type == "task" || card.action.type == "markTask" {
                await fetchTasks()
            }
        } else {
            intentionToday.cards.removeAll { $0.id == card.id }
            cacheIntention(intentionToday)
            publishIntentionWidget()
        }
    }

    func dismissIntention(_ card: IntentionCard) async {
        if isConnected, let t = try? await apiClient.dismissIntention(id: card.id) {
            intentionToday = t
            cacheIntention(t)
            publishIntentionWidget()
        } else {
            intentionToday.cards.removeAll { $0.id == card.id }
            localDismissedKinds.insert(card.kind)
            cacheIntention(intentionToday)
            publishIntentionWidget()
        }
    }

    /// Kinds dismissed while offline (not synced to hub).
    private var localDismissedKinds: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "intentionLocalDismissedKinds") ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "intentionLocalDismissedKinds")
        }
    }

    private func cacheIntention(_ t: IntentionToday) {
        if let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: "cachedIntentionToday")
        }
    }

    private func loadCachedIntention() -> IntentionToday? {
        guard let data = UserDefaults.standard.data(forKey: "cachedIntentionToday"),
              let t = try? JSONDecoder().decode(IntentionToday.self, from: data) else { return nil }
        guard Calendar.current.isDateInToday(Date(timeIntervalSince1970: t.generatedAt)) else { return nil }
        return t
    }

    func localIntentionFallback() -> IntentionToday {
        let health = HealthManager.shared
        let loc = LocationManager.shared
        let pending = dashboard.tasks.filter { $0.status == .todo || $0.status == .doing }
        return IntentionFallback.build(
            sleepHours: health.todaySleepHours,
            steps: health.todaySteps,
            exerciseMinutes: 0,
            mindfulMinutes: health.todayMindfulMinutes,
            restingHR: health.todayRestingHR,
            locationSummary: loc.summary,
            likes: personalProfile.likes,
            goals: personalProfile.goals,
            pendingTasks: pending,
            dismissedKinds: Array(localDismissedKinds)
        )
    }

    private func applyLocalConfirm(_ card: IntentionCard) {
        switch card.action.type {
        case "task":
            let title = (card.action.taskTitle ?? card.subtitle).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let now = Date().timeIntervalSince1970
                let t = WorkTask(id: UUID().uuidString, title: title, status: .doing,
                                 createdAt: now, updatedAt: now)
                allTasks.insert(t, at: 0)
            }
        case "markTask":
            if let tid = card.action.taskId, let i = allTasks.firstIndex(where: { $0.id == tid }) {
                allTasks[i].status = .doing
                allTasks[i].updatedAt = Date().timeIntervalSince1970
            }
        default: break
        }
    }

    /// Ask the AI to rewrite the daily brief per a free-text instruction ("チャットで修正").
    func reviseBrief(instruction: String) async {
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !instr.isEmpty, !isRevisingBrief else { return }
        isRevisingBrief = true
        defer { isRevisingBrief = false }
        if let resp = try? await apiClient.updateBrief(instruction: instr, text: nil) {
            dashboard.brief = resp.brief
            dashboard.briefAt = resp.briefAt
        }
    }

    /// Set the daily brief text directly (manual edit).
    func setBrief(text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !t.isEmpty, !isRevisingBrief else { return }
        isRevisingBrief = true
        defer { isRevisingBrief = false }
        if let resp = try? await apiClient.updateBrief(instruction: nil, text: t) {
            dashboard.brief = resp.brief
            dashboard.briefAt = resp.briefAt
        }
    }

    /// Generate a fresh daily reflection (AI rewrites from today's data + profile + health).
    func regenerateBrief() async {
        guard isConnected, !isRevisingBrief else { return }
        isRevisingBrief = true
        defer { isRevisingBrief = false }
        if let resp = try? await apiClient.updateBrief(instruction: nil, text: nil, regenerate: true) {
            dashboard.brief = resp.brief
            dashboard.briefAt = resp.briefAt
        }
    }

    // Personal profile (好きなもの・目標など)
    func fetchProfile() async {
        guard isConnected else { return }
        if let p = try? await apiClient.fetchProfile() { personalProfile = p }
    }
    func saveProfile(_ p: PersonalProfile) async {
        personalProfile = p
        guard isConnected else { return }
        try? await apiClient.updateProfile(p)
    }

    // Self-model (頭のメモリ割り当て＋稼働時間)
    func fetchSelf() async {
        guard isConnected else { return }
        if let m = try? await apiClient.fetchSelf() { selfModel = m }
    }
    func saveSelf(_ m: SelfModel) async {
        selfModel = m
        guard isConnected else { return }
        try? await apiClient.updateSelf(m)
    }

    // Weekly metacognitive review
    func fetchReview() async {
        guard isConnected else { return }
        if let r = try? await apiClient.fetchReview() { weeklyReview = r.review; weeklyReviewAt = r.reviewAt }
    }
    func regenerateReview() async {
        guard isConnected, !isGeneratingReview else { return }
        isGeneratingReview = true
        defer { isGeneratingReview = false }
        if let r = try? await apiClient.regenerateReview() { weeklyReview = r.review; weeklyReviewAt = r.reviewAt }
    }

    // Apps
    func fetchApps() async {
        guard isConnected else { return }
        do { apps = try await apiClient.fetchApps(); updateWidgetSnapshot() } catch {}
    }
    func createApp(name: String, detail: String, assigneeId: String?, previewURL: String, runCommand: String) async {
        try? await apiClient.createApp(name: name, detail: detail, assigneeId: assigneeId, previewURL: previewURL, runCommand: runCommand)
        await fetchApps()
    }
    func updateApp(_ id: String, fields: [String: Any]) async {
        try? await apiClient.updateApp(id: id, fields: fields)
        await fetchApps()
    }
    func deleteApp(_ id: String) async {
        try? await apiClient.deleteApp(id: id)
        await fetchApps()
    }

    /// Ask the Mac to start the app (runs its runCommand) then refresh the roster and open it.
    func launchAndOpenApp(_ app: AppProject) async {
        if let fresh = try? await apiClient.launchApp(id: app.id) {
            if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i] = fresh }
            if !fresh.previewURL.trimmingCharacters(in: .whitespaces).isEmpty {
                activeSheet = .appWeb(fresh)
            }
        } else if !app.previewURL.trimmingCharacters(in: .whitespaces).isEmpty {
            // Fallback: open immediately even if the launch call failed
            activeSheet = .appWeb(app)
        }
        await fetchApps()
    }

    // Tasks
    func fetchTasks() async {
        guard isConnected else { return }
        do { allTasks = try await apiClient.fetchTasks() } catch {}
    }
    func createTask(title: String, assigneeId: String?) async {
        try? await apiClient.createTask(title: title, assigneeId: assigneeId)
        await fetchTasks()
        if let eid = assigneeId { await fetchEmployeeDetail(eid) }
    }
    func setTaskStatus(_ id: String, _ status: TaskStatus, employeeId: String? = nil) async {
        try? await apiClient.updateTask(id: id, fields: ["status": status.rawValue])
        await fetchTasks()
        if let eid = employeeId { await fetchEmployeeDetail(eid) }
    }
    func deleteTask(_ id: String, employeeId: String? = nil) async {
        try? await apiClient.deleteTask(id: id)
        await fetchTasks()
        if let eid = employeeId { await fetchEmployeeDetail(eid) }
    }

    // EmployeeDetail (tasks + artifacts + read-only files)
    func fetchEmployeeDetail(_ employeeId: String) async {
        guard isConnected else { return }
        if let t = try? await apiClient.fetchTasks(employeeId: employeeId) { employeeTasks = t }
        if let a = try? await apiClient.fetchArtifacts(employeeId: employeeId) { employeeArtifacts = a }
        if let f = try? await apiClient.fetchEmployeeFiles(employeeId: employeeId) {
            employeeFiles = f.files
            employeeWorkspaceName = f.workspace
            employeeHasWorkspace = f.hasWorkspace
        }
    }
    func addArtifact(employeeId: String, title: String, kind: ArtifactKind, body: String) async {
        try? await apiClient.createArtifact(employeeId: employeeId, title: title, kind: kind.rawValue, body: body)
        await fetchEmployeeDetail(employeeId)
    }
    func updateArtifact(_ id: String, employeeId: String, title: String?, body: String?) async {
        var f: [String: Any] = [:]
        if let title = title { f["title"] = title }
        if let body = body { f["body"] = body }
        try? await apiClient.updateArtifact(id: id, fields: f)
        await fetchEmployeeDetail(employeeId)
    }
    func deleteArtifact(_ id: String, employeeId: String) async {
        try? await apiClient.deleteArtifact(id: id)
        await fetchEmployeeDetail(employeeId)
    }

    // MARK: - Live Activity (Dynamic Island)

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let emp = activeEmployee
        let attrs = HermesActivityAttributes(
            employeeEmoji: emp?.emoji ?? "✨",
            employeeName: emp?.name ?? "Hermes"
        )
        let state = HermesActivityAttributes.ContentState(isStreaming: true, preview: "", toolLabel: "")
        liveActivity = try? Activity.request(
            attributes: attrs,
            content: .init(state: state, staleDate: nil),
            pushType: nil
        )
    }

    private func updateLiveActivity(preview: String, toolLabel: String) {
        guard let activity = liveActivity else { return }
        let state = HermesActivityAttributes.ContentState(
            isStreaming: true,
            preview: preview,
            toolLabel: toolLabel
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        let state = HermesActivityAttributes.ContentState(isStreaming: false, preview: "", toolLabel: "完了")
        Task {
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(3)))
        }
        liveActivity = nil
    }
}
