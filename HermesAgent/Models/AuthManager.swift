import Foundation
import GoogleSignIn
import UIKit

/// Handles Google Sign-In and exposes the current user's ID token.
/// The same Google account is used across iPhone / iPad to gate access to
/// the Mac's MobileServer (the sync hub).
@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isSignedIn = false
    @Published var email: String?
    @Published var name: String?
    @Published var photoURL: URL?
    @Published var authError: String?

    private init() {}

    /// Google auth is only "configured" once a real client ID is in Info.plist.
    /// While the placeholder is present the app skips the sign-in gate so it
    /// keeps working over Tailscale without auth.
    var isConfigured: Bool {
        guard let cid = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { return false }
        return !cid.isEmpty && !cid.contains("REPLACE_WITH")
    }

    func restore() {
        guard isConfigured else { return }
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, _ in
            if let user { self?.apply(user) }
        }
    }

    func signIn() {
        guard isConfigured else {
            authError = "Google Client IDが未設定です。project.ymlのGIDClientIDを設定してください。"
            return
        }
        guard let presenter = Self.topViewController() else {
            authError = "表示中の画面を取得できませんでした。"
            return
        }
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { [weak self] result, error in
            if let error = error {
                self?.authError = "サインインに失敗しました: \(error.localizedDescription)"
                return
            }
            if let user = result?.user { self?.apply(user) }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        email = nil
        name = nil
        photoURL = nil
    }

    /// Fresh ID token (refreshed if near expiry). nil if not signed in / unconfigured.
    func idToken() async -> String? {
        guard isConfigured, let user = GIDSignIn.sharedInstance.currentUser else { return nil }
        return await withCheckedContinuation { continuation in
            user.refreshTokensIfNeeded { refreshed, _ in
                continuation.resume(returning: (refreshed ?? user).idToken?.tokenString)
            }
        }
    }

    func handle(_ url: URL) {
        guard isConfigured else { return }
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    private func apply(_ user: GIDGoogleUser) {
        isSignedIn = true
        email = user.profile?.email
        name = user.profile?.name
        photoURL = user.profile?.imageURL(withDimension: 120)
        authError = nil
    }

    /// Finds the top-most view controller to present the Google flow from.
    static func topViewController(_ base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController

        if let nav = root as? UINavigationController {
            return topViewController(nav.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(tab.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(presented)
        }
        return root
    }
}
