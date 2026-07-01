import Foundation
import UIKit

/// Lightweight HTTP client for POST /api/ingest (Share Extension + photo lifelog).
/// Reads Mac hub URL and optional Bearer token from App Group (`SharedStore`).
enum HermesIngestClient {

    enum IngestError: LocalizedError {
        case noHub
        case badResponse
        case http(Int)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .noHub: return "Macハブに未接続です。Hermesアプリを開いて接続してください。"
            case .badResponse: return "サーバー応答が不正です"
            case .http(let c): return "HTTPエラー: \(c)"
            case .unauthorized: return "認証に失敗しました"
            }
        }
    }

    /// JPEG thumbnail for ingest (small to save bandwidth and Mac storage).
    static func jpegData(from image: UIImage, maxSide: CGFloat = 256, quality: CGFloat = 0.55, maxBytes: Int = 400_000) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSide / size.width, maxSide / size.height, 1)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        var q = quality
        var data = scaled.jpegData(compressionQuality: q)
        while let d = data, d.count > maxBytes, q > 0.25 {
            q -= 0.1
            data = scaled.jpegData(compressionQuality: q)
        }
        guard let data, data.count <= maxBytes else { return nil }
        return data
    }

    static func ingest(
        kind: String,
        url: String? = nil,
        title: String? = nil,
        text: String? = nil,
        note: String? = nil,
        images: [Data] = []
    ) async throws -> String {
        let hub = SharedStore.hubURL().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hub.isEmpty, let endpoint = URL(string: "\(hub)/api/ingest") else {
            throw IngestError.noHub
        }
        var body: [String: Any] = ["kind": kind]
        if let url, !url.isEmpty { body["url"] = url }
        if let title, !title.isEmpty { body["title"] = title }
        if let text, !text.isEmpty { body["text"] = text }
        if let note, !note.isEmpty { body["note"] = note }
        if !images.isEmpty {
            body["images"] = images.prefix(3).map { $0.base64EncodedString() }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = SharedStore.hubBearer(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IngestError.badResponse }
        if http.statusCode == 401 { throw IngestError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw IngestError.http(http.statusCode) }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }
        return "ok"
    }
}
