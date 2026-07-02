import Photos
import Vision
import UIKit

/// On-device scene classification + OCR for lifelog photos. Never exports full images off-device
/// except when the user’s Mac hub is asked to refine the caption (small JPEG only).
enum PhotoSceneTagger {

    private static let labelMap: [String: String] = [
        "outdoor": "屋外", "landscape": "風景", "nature": "自然", "beach": "海",
        "mountain": "山", "forest": "森", "sky": "空", "sunset": "夕景",
        "food": "食事", "meal": "食事", "restaurant": "外食", "coffee": "カフェ",
        "indoor": "屋内", "office": "仕事", "home": "自宅", "gym": "運動",
        "sport": "スポーツ", "running": "ランニング", "walking": "散歩",
        "pet": "ペット", "dog": "犬", "cat": "猫",
        "document": "書類", "screenshot": "スクショ", "text": "文字",
        "people": "人物", "selfie": "自撮り", "party": "集まり",
        "travel": "旅行", "city": "街", "building": "建物",
        "water": "水辺", "pool": "プール", "sauna": "サウナ",
        "car": "車", "flower": "花", "plant": "植物", "book": "本",
        "computer": "パソコン", "phone": "スマホ"
    ]

    /// Classify up to `limit` camera assets; returns deduplicated Japanese scene tags.
    static func tags(for assets: [PHAsset], limit: Int = 5) async -> [String] {
        let targets = assets.filter { $0.mediaType == .image && !$0.mediaSubtypes.contains(.photoScreenshot) }
                          .prefix(limit)
        guard !targets.isEmpty else { return [] }

        var found: [String] = []
        for asset in targets {
            guard let cg = await thumbnail(for: asset) else { continue }
            found.append(contentsOf: classifyTags(cg, max: 3))
            found = dedupe(found)
            if found.count >= 3 { break }
        }
        return Array(found.prefix(3))
    }

    /// One-line Japanese description for a single photo (on-device).
    static func describe(asset: PHAsset) async -> String {
        guard asset.mediaType == .image else { return "写真" }
        if asset.mediaSubtypes.contains(.photoScreenshot) { return "スクリーンショット" }
        guard let cg = await thumbnail(for: asset, side: 512) else { return "写真" }
        let tags = classifyTags(cg, max: 4)
        let ocr = recognizeText(cg)
        return formatDescription(tags: tags, ocrText: ocr)
    }

    static func formatDescription(tags: [String], ocrText: String) -> String {
        var parts: [String] = []
        if !tags.isEmpty {
            parts.append(tags.joined(separator: "、"))
        }
        let trimmedOCR = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOCR.isEmpty {
            parts.append("写っている文字: \(trimmedOCR)")
        }
        guard !parts.isEmpty else { return "写真" }
        if tags.isEmpty { return parts.joined(separator: "。") }
        if trimmedOCR.isEmpty { return parts[0] + "の写真" }
        return parts[0] + "の写真。" + parts[1]
    }

    // MARK: - Private

    private static func dedupe(_ tags: [String]) -> [String] {
        var out: [String] = []
        for t in tags where !out.contains(t) { out.append(t) }
        return out
    }

    private static func thumbnail(for asset: PHAsset, side: CGFloat = 224) async -> CGImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                guard !resumed else { return }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                resumed = true
                cont.resume(returning: img?.cgImage)
            }
        }
    }

    private static func classifyTags(_ cg: CGImage, max: Int) -> [String] {
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([req])) != nil,
              let results = req.results else { return [] }
        var found: [String] = []
        for obs in results.prefix(14) where obs.confidence > 0.1 {
            let id = obs.identifier.lowercased()
            for (key, ja) in labelMap where id.contains(key) {
                if !found.contains(ja) { found.append(ja) }
            }
            if found.count >= max { break }
        }
        return found
    }

    private static func recognizeText(_ cg: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["ja-JP", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([req])) != nil,
              let results = req.results else { return "" }
        let lines = results.prefix(6).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: " / ")
        if joined.count <= 80 { return joined }
        return String(joined.prefix(80)) + "…"
    }
}
