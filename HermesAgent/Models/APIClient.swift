import Foundation

// MARK: - API Errors

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case unauthorized
    case decodingError(Error)
    case streamingError(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "無効なURLです"
        case .invalidResponse:
            return "無効なレスポンスです"
        case .httpError(let code):
            return "HTTPエラー: \(code)"
        case .unauthorized:
            return "認証に失敗しました。許可されたGoogleアカウントでサインインしてください"
        case .decodingError(let error):
            return "デコードエラー: \(error.localizedDescription)"
        case .streamingError(let message):
            return "ストリーミングエラー: \(message)"
        case .notConnected:
            return "サーバーに接続されていません"
        }
    }
}

// MARK: - AI Employee (company parity, served by the Mac hub)

struct MobileEmployee: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let roleTitle: String
    let emoji: String
    let accent: String
    let model: String
    let mode: String
    let blurb: String
}

// MARK: - SSE Event

private struct SSEEvent: Codable {
    let type: String
    let content: String?
    let tokens: Int?
    let calls: [ACPToolCall]?   // for type == "tool_activity"
}

// MARK: - API Client

@MainActor
final class APIClient {
    private weak var appState: AppState?
    private let decoder = JSONDecoder()

    // Reused long-lived session for the SSE event stream (avoids per-reconnect leaks).
    private lazy var eventSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 86400
        return URLSession(configuration: config)
    }()

    init(appState: AppState) {
        self.appState = appState
    }

    private var baseURL: String {
        guard let appState = appState else { return "" }
        var url = appState.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove trailing slash
        while url.hasSuffix("/") {
            url = String(url.dropLast())
        }
        // Add http:// if no scheme
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://\(url)"
        }
        return url
    }

    // MARK: - Status Check

    func checkStatus() async throws -> ServerStatus {
        let data = try await get(path: "/api/status")
        do {
            return try decoder.decode(ServerStatus.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Lightweight liveness probe: is the Mac server (MobileServer :9119) actually up?
    /// Short timeout so the UI reflects the real state quickly.
    func isServerUp() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/status") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        await attachAuth(&req)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    // MARK: - Config

    func fetchConfig() async throws -> ServerConfig {
        let data = try await get(path: "/api/config")
        do {
            return try decoder.decode(ServerConfig.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Sessions

    func fetchSessions() async throws -> [Session] {
        let data = try await get(path: "/api/sessions")
        do {
            let response = try decoder.decode(SessionsResponse.self, from: data)
            return response.sessions
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // AI employee roster (company parity) served by the Mac hub.
    struct EmployeesResponse: Codable { let employees: [MobileEmployee] }
    func fetchEmployees() async throws -> [MobileEmployee] {
        let data = try await get(path: "/api/employees")
        return try decoder.decode(EmployeesResponse.self, from: data).employees
    }

    struct SessionMessagesResponse: Codable {
        struct Msg: Codable { let id: Int64; let role: String; let content: String; let timestamp: Double }
        let sessionId: String
        let messages: [Msg]
        let messageCount: Int
    }

    /// Full (after == nil) or incremental (after == lastSeenId) message history for a session.
    func fetchSessionMessages(_ id: String, after: Int64? = nil) async throws -> SessionMessagesResponse {
        var path = "/api/sessions/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/messages"
        if let after = after { path += "?after=\(after)" }
        let data = try await get(path: path)
        do { return try decoder.decode(SessionMessagesResponse.self, from: data) }
        catch { throw APIError.decodingError(error) }
    }

    /// Long-lived SSE stream of change tokens from GET /api/events.
    func eventsStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let url = URL(string: "\(baseURL)/api/events") else { throw APIError.invalidURL }
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 3600
                    await attachAuth(&request)

                    let (bytes, response) = try await self.eventSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        continuation.finish(throwing: APIError.unauthorized); return
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let d = json.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let token = obj["token"] as? String else { continue }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func newSession() async throws {
        guard let url = URL(string: "\(baseURL)/api/sessions/new") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        await attachAuth(&request)
        _ = try await URLSession.shared.data(for: request)
    }

    func registerPushToken(_ token: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/push/register") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "platform": "ios"])
        _ = try await URLSession.shared.data(for: request)
    }

    /// Tell the Mac which session this device is viewing in the foreground, so it can
    /// skip pushing that session's notifications here. Best-effort (errors ignored).
    func reportPresence(token: String, sessionId: String?, active: Bool) async {
        guard let url = URL(string: "\(baseURL)/api/presence") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        await attachAuth(&request)
        var body: [String: Any] = ["token": token, "active": active]
        if let sessionId = sessionId { body["sessionId"] = sessionId }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    func deleteSession(_ sessionId: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/sessions/\(sessionId)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        await attachAuth(&request)
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Cron / automations

    func fetchCronJobs() async throws -> [CronJob] {
        let data = try await get(path: "/api/cron")
        struct Resp: Codable { let jobs: [CronJob] }
        return try decoder.decode(Resp.self, from: data).jobs
    }

    func createCronJob(schedule: String, prompt: String, name: String, deliver: String, script: String, noAgent: Bool) async throws {
        guard let url = URL(string: "\(baseURL)/api/cron") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        let body: [String: Any] = ["schedule": schedule, "prompt": prompt, "name": name,
                                   "deliver": deliver, "script": script, "noAgent": noAgent]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: request)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            throw APIError.httpError(h.statusCode)
        }
    }

    func toggleCronJob(id: String, paused: Bool) async throws {
        guard let url = URL(string: "\(baseURL)/api/cron/toggle") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "paused": paused])
        _ = try await URLSession.shared.data(for: request)
    }

    func deleteCronJob(id: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/cron/\(id)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        await attachAuth(&request)
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Chat with SSE Streaming

    func sendChat(prompt: String, sessionId: String?, imageBase64: String? = nil,
                  employeeId: String? = nil,
                  onChunk: @escaping @Sendable (String) -> Void,
                  onThought: @escaping @Sendable (String) -> Void = { _ in },
                  onToolActivity: @escaping @Sendable ([ACPToolCall]) -> Void = { _ in },
                  onDone: @escaping @Sendable (Int?) -> Void = { _ in }) async throws {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        await attachAuth(&request)

        var body: [String: Any] = ["prompt": prompt]
        if let sessionId = sessionId {
            body["sessionId"] = sessionId
        }
        if let imageBase64 = imageBase64 {
            body["image"] = imageBase64
            body["imageType"] = "jpeg"
        }
        if let employeeId = employeeId {
            body["employeeId"] = employeeId
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        // Parse SSE stream. `bytes.lines` decodes UTF-8 correctly across packet
        // boundaries — decoding byte-by-byte (UnicodeScalar(byte)) would treat each
        // byte as Latin-1 and corrupt multi-byte characters (日本語 / box-drawing → â…).
        for try await line in bytes.lines {
            processSSELine(line, onChunk: onChunk, onThought: onThought,
                           onToolActivity: onToolActivity, onDone: onDone)
        }

        session.invalidateAndCancel()
    }

    private func processSSELine(_ line: String,
                                onChunk: (String) -> Void,
                                onThought: (String) -> Void = { _ in },
                                onToolActivity: ([ACPToolCall]) -> Void = { _ in },
                                onDone: (Int?) -> Void = { _ in }) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty lines and comments
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return }

        // Handle SSE "data:" prefix
        var jsonString = trimmed
        if trimmed.hasPrefix("data:") {
            jsonString = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }

        // Skip empty data
        guard !jsonString.isEmpty else { return }

        // Try to parse as JSON
        guard let jsonData = jsonString.data(using: .utf8) else { return }

        do {
            let event = try decoder.decode(SSEEvent.self, from: jsonData)
            switch event.type {
            case "chunk":
                if let content = event.content {
                    onChunk(content)
                }
            case "thought":
                if let content = event.content {
                    onThought(content)
                }
            case "tool_activity":
                if let calls = event.calls {
                    onToolActivity(calls)
                }
            case "done":
                onDone(event.tokens)
            case "error":
                if let content = event.content {
                    onChunk("\n\nエラー: \(content)")
                }
            default:
                break
            }
        } catch {
            // If it's not valid JSON, try treating the whole line as content
            // This handles plain-text streaming responses
            if !jsonString.hasPrefix("{") && !jsonString.hasPrefix("[") {
                onChunk(jsonString)
            }
        }
    }

    // MARK: - Auth

    /// Adds the Google ID token as a Bearer header when signed in.
    private func attachAuth(_ request: inout URLRequest) async {
        if let token = await AuthManager.shared.idToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Generic write helpers (POST / PUT / DELETE)

    /// 健康スナップショット(HealthKit由来)を Mac ハブへ送信。
    func pushHealth(_ json: [String: Any]) async throws {
        try await send("POST", path: "/api/health", json: json)
    }

    @discardableResult
    private func send(_ method: String, path: String, json: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let json = json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        await attachAuth(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }
        return data
    }

    // MARK: - Generic GET

    private func get(path: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        await attachAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        return data
    }

    // expose GET to same-file extension
    func rawGet(_ path: String) async throws -> Data { try await get(path: path) }
    func rawSend(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        try await send(method, path: path, json: json)
    }
}

// MARK: - iOS-parity endpoints (Dashboard / Calendar / Apps / Tasks / Artifacts / Files / Gmail)

extension APIClient {
    // Dashboard
    func fetchDashboard() async throws -> DashboardData {
        try decoder.decode(DashboardData.self, from: await rawGet("/api/dashboard"))
    }

    // Calendar
    private struct EventsResp: Codable { let events: [ScheduleEvent] }
    func fetchCalendar(month: String? = nil) async throws -> [ScheduleEvent] {
        let path = month.map { "/api/calendar?month=\($0)" } ?? "/api/calendar"
        return try decoder.decode(EventsResp.self, from: await rawGet(path)).events
    }
    func createEvent(title: String, date: Double, allDay: Bool, detail: String, assigneeId: String?) async throws {
        var body: [String: Any] = ["title": title, "date": date, "allDay": allDay, "detail": detail]
        if let a = assigneeId { body["assigneeId"] = a }
        try await rawSend("POST", "/api/calendar", json: body)
    }
    func updateEvent(id: String, fields: [String: Any]) async throws {
        try await rawSend("PUT", "/api/calendar/\(enc(id))", json: fields)
    }
    func deleteEvent(id: String) async throws {
        try await rawSend("DELETE", "/api/calendar/\(enc(id))")
    }

    // Apps
    private struct AppsResp: Codable { let apps: [AppProject] }
    func fetchApps() async throws -> [AppProject] {
        try decoder.decode(AppsResp.self, from: await rawGet("/api/apps")).apps
    }
    func createApp(name: String, detail: String, assigneeId: String?, previewURL: String, runCommand: String) async throws {
        var body: [String: Any] = ["name": name, "detail": detail, "previewURL": previewURL, "runCommand": runCommand]
        if let a = assigneeId { body["assigneeId"] = a }
        try await rawSend("POST", "/api/apps", json: body)
    }
    func updateApp(id: String, fields: [String: Any]) async throws {
        try await rawSend("PUT", "/api/apps/\(enc(id))", json: fields)
    }
    func deleteApp(id: String) async throws {
        try await rawSend("DELETE", "/api/apps/\(enc(id))")
    }

    // Tasks
    private struct TasksResp: Codable { let tasks: [WorkTask] }
    func fetchTasks(employeeId: String? = nil) async throws -> [WorkTask] {
        let path = employeeId.map { "/api/tasks?employeeId=\(enc($0))" } ?? "/api/tasks"
        return try decoder.decode(TasksResp.self, from: await rawGet(path)).tasks
    }
    func createTask(title: String, assigneeId: String?) async throws {
        var body: [String: Any] = ["title": title]
        if let a = assigneeId { body["assigneeId"] = a }
        try await rawSend("POST", "/api/tasks", json: body)
    }
    func updateTask(id: String, fields: [String: Any]) async throws {
        try await rawSend("PUT", "/api/tasks/\(enc(id))", json: fields)
    }
    func deleteTask(id: String) async throws {
        try await rawSend("DELETE", "/api/tasks/\(enc(id))")
    }

    // Artifacts
    private struct ArtifactsResp: Codable { let artifacts: [Artifact] }
    func fetchArtifacts(employeeId: String) async throws -> [Artifact] {
        try decoder.decode(ArtifactsResp.self, from: await rawGet("/api/artifacts?employeeId=\(enc(employeeId))")).artifacts
    }
    func createArtifact(employeeId: String, title: String, kind: String, body: String) async throws {
        try await rawSend("POST", "/api/artifacts",
                          json: ["employeeId": employeeId, "title": title, "kind": kind, "body": body])
    }
    func updateArtifact(id: String, fields: [String: Any]) async throws {
        try await rawSend("PUT", "/api/artifacts/\(enc(id))", json: fields)
    }
    func deleteArtifact(id: String) async throws {
        try await rawSend("DELETE", "/api/artifacts/\(enc(id))")
    }

    // Employee files (read-only)
    struct FilesResp: Codable { let hasWorkspace: Bool; let workspace: String; let files: [EmployeeFile] }
    func fetchEmployeeFiles(employeeId: String) async throws -> FilesResp {
        try decoder.decode(FilesResp.self, from: await rawGet("/api/employees/\(enc(employeeId))/files"))
    }

    // Gmail
    private struct ThreadsResp: Codable { let threads: [GmailThreadSummary] }
    private struct ThreadResp: Codable { let thread: GmailThreadDetail }
    func fetchGmailThreads() async throws -> [GmailThreadSummary] {
        try decoder.decode(ThreadsResp.self, from: await rawGet("/api/gmail")).threads
    }
    func fetchGmailThread(_ id: String) async throws -> GmailThreadDetail {
        try decoder.decode(ThreadResp.self, from: await rawGet("/api/gmail/\(enc(id))")).thread
    }
    func sendGmail(to: String, subject: String, body: String) async throws {
        try await rawSend("POST", "/api/gmail/send", json: ["to": to, "subject": subject, "body": body])
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
