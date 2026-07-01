import Photos
import UIKit

/// Indexes today's photos/videos into Mac memos via `/api/ingest`.
/// On-device Vision tags only; small thumbnails; strict daily caps (no LLM per asset).
@MainActor
final class PhotoLifeLogIndexer {
    static let shared = PhotoLifeLogIndexer()

    private let maxPhotosPerDay = 5
    private let maxVideosPerDay = 2
    private let indexedIdsKey = "photoLifeLogIndexedIds"
    private let dayCountsKey = "photoLifeLogDayCounts"

    private init() {}

    /// Scan new assets from today's library fetch and push metadata + tiny thumbnails.
    func indexNewAssets(_ allToday: [PHAsset]) async {
        guard !allToday.isEmpty else { return }
        let hub = SharedStore.hubURL()
        guard !hub.isEmpty else { return }

        resetDayCountsIfNeeded()
        var (photoCount, videoCount) = todayCounts()
        let indexed = loadIndexedIds()

        let sorted = allToday.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }

        for asset in sorted {
            guard !indexed.contains(asset.localIdentifier) else { continue }
            switch asset.mediaType {
            case .image:
                guard photoCount < maxPhotosPerDay else { continue }
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

    private func indexPhoto(_ asset: PHAsset) async -> Bool {
        let tags = await PhotoSceneTagger.tags(for: [asset], limit: 1)
        let tagLine = tags.isEmpty ? "" : "シーン: \(tags.joined(separator: "・"))"
        guard let img = await thumbnail(for: asset),
              let data = HermesIngestClient.jpegData(from: img) else { return false }
        let time = asset.creationDate.map { Self.timeFormatter.string(from: $0) } ?? ""
        let title = tagLine.isEmpty ? "ライフログ写真" : tagLine
        let meta = time.isEmpty ? tagLine : "\(time) \(tagLine)".trimmingCharacters(in: .whitespaces)
        do {
            _ = try await HermesIngestClient.ingest(
                kind: "image", title: title, text: meta, images: [data]
            )
            return true
        } catch {
            return false
        }
    }

    private func indexVideo(_ asset: PHAsset) async -> Bool {
        let dur = Int(asset.duration)
        let durStr = dur >= 60 ? "\(dur / 60)分\(dur % 60 > 0 ? "\(dur % 60)秒" : "")" : "\(dur)秒"
        let time = asset.creationDate.map { Self.timeFormatter.string(from: $0) } ?? ""
        let title = "動画 \(durStr)"
        let meta = time.isEmpty ? "ライフログ動画" : "\(time) ライフログ動画"
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
            return false
        }
    }

    private func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 256, height: 256),
                contentMode: .aspectFill, options: opts
            ) { img, _ in cont.resume(returning: img) }
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
