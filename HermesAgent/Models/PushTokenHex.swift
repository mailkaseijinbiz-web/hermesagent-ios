import Foundation

/// Hex-encodes APNs / ActivityKit push token bytes for registration with the Mac hub.
enum PushTokenHex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
