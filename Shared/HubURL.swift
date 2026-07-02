import Foundation

/// Normalize hub URLs scanned from QR codes or pasted by the user.
enum HubURL {
    /// Trim whitespace and reduce to `scheme://host:port` (default port 9119).
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if let url = URL(string: s), let host = url.host, !host.isEmpty {
            let scheme = url.scheme ?? "http"
            let port = url.port ?? 9119
            return "\(scheme)://\(host):\(port)"
        }
        if !s.hasPrefix("http://"), !s.hasPrefix("https://") {
            s = "http://\(s)"
        }
        return s
    }
}
