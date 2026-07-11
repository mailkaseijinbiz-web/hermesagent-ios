import SwiftUI

@main
struct HermesAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var auth = AuthManager.shared

    init() {
        // Metal Performance HUD（FPS/GPUのデバッグオーバーレイ）を明示的に無効化。
        // 開発者設定や devicectl 起動で有効化されると MapKit の Metal レイヤーに
        // HUD が重なって表示されるため、Metal レイヤー生成前に環境変数で抑止する。
        setenv("MTL_HUD_ENABLED", "0", 1)
    }

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
                        case "evening-reflect":
                            appState.openEveningReflection(trigger: "deeplink")
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
