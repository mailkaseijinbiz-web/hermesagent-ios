import Foundation

/// Queued product-metrics events; flushed to the Mac hub when connected.
@MainActor
final class ProductMetricsClient {
    static let shared = ProductMetricsClient()

    private static let queueKey = "productMetricsPendingEvents"

    private struct PendingEvent: Codable {
        var name: String
        var ts: Double
        var props: [String: String]
        var source: String
    }

    private var queue: [PendingEvent] = []

    private init() {
        loadQueue()
    }

    func track(name: String, props: [String: String] = [:], source: String = "ios") {
        queue.append(PendingEvent(
            name: name,
            ts: Date().timeIntervalSince1970,
            props: props,
            source: source
        ))
        persistQueue()
    }

    func flush(apiClient: APIClient) async {
        guard !queue.isEmpty else { return }
        let batch = queue
        do {
            try await apiClient.postMetricsEvents(batch.map { ev in
                [
                    "name": ev.name,
                    "ts": ev.ts,
                    "props": ev.props,
                    "source": ev.source,
                ] as [String: Any]
            })
            queue.removeAll()
            persistQueue()
        } catch {
            // keep queue for next connect
        }
    }

    // MARK: - Persistence

    private func loadQueue() {
        guard let data = UserDefaults.standard.data(forKey: Self.queueKey),
              let decoded = try? JSONDecoder().decode([PendingEvent].self, from: data) else { return }
        queue = decoded
    }

    private func persistQueue() {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
    }
}
