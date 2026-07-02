import SwiftUI
import UIKit

// MARK: - Pinch-zoom (UIScrollView, aspect-fit + bounded pan)

private struct ZoomableScrollImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .black
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never

        let container = UIView()
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        container.addSubview(imageView)
        scroll.addSubview(container)

        context.coordinator.scrollView = scroll
        context.coordinator.containerView = container
        context.coordinator.imageView = imageView
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        DispatchQueue.main.async {
            context.coordinator.updateLayout()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var containerView: UIView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { containerView }

        func updateLayout() {
            guard let scrollView, let containerView, let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 1, bounds.height > 1 else { return }

            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let widthScale = bounds.width / imageSize.width
            let heightScale = bounds.height / imageSize.height
            let fitScale = min(widthScale, heightScale)

            let displayW = imageSize.width * fitScale
            let displayH = imageSize.height * fitScale
            containerView.frame = CGRect(origin: .zero, size: CGSize(width: displayW, height: displayH))
            imageView.frame = containerView.bounds

            scrollView.contentSize = CGSize(width: displayW, height: displayH)
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = min(2.5, max(1, 1 / fitScale))
            scrollView.zoomScale = 1
            centerInScrollView()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerInScrollView()
        }

        private func centerInScrollView() {
            guard let scrollView else { return }
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let insetX = max((bounds.width - content.width) / 2, 0)
            let insetY = max((bounds.height - content.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }
    }
}

// MARK: - Full-screen viewer

struct PhotoZoomViewer: View {
    let entry: PhotoLogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableScrollImage(image: image)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .white.opacity(0.35))
                    }
                    .padding(20)
                }
                Spacer()
                if !entry.label.isEmpty {
                    Text(entry.label)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                }
            }
        }
        .task(id: entry.id) {
            image = await PhotoThumbnailLoader.loadFull(localIdentifier: entry.id)
        }
    }
}
