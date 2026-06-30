import Photos
import Vision
import UIKit

/// On-device scene classification for today's photos. Never exports image bytes.
enum PhotoSceneTagger {

    private static let labelMap: [String: String] = [
        "outdoor": "屋外", "landscape": "風景", "nature": "自然", "beach": "海",
        "mountain": "山", "forest": "森", "sky": "空", "sunset": "夕景",
        "food": "食事", "meal": "食事", "restaurant": "外食", "coffee": "カフェ",
        "indoor": "屋内", "office": "仕事", "home": "自宅", "gym": "運動",
        "sport": "スポーツ", "running": "ランニング", "walking": "散歩",
        "pet": "ペット", "dog": "ペット", "cat": "ペット",
        "document": "書類", "screenshot": "スクショ", "text": "文字",
        "people": "人物", "selfie": "自撮り", "party": "集まり",
        "travel": "旅行", "city": "街", "building": "建物",
        "water": "水辺", "pool": "プール", "sauna": "サウナ"
    ]

    /// Classify up to `limit` camera assets; returns deduplicated Japanese scene tags.
    static func tags(for assets: [PHAsset], limit: Int = 5) async -> [String] {
        let targets = assets.filter { $0.mediaType == .image && !$0.mediaSubtypes.contains(.photoScreenshot) }
                          .prefix(limit)
        guard !targets.isEmpty else { return [] }

        var found: [String] = []
        for asset in targets {
            guard let cg = await thumbnail(for: asset) else { continue }
            if let tag = classify(cg), !found.contains(tag) { found.append(tag) }
            if found.count >= 3 { break }
        }
        return found
    }

    private static func thumbnail(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 224, height: 224),
                contentMode: .aspectFill, options: opts
            ) { img, _ in
                cont.resume(returning: img?.cgImage)
            }
        }
    }

    private static func classify(_ cg: CGImage) -> String? {
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([req])) != nil,
              let results = req.results?.prefix(8) else { return nil }
        for obs in results where obs.confidence > 0.12 {
            let id = obs.identifier.lowercased()
            for (key, ja) in labelMap where id.contains(key) { return ja }
        }
        return nil
    }
}
