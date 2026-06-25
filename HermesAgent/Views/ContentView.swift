import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if appState.canShowMain {
                TabView(selection: $appState.selectedTab) {
                    NavigationStack {
                        ChatView()
                    }
                    .tabItem {
                        Label("チャット", systemImage: "bubble.left.and.bubble.right")
                    }
                    .tag(AppState.Tab.chat)

                    NavigationStack {
                        AutomationsView()
                    }
                    .tabItem {
                        Label("オートメーション", systemImage: "clock")
                    }
                    .tag(AppState.Tab.automations)

                    NavigationStack {
                        SettingsView()
                    }
                    .tabItem {
                        Label("設定", systemImage: "gearshape")
                    }
                    .tag(AppState.Tab.settings)
                }
                .tint(.primary)
            } else {
                ConnectView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.canShowMain)
        .task {
            // Auto-connect using the saved/default server URL — no QR needed.
            await appState.autoConnectIfPossible()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Reconnect + resync when returning to the foreground, and start the
                // health monitor so the connection badge tracks the Mac server's state.
                Task {
                    await appState.autoConnectIfPossible()
                    appState.startHealthMonitor()
                    if appState.isConnected {
                        appState.startEvents()   // restart SSE if it was stopped on background
                        appState.startPresenceReporting()
                        await appState.resyncNow()
                    }
                }
            case .background:
                // Stop the SSE stream + health polling while backgrounded (battery),
                // and clear presence so the device gets push again while away.
                appState.stopEvents()
                appState.stopHealthMonitor()
                appState.stopPresenceReporting()
            default:
                break
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        List {
            // Google Account
            if auth.isConfigured {
                Section {
                    HStack(spacing: 12) {
                        AsyncImage(url: auth.photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(auth.name ?? "サインイン済み")
                                .font(.system(.body, weight: .medium))
                            if let email = auth.email {
                                Text(email)
                                    .font(.system(.caption, weight: .light))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        auth.signOut()
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("サインアウト")
                        }
                    }
                } header: {
                    Text("Googleアカウント")
                }
            }

            // Server Info
            Section {
                if let status = appState.serverStatus {
                    LabeledRow(label: "ステータス", value: status.status == "ok" ? "接続中" : status.status)
                    if let provider = status.provider {
                        LabeledRow(label: "プロバイダー", value: provider)
                    }
                    if let model = status.model {
                        LabeledRow(label: "モデル", value: formatModelName(model))
                    }
                    if let personality = status.personality {
                        LabeledRow(label: "パーソナリティ", value: personality)
                    }
                }
            } header: {
                Text("サーバー情報")
            }

            // Connection
            Section {
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Text(appState.serverURL)
                        .font(.system(.body, weight: .light))
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    appState.disconnect()
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("切断する")
                    }
                }
            } header: {
                Text("接続")
            }

            // About
            Section {
                LabeledRow(label: "バージョン", value: "1.0.0")
                LabeledRow(label: "プラットフォーム", value: "iOS")
            } header: {
                Text("アプリについて")
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await appState.connect()
        }
    }

    private func formatModelName(_ model: String) -> String {
        if let lastSlash = model.lastIndex(of: "/") {
            return String(model[model.index(after: lastSlash)...])
        }
        return model
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(.body, weight: .light))
            Spacer()
            Text(value)
                .font(.system(.body, weight: .light))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(AuthManager.shared)
}
