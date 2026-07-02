import Foundation
import Photos
import CoreLocation
import UIKit
import Combine

/// 今日の写真を**端末内**でメタデータ集計し、プライバシーの軽い要約を Mac ハブへ送る。
/// 原画像は送らない（要約テキスト + 1日数枚の小さなサムネのみ ingest）。
@MainActor
final class PhotosManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotosManager()

    /// Set by AppState so summaries can be pushed to the Mac hub.
    weak var apiClient: APIClient?
    private var isLoading = false
    private var isObservingLibrary = false

    @Published var enabled: Bool = {
        if UserDefaults.standard.object(forKey: "photosLoggingEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "photosLoggingEnabled")
    }() {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "photosLoggingEnabled")
            if enabled {
                startObservingLibrary()
                Task { await syncNow() }
            } else {
                stopObservingLibrary()
                summaryText = ""
            }
        }
    }
    @Published var authorized = false
    @Published var summaryText: String = ""
    @Published var todayAssets: [PHAsset] = []
    @Published var lastLoaded: Date?

    var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    private override init() {
        super.init()
        authorized = (status == .authorized || status == .limited)
        if UserDefaults.standard.object(forKey: "photosLoggingEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "photosLoggingEnabled")
        }
        if enabled { startObservingLibrary() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
    }

    /// Request library access and refresh today's summary + lifelog entries.
    func requestAuthAndLoad() async {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = (s == .authorized || s == .limited)
        if authorized { await loadToday() }
    }

    /// Foreground / connect / pull-to-refresh entry point.
    func syncNow() async {
        guard enabled else { return }
        authorized = (status == .authorized || status == .limited)
        if authorized {
            await loadToday()
        } else {
            await requestAuthAndLoad()
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard self.enabled else { return }
            await self.loadToday()
        }
    }

    /// 今日の写真メタデータを集計して要約。enabled かつ許可済みのときだけ。
    func loadToday() async {
        guard enabled, !isLoading else { return }
        authorized = (status == .authorized || status == .limited)
        guard authorized else { return }
        isLoading = true
        defer { isLoading = false }

        let start = Calendar.current.startOfDay(for: Date())
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        let result = PHAsset.fetchAssets(with: opts)

        var camera = 0, screenshots = 0, videos = 0, favorites = 0
        var locations: [CLLocation] = []
        var cameraAssets: [PHAsset] = []
        var allTodayAssets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            allTodayAssets.append(asset)
            if asset.mediaType == .video { videos += 1 }
            else if asset.mediaSubtypes.contains(.photoScreenshot) { screenshots += 1 }
            else { camera += 1; cameraAssets.append(asset) }
            if asset.isFavorite { favorites += 1 }
            if let loc = asset.location { locations.append(loc) }
        }
        todayAssets = cameraAssets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
                                  .prefix(30).map { $0 }

        // スクショは記録対象外（枚数にも文言にも含めない）
        let photos = camera
        guard photos + videos > 0 else {
            summaryText = "今日はまだ写真がありません"
            lastLoaded = Date()
            return
        }

        let places = await representativePlaces(from: locations, max: 2)

        var parts: [String] = []
        parts.append("写真\(photos)枚")
        if videos > 0 { parts.append("動画\(videos)") }
        if favorites > 0 { parts.append("お気に入り\(favorites)") }
        var s = parts.joined(separator: "、")
        if !places.isEmpty { s += "。撮影場所: \(places.joined(separator: "・"))" }

        let sceneTags = await PhotoSceneTagger.tags(for: Array(todayAssets.prefix(5)))
        if !sceneTags.isEmpty { s += "。シーン: \(sceneTags.joined(separator: "・"))" }

        let captions = PhotoLogStore.shared.todayEntries
            .filter { $0.mediaKind == "image" && $0.isScreenshot != true }
            .map(\.label)
            .filter { !$0.isEmpty && $0 != "写真" && $0 != "スクリーンショット" }
        if !captions.isEmpty {
            s += "。\(captions.prefix(3).joined(separator: " / "))"
        }

        summaryText = s
        lastLoaded = Date()
        if let api = apiClient { await api.pushPhotos(summary: s) }
        await PhotoLifeLogIndexer.shared.indexNewAssets(allTodayAssets)
    }

    private func startObservingLibrary() {
        guard !isObservingLibrary else { return }
        PHPhotoLibrary.shared().register(self)
        isObservingLibrary = true
    }

    private func stopObservingLibrary() {
        guard isObservingLibrary else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isObservingLibrary = false
    }

    /// 位置をざっくりクラスタ化し、代表地点を最大 `max` 件だけ逆ジオコーディング。
    private func representativePlaces(from locations: [CLLocation], max: Int) async -> [String] {
        guard !locations.isEmpty else { return [] }
        var seen = Set<String>()
        var reps: [CLLocation] = []
        for loc in locations {
            let key = String(format: "%.2f,%.2f", loc.coordinate.latitude, loc.coordinate.longitude)
            if seen.insert(key).inserted { reps.append(loc); if reps.count >= max { break } }
        }
        let geocoder = CLGeocoder()
        var names: [String] = []
        for loc in reps {
            if let p = try? await geocoder.reverseGeocodeLocation(loc).first {
                let name = p.locality ?? p.name ?? p.areasOfInterest?.first ?? p.subAdministrativeArea
                if let name = name, !names.contains(name) { names.append(name) }
            }
        }
        return names
    }
}
