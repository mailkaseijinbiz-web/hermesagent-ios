import Foundation

struct CollectionItem: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let note: String
    let url: String
    let text: String
    let imageCount: Int
    let source: String
    let createdAt: Double

    var createdDate: Date { Date(timeIntervalSince1970: createdAt) }

    var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f.localizedString(for: createdDate, relativeTo: Date())
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !text.isEmpty { return String(text.prefix(80)) }
        if !url.isEmpty { return url }
        switch kind {
        case "image": return "共有された写真"
        case "video": return "共有された動画"
        default: return "保存されたアイテム"
        }
    }

    var icon: String {
        switch kind {
        case "url":   return "link"
        case "image": return "photo"
        case "video": return "film"
        default:      return "doc.text"
        }
    }
}

struct CollectionResponse: Codable {
    let items: [CollectionItem]
}
