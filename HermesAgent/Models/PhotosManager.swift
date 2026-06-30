import Foundation
import Photos
import CoreLocation
import UIKit
import Combine

/// 今日の写真を**端末内だけ**でメタデータ集計し、プライバシーの軽い要約を作る。
/// 写真そのものは一切端末外に出さない。枚数・内訳（カメラ/スクショ/動画）・お気に入り・
/// 撮影場所（代表地名のみ）を要約して Mac ハブへ送り、AIの振り返りに使う。
@MainActor
final class PhotosManager: NSObject, ObservableObject {
    static let shared = PhotosManager()

    /// Set by AppState so summaries can be pushed to the Mac hub.
    weak var apiClient: APIClient?
    private var isLoading = false   // re-entrancy guard (MainActor → race-free)

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "photosLoggingEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "photosLoggingEnabled") }
    }
    @Published var authorized = false
    @Published var summaryText: String = ""
    @Published var todayAssets: [PHAsset] = []   // 今日撮影したカメラ写真（新しい順・最大30枚）
    @Published var lastLoaded: Date?

    var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            Task { await requestAuthAndLoad() }
        } else {
            summaryText = ""
        }
    }

    func requestAuthAndLoad() async {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = (s == .authorized || s == .limited)
        if authorized { await loadToday() }
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
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == .video { videos += 1 }
            else if asset.mediaSubtypes.contains(.photoScreenshot) { screenshots += 1 }
            else { camera += 1; cameraAssets.append(asset) }
            if asset.isFavorite { favorites += 1 }
            if let loc = asset.location { locations.append(loc) }
        }
        // 新しい順・最大30枚
        todayAssets = cameraAssets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
                                  .prefix(30).map { $0 }

        let photos = camera + screenshots
        guard photos + videos > 0 else {
            summaryText = "今日はまだ写真がありません"
            lastLoaded = Date()
            return
        }

        let places = await representativePlaces(from: locations, max: 2)

        var parts: [String] = []
        var photoPart = "写真\(photos)枚"
        if camera > 0 && screenshots > 0 { photoPart += "（カメラ\(camera)・スクショ\(screenshots)）" }
        else if screenshots > 0 { photoPart += "（スクショ）" }
        parts.append(photoPart)
        if videos > 0 { parts.append("動画\(videos)") }
        if favorites > 0 { parts.append("お気に入り\(favorites)") }
        var s = parts.joined(separator: "、")
        if !places.isEmpty { s += "。撮影場所: \(places.joined(separator: "・"))" }

        summaryText = s
        lastLoaded = Date()
        if let api = apiClient { Task { await api.pushPhotos(summary: s) } }
    }

    /// 位置をざっくりクラスタ化し、代表地点を最大 `max` 件だけ逆ジオコーディング。
    private func representativePlaces(from locations: [CLLocation], max: Int) async -> [String] {
        guard !locations.isEmpty else { return [] }
        // 小数2桁(約1km)で丸めて重複排除 → 代表点を間引く。
        var seen = Set<String>()
        var reps: [CLLocation] = []
        for loc in locations {
            let key = String(format: "%.2f,%.2f", loc.coordinate.latitude, loc.coordinate.longitude)
            if seen.insert(key).inserted { reps.append(loc); if reps.count >= max { break } }
        }
        let geocoder = CLGeocoder()   // local instance — avoid sharing across concurrent callers
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
