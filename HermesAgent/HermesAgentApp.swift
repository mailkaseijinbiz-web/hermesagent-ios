import SwiftUI

@main
struct HermesAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var auth = AuthManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(auth)
                .preferredColorScheme(appState.preferredColorScheme)
                .task { appState.setupPush() }
                .onOpenURL { url in
                    if url.scheme == "hermesagent" {
                        switch url.host {
                        case "newchat":
                            appState.tab = .home
                            appState.openNewChat()
                        case "employee":
                            appState.tab = .home
                            appState.activateEmployeeFromDeepLink(url.lastPathComponent)
                        case "app":
                            appState.openAppFromDeepLink(url.lastPathComponent)
                        case "apps":
                            appState.tab = .apps
                        case "home":
                            appState.tab = .home
                        case "intention":
                            appState.confirmIntentionFromDeepLink(url.lastPathComponent)
                        default:
                            appState.tab = .home
                            appState.showingChat = true
                        }
                    } else {
                        auth.handle(url)
                    }
                }
                .task { auth.restore() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        // Require Google sign-in only when auth is configured (real client ID present).
        if auth.isConfigured && !auth.isSignedIn {
            SignInView()
        } else {
            ContentView()
        }
    }
}
