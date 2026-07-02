import Photos
import UIKit

/// Indexes today's photos/videos into Mac memos via `/api/ingest`.
/// Captions: on-device Vision + optional Mac vision when connected.
@MainActor
final class PhotoLifeLogIndexer {
    static let shared = PhotoLifeLogIndexer()

    weak var apiClient: APIClient?

    private let maxPhotosPerDay = 5
    private let maxVideosPerDay = 2
    private let indexedIdsKey = "photoLifeLogIndexedIds"
    private let dayCountsKey = "photoLifeLogDayCounts"

    private init() {}

    /// Scan new assets from today's library fetch; record locally and push metadata + tiny thumbnails to Mac when connected.
    func indexNewAssets(_ allToday: [PHAsset]) async {
        guard !allToday.isEmpty else { return }

        resetDayCountsIfNeeded()
        var (photoCount, videoCount) = todayCounts()
        let indexed = loadIndexedIds()

        let sorted = allToday.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }

        for asset in sorted {
            let inStore = PhotoLogStore.shared.todayEntries.contains { $0.id == asset.localIdentifier }
            if indexed.contains(asset.localIdentifier) && inStore { continue }
            switch asset.mediaType {
            case .image:
                guard photoCount < maxPhotosPerDay else { continue }
                // 連写・撮り直し: 既存の写真エントリから3分以内なら同じ場面とみなして
                // スキップ（1日5枚の枠とMacへのingestを重複で消費しない）
                if isNearDuplicate(asset) {
                    markIndexed(asset.localIdentifier)
                    continue
                }
                guard await indexPhoto(asset) else { continue }
                photoCount += 1
            case .video:
                guard videoCount < maxVideosPerDay else { continue }
                guard await indexVideo(asset) else { continue }
                videoCount += 1
            default:
                continue
            }
            markIndexed(asset.localIdentifier)
        }
        saveDayCounts(photos: photoCount, videos: videoCount)
    }

    // MARK: - Private

    /// すでに記録済みの写真エントリから3分以内に撮られた写真か（同じ場面の撮り直しとみなす）。
    private func isNearDuplicate(_ asset: PHAsset) -> Bool {
        guard let when = asset.creationDate else { return false }
        return PhotoLogStore.shared.entries(on: when).contains {
            $0.mediaKind == "image" && abs($0.time.timeIntervalSince(when)) < 180
        }
    }

    private func indexPhoto(_ asset: PHAsset) async -> Bool {
        let when = asset.creationDate ?? Date()
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        let thumb = await thumbnail(for: asset)
        let jpeg = thumb.flatMap { HermesIngestClient.jpegData(from: $0) }

        var caption = await PhotoSceneTagger.describe(asset: asset)
        if isScreenshot { caption = "スクリーンショット" }
        PhotoLogStore.shared.addEntry(id: asset.localIdentifier, time: when, label: caption,
                                      mediaKind: "image", isScreenshot: isScreenshot)

        // スクショは画面内容を含むためAIキャプション生成もスキップ
        if !isScreenshot, let refined = await refineCaption(jpeg: jpeg, fallback: caption) {
            caption = refined
            PhotoLogStore.shared.updateEntryLabel(id: asset.localIdentifier, label: refined)
        }

        guard !SharedStore.hubURL().isEmpty else { return true }
        guard let jpeg else { return true }
        let time = asset.creationDate.map { Self.timeFormatter.string(from: $0) } ?? ""
        let meta = time.isEmpty ? caption : "\(time) \(caption)"
        do {
            // スクショは画像を送らずテキストのみ記録
            _ = try await HermesIngestClient.ingest(
                kind: "image", title: caption, text: meta, images: isScreenshot ? [] : [jpeg]
            )
            return true
        } catch {
            return true
        }
    }

    private func refineCaption(jpeg: Data?, fallback: String) async -> String? {
        guard let jpeg, !jpeg.isEmpty else { return nil }
        if let api = apiClient, let ai = await api.describePhoto(imageData: jpeg) {
            return ai
        }
        return nil
    }

    private func indexVideo(_ asset: PHAsset) async -> Bool {
        let dur = Int(asset.duration)
        let durStr = dur >= 60 ? "\(dur / 60)分\(dur % 60 > 0 ? "\(dur % 60)秒" : "")" : "\(dur)秒"
        let time = asset.creationDate.map { Self.timeFormatter.string(from: $0) } ?? ""
        let title = "動画 \(durStr)"
        let meta = time.isEmpty ? "ライフログ動画" : "\(time) ライフログ動画"
        let when = asset.creationDate ?? Date()
        PhotoLogStore.shared.addEntry(id: asset.localIdentifier, time: when, label: title, mediaKind: "video")

        guard !SharedStore.hubURL().isEmpty else { return true }
        var images: [Data] = []
        if let img = await thumbnail(for: asset),
           let data = HermesIngestClient.jpegData(from: img) {
            images = [data]
        }
        do {
            _ = try await HermesIngestClient.ingest(
                kind: "video", title: title, text: meta, images: images
            )
            return true
        } catch {
            return true
        }
    }

    private func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFill, options: opts
            ) { img, info in
                guard !resumed else { return }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f
    }()

    private func resetDayCountsIfNeeded() {
        let today = Self.dayKey(Date())
        let stored = UserDefaults.standard.string(forKey: dayCountsKey + ".day")
        if stored != today {
            UserDefaults.standard.set(today, forKey: dayCountsKey + ".day")
            UserDefaults.standard.set(0, forKey: dayCountsKey + ".photos")
            UserDefaults.standard.set(0, forKey: dayCountsKey + ".videos")
        }
    }

    private func todayCounts() -> (photos: Int, videos: Int) {
        (
            UserDefaults.standard.integer(forKey: dayCountsKey + ".photos"),
            UserDefaults.standard.integer(forKey: dayCountsKey + ".videos")
        )
    }

    private func saveDayCounts(photos: Int, videos: Int) {
        UserDefaults.standard.set(photos, forKey: dayCountsKey + ".photos")
        UserDefaults.standard.set(videos, forKey: dayCountsKey + ".videos")
    }

    private func loadIndexedIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: indexedIdsKey) ?? [])
    }

    private func markIndexed(_ id: String) {
        var ids = Array(loadIndexedIds())
        ids.append(id)
        if ids.count > 500 { ids = Array(ids.suffix(500)) }
        UserDefaults.standard.set(ids, forKey: indexedIdsKey)
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }
}
