import ActivityKit
import Foundation

struct HermesActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isStreaming: Bool
        var preview: String        // 返答の冒頭（最大80文字）
        var toolLabel: String      // 実行中ツール名（例: "ファイルを読み込み中"）
    }
    // 固定情報（Activity の生存中は変わらない）
    var employeeEmoji: String
    var employeeName: String
}
