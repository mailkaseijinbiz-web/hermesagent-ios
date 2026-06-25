import Foundation
import SwiftUI

/// One agent tool invocation, streamed from the Mac over the chat SSE
/// (`tool_activity` events). Mirrors the Mac's ACPToolCall. Drives the iOS
/// activity cards (rich relay / H1完遂).
struct ACPToolCall: Identifiable, Equatable, Codable {
    let id: String          // toolCallId
    var title: String       // "terminal: echo hi" / "read: /path"
    var kind: String        // execute | read | edit | fetch | search | think | other
    var status: String      // pending | in_progress | completed | failed
    var locations: [String] // file paths
    var input: String       // command/args text
    var output: String      // result text

    var symbol: String {
        switch kind {
        case "execute": return "terminal"
        case "read":    return "doc.text"
        case "edit":    return "pencil"
        case "fetch":   return "globe"
        case "search":  return "magnifyingglass"
        case "think":   return "brain"
        default:        return "wrench.and.screwdriver"
        }
    }

    var statusColor: Color {
        switch status {
        case "completed": return .green
        case "failed":    return .red
        case "in_progress", "pending": return .orange
        default:          return .secondary
        }
    }

    var statusSymbol: String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "failed":    return "xmark.octagon.fill"
        default:          return "circle.dotted"
        }
    }

    var hasBody: Bool { !input.isEmpty || !output.isEmpty || !locations.isEmpty }
}
