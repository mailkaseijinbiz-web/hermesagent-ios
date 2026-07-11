import SwiftUI
import Photos
import UIKit

/// Loads a small square thumbnail from the local photo library (by `PHAsset` id).
enum PhotoThumbnailLoader {
    private static let cache = NSCache<NSString, UIImage>()

    @MainActor
    static func load(localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        let key = "\(localIdentifier)-\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        let image = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                guard !resumed else { return }
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    resumed = true
                    cont.resume(returning: nil)
                    return
                }
                guard let img else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    resumed = true
                    cont.resume(returning: img)
                    return
                }
                // Degraded preview — use it rather than waiting forever (iCloud / slow assets).
                resumed = true
                cont.resume(returning: img)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    @MainActor
    static func loadFull(localIdentifier: String) async -> UIImage? {
        let key = "\(localIdentifier)-full" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        let image = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .none
            opts.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: opts
            ) { img, info in
                guard !resumed else { return }
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    resumed = true
                    cont.resume(returning: nil)
                    return
                }
                guard let img else { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// Mac ハブのメモ添付画像（`/api/memo-image`）を表示。
struct MacMemoImageView: View {
    @EnvironmentObject private var appState: AppState
    let fileName: String
    var fillWidth: Bool = false
    var side: CGFloat = 96

    @State private var image: UIImage?

    var body: some View {
        Group {
            if fillWidth {
                fullWidthBody
            } else {
                thumbnailBody
            }
        }
        .task(id: fileName) {
            image = await appState.loadMemoImage(fileName: fileName)
        }
    }

    private var thumbnailBody: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var fullWidthBody: some View {
        // 横長画像を scaledToFill すると報告サイズが枠幅を超えて行全体を押し広げるため、
        // サイズ決めは Color.clear（正方形）が担い、画像は overlay（レイアウト非関与）で重ねる。
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color.orange.opacity(0.12)
            Image(systemName: "photo.fill")
                .font(.system(size: fillWidth ? 36 : 22))
                .foregroundStyle(.orange.opacity(0.45))
        }
    }
}

/// Lifelog timeline thumbnail for a indexed photo/video asset.
struct PhotoThumbnailView: View {
    let localIdentifier: String
    let mediaKind: String
    var side: CGFloat = 72
    /// When true, thumbnail spans the full row width as a square.
    var fillWidth: Bool = false

    @State private var image: UIImage?

    var body: some View {
        if fillWidth {
            fullWidthBody
        } else {
            squareBody
        }
    }

    private var squareBody: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailImage
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            videoBadge
        }
        .task(id: loadTaskKey) { await loadThumbnail(pixelWidth: side * 2, pixelHeight: side * 2) }
    }

    private var fullWidthBody: some View {
        // 横長画像を scaledToFill すると報告サイズが枠幅を超えて行全体を押し広げるため、
        // サイズ決めは Color.clear（正方形）が担い、画像は overlay（レイアウト非関与）で重ねる。
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.orange.opacity(0.12)
                        Image(systemName: mediaKind == "video" ? "video.fill" : "photo.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange.opacity(0.45))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) { videoBadge }
            .task(id: loadTaskKey) {
                let width = UIScreen.main.bounds.width - 80
                await loadThumbnail(pixelWidth: width, pixelHeight: width)
            }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.orange.opacity(0.12)
                    Image(systemName: mediaKind == "video" ? "video.fill" : "photo.fill")
                        .font(.system(size: fillWidth ? 36 : 22))
                        .foregroundStyle(.orange.opacity(0.45))
                }
            }
        }
    }

    @ViewBuilder
    private var videoBadge: some View {
        if mediaKind == "video" {
            Image(systemName: "play.circle.fill")
                .font(.system(size: fillWidth ? 28 : 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.35))
                .padding(fillWidth ? 10 : 4)
        }
    }

    private var loadTaskKey: String {
        fillWidth ? "\(localIdentifier)-full" : "\(localIdentifier)-\(Int(side))"
    }

    private func loadThumbnail(pixelWidth: CGFloat, pixelHeight: CGFloat) async {
        // 表示時の保険: スクショなら画像を出さずエントリにフラグを立てる。
        // 端末から消えた写真はエントリごと除去（空プレースホルダー行の原因）。
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetched.firstObject else {
            PhotoLogStore.shared.removeEntry(id: localIdentifier)
            return
        }
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            PhotoLogStore.shared.markScreenshot(id: localIdentifier)
            return
        }
        let scale = UIScreen.main.scale
        image = await PhotoThumbnailLoader.load(
            localIdentifier: localIdentifier,
            targetSize: CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
        )
    }
}
