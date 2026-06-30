import SwiftUI
import WebKit

/// 開発したアプリ（AppProject）の previewURL を**アプリ内ブラウザ**で開く画面。
/// Mac が Tailscale 経由で配信している Web アプリ（例: 健康管理アプリ）をそのまま
/// HermesAgent 内で表示する。AppState.activeSheet == .appWeb 経由でシート表示される。
struct AppWebView: View {
    let app: AppProject
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WebViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if let url = normalizedURL {
                    WebContainer(url: url, model: model)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .top) {
                            if model.isLoading {
                                ProgressView().progressViewStyle(.linear)
                            }
                        }
                } else {
                    invalidURL
                }
            }
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if normalizedURL != nil {
                        Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!model.canGoBack)
                        Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    }
                    if let url = normalizedURL {
                        Button { UIApplication.shared.open(url) } label: { Image(systemName: "safari") }
                    }
                }
            }
        }
    }

    /// previewURL を正規化（スキームが無ければ http:// を補う）。
    private var normalizedURL: URL? {
        var s = app.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "http://" + s }
        return URL(string: s)
    }

    private var invalidURL: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("プレビューURLが未設定です")
                .font(.system(size: 15, weight: .medium))
            Text("「アプリ」画面でこのアプリのプレビューURL（例: http://〈Macのtailscale名〉:ポート）を設定すると、ここで開けます。")
                .font(.system(size: 12, weight: .light)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// WKWebView の読み込み状態と戻る可否を SwiftUI に橋渡しし、ツールバーから操作させる。
final class WebViewModel: ObservableObject {
    @Published var canGoBack = false
    @Published var isLoading = false
    weak var webView: WKWebView?
    func goBack() { webView?.goBack() }
    func reload() { webView?.reload() }
}

struct WebContainer: UIViewRepresentable {
    let url: URL
    @ObservedObject var model: WebViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        model.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: WebViewModel
        init(model: WebViewModel) { self.model = model }

        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
            model.isLoading = true
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            model.isLoading = false; model.canGoBack = w.canGoBack
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            model.isLoading = false; model.canGoBack = w.canGoBack
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            model.isLoading = false
        }
    }
}
