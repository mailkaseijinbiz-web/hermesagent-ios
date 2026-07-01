import LinkPresentation
import UIKit

/// Loads news row thumbnails: RSS image → publisher og:image → LinkPresentation preview.
enum NewsThumbnailLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func load(for item: SaunaNewsItem) async -> UIImage? {
        let key = (item.imageURL ?? item.link) as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let urlStr = item.imageURL, OpenGraphImageExtractor.isUsableImageURL(urlStr),
           let url = URL(string: urlStr), let img = await download(url), isPhotoSized(img) {
            cache.setObject(img, forKey: key)
            return img
        }

        let articleURL = await resolvedArticleURL(for: item)
        if let ogURL = await OpenGraphImageExtractor.fetchImageURL(from: articleURL),
           let url = URL(string: ogURL), let img = await download(url), isPhotoSized(img) {
            cache.setObject(img, forKey: key)
            return img
        }

        if let url = URL(string: articleURL),
           let img = await linkPreviewImage(for: url), isPhotoSized(img) {
            cache.setObject(img, forKey: key)
            return img
        }

        return nil
    }

    static func faviconDomain(from sourceURL: String?) -> String? {
        guard let sourceURL, let host = URL(string: sourceURL)?.host, !host.isEmpty else { return nil }
        return host
    }

    private static func resolvedArticleURL(for item: SaunaNewsItem) async -> String {
        if GoogleNewsURLResolver.isGoogleNewsArticleURL(item.link),
           let resolved = await GoogleNewsURLResolver.resolvePublisherURL(from: item.link) {
            return resolved
        }
        return item.link
    }

    private static func isPhotoSized(_ img: UIImage) -> Bool {
        img.size.width >= 80 && img.size.height >= 80
    }

    private static func download(_ url: URL) async -> UIImage? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    private static func linkPreviewImage(for url: URL) async -> UIImage? {
        await withCheckedContinuation { cont in
            LPMetadataProvider().startFetchingMetadata(for: url) { meta, _ in
                guard let provider = meta?.imageProvider else {
                    cont.resume(returning: nil)
                    return
                }
                provider.loadObject(ofClass: UIImage.self) { obj, _ in
                    cont.resume(returning: obj as? UIImage)
                }
            }
        }
    }
}
