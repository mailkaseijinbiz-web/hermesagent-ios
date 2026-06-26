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
                        // Widget deep links
                        appState.selectedTab = .chat
                        switch url.host {
                        case "newchat":
                            appState.newSession()
                        case "employee":
                            // hermesagent://employee/<id> — talk as that 社員.
                            appState.activateEmployeeFromDeepLink(url.lastPathComponent)
                        default:
                            break   // "open" / unknown → just surface the chat tab
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
