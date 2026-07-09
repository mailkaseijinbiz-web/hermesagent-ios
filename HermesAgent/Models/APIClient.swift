import HermesShared
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
    let proactiveEnabled: Bool?
    var isProactiveEnabled: Bool { proactiveEnabled ?? false }
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
        do {
            return try decoder.decode(EmployeesResponse.self, from: data).employees
        } catch {
            throw APIError.decodingError(error)
        }
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

    /// Register a Live Activity push token so the Mac can send ActivityKit updates.
    func registerLiveActivityPushToken(_ token: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/push/live-activity-token") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        _ = try await URLSession.shared.data(for: request)
    }

    /// Register a push-to-start token so the Mac can remotely start a Live Activity.
    func registerLiveActivityStartToken(_ token: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/push/live-activity-start-token") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: PushRegistrationPayload.liveActivityStartToken(token))
        _ = try await URLSession.shared.data(for: request)
    }

    /// Register a lifelog Live Activity push token (lock-screen glance updates).
    func registerLifeLogLiveActivityPushToken(_ token: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/push/lifelog-live-activity-token") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        _ = try await URLSession.shared.data(for: request)
    }

    /// Register a lifelog push-to-start token (start glance without opening the app).
    func registerLifeLogLiveActivityStartToken(_ token: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/push/lifelog-live-activity-start-token") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
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

    struct BriefUpdateResponse: Codable { let brief: String; let briefAt: Double }

    /// Modify the dashboard daily brief: `instruction` → AI rewrite, `text` → direct set,
    /// `regenerate` → fresh AI reflection from today's data + profile. Returns the updated brief.
    func updateBrief(instruction: String?, text: String?, regenerate: Bool = false) async throws -> BriefUpdateResponse {
        guard let url = URL(string: "\(baseURL)/api/dashboard/brief") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60   // the AI rewrite can take a while
        await attachAuth(&request)
        var body: [String: Any] = [:]
        if let instruction = instruction { body["instruction"] = instruction }
        if let text = text { body["text"] = text }
        if regenerate { body["regenerate"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decoder.decode(BriefUpdateResponse.self, from: data)
    }

    // MARK: - Personal profile

    func fetchProfile() async throws -> PersonalProfile {
        let data = try await get(path: "/api/profile")
        return try decoder.decode(PersonalProfile.self, from: data)
    }

    func updateProfile(_ p: PersonalProfile) async throws {
        guard let url = URL(string: "\(baseURL)/api/profile") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "likes": p.likes, "goals": p.goals, "values": p.values, "notes": p.notes
        ])
        _ = try await URLSession.shared.data(for: request)
    }

    /// Push today's location footprint: place-name summary + per-place coordinates (for the
    /// map on the user's own private Mac hub).
    func pushLocation(summary: String, points: [[String: Any]] = []) async {
        guard let url = URL(string: "\(baseURL)/api/location") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        await attachAuth(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["summary": summary, "points": points])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Push today's photo metadata summary (counts/places only — never the photos).
    func pushPhotos(summary: String) async {
        guard let url = URL(string: "\(baseURL)/api/photos") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        await attachAuth(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["summary": summary])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Ask the Mac hub to describe a photo (vision). Returns nil when offline or on failure.
    func describePhoto(imageData: Data) async -> String? {
        guard !imageData.isEmpty,
              let url = URL(string: "\(baseURL)/api/photo/describe") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        await attachAuth(&request)
        let body: [String: Any] = ["image": imageData.base64EncodedString()]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["description"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Self-model (memory allocation + work hours)

    func fetchSelf() async throws -> SelfModel {
        let data = try await get(path: "/api/self")
        return try decoder.decode(SelfModel.self, from: data)
    }

    func updateSelf(_ m: SelfModel) async throws {
        guard let url = URL(string: "\(baseURL)/api/self") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONEncoder().encode(m)
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Weekly metacognitive review

    struct ReviewResponse: Codable { let review: String; let reviewAt: Double }

    func fetchReview() async throws -> ReviewResponse {
        let data = try await get(path: "/api/review")
        return try decoder.decode(ReviewResponse.self, from: data)
    }

    func regenerateReview() async throws -> ReviewResponse {
        guard let url = URL(string: "\(baseURL)/api/review") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60   // AI review over 2 weeks of data can take a while
        await attachAuth(&request)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decoder.decode(ReviewResponse.self, from: data)
    }

    // MARK: - Lifelog summary

    struct LifelogSummaryResponse: Codable {
        let summary: String
        let summaryAt: Double
    }

    func fetchLifelogSummary() async throws -> LifelogSummaryResponse {
        let data = try await get(path: "/api/lifelog/summary")
        return try decoder.decode(LifelogSummaryResponse.self, from: data)
    }

    func regenerateLifelogSummary() async throws -> LifelogSummaryResponse {
        guard let url = URL(string: "\(baseURL)/api/lifelog/summary") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        await attachAuth(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }
        return try decoder.decode(LifelogSummaryResponse.self, from: data)
    }

    // MARK: - Evening reflection

    struct EveningReflectionResponse: Codable {
        let oneLiner: String
        let aiReflection: String?
    }

    struct EveningReflectionSaveResponse: Codable {
        let ok: Bool?
    }

    struct EveningReflectionFetchResponse: Codable {
        let dateKey: String
        let reflectionJSON: String
    }

    func generateEveningReflection(
        pickedLabel: String,
        pickedDetail: String,
        feelingText: String
    ) async throws -> EveningReflectionResponse {
        guard let url = URL(string: "\(baseURL)/api/lifelog/evening-reflect") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pickedLabel": pickedLabel,
            "pickedDetail": pickedDetail,
            "feelingText": feelingText,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }
        return try decoder.decode(EveningReflectionResponse.self, from: data)
    }

    func saveEveningReflectionToMac(dateKey: String, reflection: DayEveningReflection) async throws {
        guard let url = URL(string: "\(baseURL)/api/lifelog/evening-reflection/save") else { throw APIError.invalidURL }
        let reflectionData = try JSONEncoder().encode(reflection)
        let reflectionJSON = String(data: reflectionData, encoding: .utf8) ?? "{}"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "dateKey": dateKey,
            "reflectionJSON": reflectionJSON,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }
    }

    func fetchEveningReflection(dateKey: String) async throws -> DayEveningReflection? {
        let data = try await get(path: "/api/lifelog/evening-reflection?date=\(dateKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dateKey)")
        let wrapper = try decoder.decode(EveningReflectionFetchResponse.self, from: data)
        guard let reflectionData = wrapper.reflectionJSON.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(DayEveningReflection.self, from: reflectionData)
    }

    // MARK: - ライフログ正準記録（Macハブの DayRecord）

    /// Macハブが集約した1日の正準ライフログ（タイムバンド・メトリクス・気づき）。
    func fetchDayRecord(dateKey: String) async throws -> DayRecord {
        let q = dateKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dateKey
        let data = try await get(path: "/api/lifelog/day?date=\(q)")
        return try JSONDecoder().decode(DayRecord.self, from: data)
    }

    /// 直近days日分のサマリー行（古い順、今日を含む）。週ヒートマップ用。
    func fetchLifelogRange(days: Int) async throws -> [LifelogRangeDay] {
        let data = try await get(path: "/api/lifelog/range?days=\(days)")
        return try JSONDecoder().decode([LifelogRangeDay].self, from: data)
    }

    /// HealthKit由来の睡眠スパンをハブへ送る（ハブ側DayRecordの睡眠帯に反映）。
    func pushSleep(dateKey: String, start: Double, end: Double, hours: Double) async throws {
        guard let url = URL(string: "\(baseURL)/api/lifelog/sleep") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "dateKey": dateKey,
            "start": start,
            "end": end,
            "hours": hours,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }
    }

    // MARK: - 振り返りコーチ（気分スコア＋AI質問）

    /// 今日のReflectionEntry（AI質問＋既存回答）。質問未生成でもentryは返る。
    func fetchReflectionToday() async throws -> ReflectionEntry {
        let data = try await get(path: "/api/reflection/today")
        return try JSONDecoder().decode(ReflectionEntry.self, from: data)
    }

    /// 回答を保存する（渡したフィールドだけ部分更新）。
    func submitReflectionAnswers(
        dateKey: String, moodScore: Int?, oneLiner: String?, answers: [String: String]
    ) async throws -> ReflectionEntry {
        guard let url = URL(string: "\(baseURL)/api/reflection/answer") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        await attachAuth(&request)
        var body: [String: Any] = ["dateKey": dateKey, "answers": answers]
        if let moodScore { body["moodScore"] = moodScore }
        if let oneLiner { body["oneLiner"] = oneLiner }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }
        return try JSONDecoder().decode(ReflectionEntry.self, from: data)
    }

    /// 直近days日分のエントリ（気分トレンド用、古い順）。
    func fetchReflectionHistory(days: Int = 14) async throws -> [ReflectionEntry] {
        let data = try await get(path: "/api/reflection/history?days=\(days)")
        return try JSONDecoder().decode([ReflectionEntry].self, from: data)
    }

    // MARK: - 自己グラフ差分提案（承認制）

    func fetchSelfGraphProposals() async throws -> [SelfGraphProposal] {
        let data = try await get(path: "/api/self-graph/proposals")
        return try JSONDecoder().decode([SelfGraphProposal].self, from: data)
    }

    func decideSelfGraphProposal(id: String, accept: Bool) async throws -> SelfGraphProposal {
        guard let url = URL(string: "\(baseURL)/api/self-graph/proposals/decide") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "accept": accept])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }
        return try JSONDecoder().decode(SelfGraphProposal.self, from: data)
    }

    // MARK: - Collection

    func fetchCollection() async throws -> [CollectionItem] {
        let data = try await get(path: "/api/collection")
        return try decoder.decode(CollectionResponse.self, from: data).items
    }

    func deleteCollectionItem(id: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/collection/\(id)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        await attachAuth(&request)
        _ = try await URLSession.shared.data(for: request)
    }

    /// Reset this device's push badge counter on the Mac (called when the app is
    /// foregrounded — the user has seen the updates). Best-effort.
    func clearBadge(token: String) async {
        guard let url = URL(string: "\(baseURL)/api/badge/clear") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        await attachAuth(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
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

    /// Adds Bearer auth: Google ID token when signed in, else App Group hub token (Share Extension parity).
    private func attachAuth(_ request: inout URLRequest) async {
        if let token = await AuthManager.shared.idToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let hubToken = SharedStore.hubBearer(), !hubToken.isEmpty {
            request.setValue("Bearer \(hubToken)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Generic write helpers (POST / PUT / DELETE)

    /// 健康スナップショット(HealthKit由来)を Mac ハブへ送信。
    func pushHealth(_ json: [String: Any]) async throws {
        try await send("POST", path: "/api/health", json: json)
    }

    /// メモ由来の体重を Mac ハブへ送信。
    func pushWeightRecord(kg: Double, recordedAt: Double, memoId: String) async throws {
        try await send("POST", path: "/api/health/weight", json: [
            "kg": kg,
            "recordedAt": recordedAt,
            "memoId": memoId,
            "source": "ios-memo"
        ])
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 圏外・Mac未達（URLError）はキャッシュで応答。認証/HTTPエラーは対象外
            if error is URLError, let cached = await HubCache.shared.load(for: path) {
                NotificationCenter.default.post(name: .hubServedFromCache, object: cached.savedAt)
                return cached.data
            }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        await HubCache.shared.save(data, for: path)
        NotificationCenter.default.post(name: .hubServedLive, object: nil)
        return data
    }

    // expose GET to same-file extension
    func rawGet(_ path: String) async throws -> Data { try await get(path: path) }
    @discardableResult
    func rawSend(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        try await send(method, path: path, json: json)
    }

    /// Mutation endpoints that ignore the response body.
    func rawSendVoid(_ method: String, _ path: String, json: [String: Any]? = nil) async throws {
        _ = try await send(method, path: path, json: json)
    }
}

// MARK: - iOS-parity endpoints (Dashboard / Calendar / Apps / Tasks / Artifacts / Files / Gmail)

extension APIClient {
    // Dashboard
    func fetchDashboard() async throws -> DashboardData {
        try decoder.decode(DashboardData.self, from: await rawGet("/api/dashboard"))
    }

    // Intention cards
    func fetchIntention() async throws -> IntentionToday {
        try decoder.decode(IntentionToday.self, from: await rawGet("/api/intention/today"))
    }

    func regenerateIntention() async throws -> IntentionToday {
        try decoder.decode(IntentionToday.self, from: await rawSend("POST", "/api/intention/today"))
    }

    func confirmIntention(id: String) async throws -> [String: Any] {
        let data = try await rawSend("POST", "/api/intention/confirm", json: ["id": id])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["ok": false]
        }
        return obj
    }

    func dismissIntention(id: String) async throws -> IntentionToday {
        try decoder.decode(IntentionToday.self, from: await rawSend("POST", "/api/intention/dismiss", json: ["id": id]))
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
        try await rawSendVoid("POST", "/api/calendar", json: body)
    }
    func updateEvent(id: String, fields: [String: Any]) async throws {
        try await rawSendVoid("PUT", "/api/calendar/\(enc(id))", json: fields)
    }
    func deleteEvent(id: String) async throws {
        try await rawSendVoid("DELETE", "/api/calendar/\(enc(id))")
    }

    // Apps
    private struct AppsResp: Codable { let apps: [AppProject] }
    func fetchApps() async throws -> [AppProject] {
        try decoder.decode(AppsResp.self, from: await rawGet("/api/apps")).apps
    }
    func createApp(name: String, detail: String, assigneeId: String?, previewURL: String, runCommand: String) async throws {
        var body: [String: Any] = ["name": name, "detail": detail, "previewURL": previewURL, "runCommand": runCommand]
        if let a = assigneeId { body["assigneeId"] = a }
        try await rawSendVoid("POST", "/api/apps", json: body)
    }
    func updateApp(id: String, fields: [String: Any]) async throws {
        try await rawSendVoid("PUT", "/api/apps/\(enc(id))", json: fields)
    }
    func deleteApp(id: String) async throws {
        try await rawSendVoid("DELETE", "/api/apps/\(enc(id))")
    }

    /// Tell the Mac hub to launch (or re-launch) an app by running its runCommand.
    @discardableResult
    func launchApp(id: String) async throws -> AppProject? {
        let data = try await rawSend("POST", "/api/apps/\(enc(id))/launch")
        struct R: Codable { let app: AppProject? }
        return (try? decoder.decode(R.self, from: data))?.app
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
        try await rawSendVoid("POST", "/api/tasks", json: body)
    }
    func updateTask(id: String, fields: [String: Any]) async throws {
        try await rawSendVoid("PUT", "/api/tasks/\(enc(id))", json: fields)
    }
    func deleteTask(id: String) async throws {
        try await rawSendVoid("DELETE", "/api/tasks/\(enc(id))")
    }

    // Artifacts
    private struct ArtifactsResp: Codable { let artifacts: [Artifact] }
    func fetchArtifacts(employeeId: String) async throws -> [Artifact] {
        try decoder.decode(ArtifactsResp.self, from: await rawGet("/api/artifacts?employeeId=\(enc(employeeId))")).artifacts
    }
    func createArtifact(employeeId: String, title: String, kind: String, body: String) async throws {
        try await rawSendVoid("POST", "/api/artifacts",
                          json: ["employeeId": employeeId, "title": title, "kind": kind, "body": body])
    }
    func updateArtifact(id: String, fields: [String: Any]) async throws {
        try await rawSendVoid("PUT", "/api/artifacts/\(enc(id))", json: fields)
    }
    func deleteArtifact(id: String) async throws {
        try await rawSendVoid("DELETE", "/api/artifacts/\(enc(id))")
    }

    // Employee files (read-only)
    struct FilesResp: Codable { let hasWorkspace: Bool; let workspace: String; let files: [EmployeeFile] }
    func fetchEmployeeFiles(employeeId: String) async throws -> FilesResp {
        try decoder.decode(FilesResp.self, from: await rawGet("/api/employees/\(enc(employeeId))/files"))
    }

    // ディレクトリ参照（path はワークスペースからの相対パス、空文字 = ルート）
    struct DirResp: Codable { let isDir: Bool; let dirName: String; let files: [EmployeeFile] }
    func fetchEmployeeDir(employeeId: String, path: String) async throws -> DirResp {
        let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try decoder.decode(DirResp.self, from: await rawGet("/api/employees/\(enc(employeeId))/file?path=\(q)"))
    }

    // ファイルをダウンロードして端末の一時ディレクトリに保存し URL を返す
    func downloadEmployeeFile(employeeId: String, path: String) async throws -> URL {
        let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let data = try await rawGet("/api/employees/\(enc(employeeId))/file?path=\(q)")
        let fileName = (path as NSString).lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        try data.write(to: dest, options: .atomic)
        return dest
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
        try await rawSendVoid("POST", "/api/gmail/send", json: ["to": to, "subject": subject, "body": body])
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // Stocks & News
    func fetchStocks() async throws -> [StockQuote] {
        try JSONDecoder().decode([StockQuote].self, from: await rawGet("/api/stocks"))
    }
    func fetchSaunaNews() async throws -> [SaunaNewsItem] {
        try JSONDecoder().decode([SaunaNewsItem].self, from: await rawGet("/api/sauna-news"))
    }

    // Mac activity
    func fetchMacActivity(date: Date = Date()) async throws -> [MacActivityEntry] {
        let key = HomeDateHelpers.dayKey(date)
        return try JSONDecoder().decode([MacActivityEntry].self, from: await rawGet("/api/mac-activity?date=\(key)"))
    }

    func fetchDayHistory(date: Date) async throws -> MacDayRecord {
        let key = HomeDateHelpers.dayKey(date)
        return try decoder.decode(MacDayRecord.self, from: await rawGet("/api/history?date=\(key)"))
    }

    // MARK: - Lifelog memos

    private struct RemoteMemosResponse: Codable {
        struct RemoteMemo: Codable {
            let id: String
            let text: String
            let time: Double
            let source: String?
            let pageTitle: String?
            let mediaKind: String?
            let imageNames: [String]?
        }
        let memos: [RemoteMemo]
    }

    private struct MemoPushResponse: Codable {
        let id: String
    }

    func fetchMemos(date: Date = Date()) async throws -> [LifeLogMemo] {
        let key = HomeDateHelpers.dayKey(date)
        let data = try await get(path: "/api/memos?date=\(key)")
        let resp = try decoder.decode(RemoteMemosResponse.self, from: data)
        return resp.memos.map {
            LifeLogMemo(
                id: $0.id,
                text: $0.text,
                time: Date(timeIntervalSince1970: $0.time),
                source: ($0.source?.isEmpty == false) ? $0.source : "mac",
                pageTitle: $0.pageTitle,
                mediaKind: $0.mediaKind,
                imageNames: $0.imageNames?.filter { !$0.isEmpty }
            )
        }
    }

    /// Mac メモ添付画像を取得（`/api/memo-image`）。
    func fetchMemoImage(fileName: String) async throws -> Data {
        let enc = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileName
        return try await get(path: "/api/memo-image?file=\(enc)")
    }

    func pushMemo(text: String, source: String = "ios", at: Date = Date()) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/memo") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await attachAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "source": source, "time": at.timeIntervalSince1970
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.httpError(http.statusCode)
        }
        return try decoder.decode(MemoPushResponse.self, from: data).id
    }

    // MARK: - Product metrics

    func postMetricsEvents(_ events: [[String: Any]]) async throws {
        try await rawSendVoid("POST", "/api/metrics/events", json: ["events": events])
    }

    func fetchMetricsSummary(days: Int = 7) async throws -> ProductMetricsSummaryResponse {
        try decoder.decode(
            ProductMetricsSummaryResponse.self,
            from: await rawGet("/api/metrics/summary?days=\(days)")
        )
    }
}

// MARK: - Product metrics models

struct ProductMetricsSummaryResponse: Codable, Equatable {
    var computedAt: Double = 0
    var windowDays: Int = 7
    var agencyDays7d: Int = 0
    var nsmPerWeek: Double = 0
    var intentionFitRate: Double = 0
    var syncSuccessRate: Double = 0
    var syncFailureCount: Int = 0
    var growthStage: String = "S0"
    var recommendations: [String] = []
    var eventCount: Int = 0
}

// MARK: - Stock / News models (iOS side)

struct StockQuote: Codable, Identifiable {
    var ticker: String
    var label: String
    var price: String
    var change: String
    var changePercent: String
    var isPositive: Bool
    var id: String { ticker }
}

struct SaunaNewsItem: Codable, Identifiable {
    var title: String
    var link: String
    var date: String
    var source: String?
    var topic: String?
    var sourceURL: String?
    var imageURL: String?
    var id: String { link.isEmpty ? title : link }
}
