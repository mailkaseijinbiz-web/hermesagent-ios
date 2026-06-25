import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showAutomations = false

    var body: some View {
        Group {
            if appState.canShowMain {
                // Claude-style: a single full-screen conversation with a left drawer
                // for history / new chat / settings (no bottom tab bar).
                ZStack(alignment: .leading) {
                    NavigationStack { ChatView() }

                    if appState.showDrawer {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture { appState.showDrawer = false }
                            .transition(.opacity)

                        DrawerView(showSettings: $showSettings, showAutomations: $showAutomations)
                            .frame(width: 312)
                            .frame(maxHeight: .infinity)
                            .background(Color(.systemBackground))
                            .transition(.move(edge: .leading))
                            .zIndex(1)
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: appState.showDrawer)
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView().toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("完了") { showSettings = false } }
                        }
                    }
                }
                .sheet(isPresented: $showAutomations) {
                    NavigationStack {
                        AutomationsView().toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("完了") { showAutomations = false } }
                        }
                    }
                }
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

// MARK: - Drawer (Claude-style history + nav)

struct DrawerView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showSettings: Bool
    @Binding var showAutomations: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hermes").font(.system(.title3, weight: .semibold))
                Spacer()
                Button {
                    appState.newSession(); appState.showDrawer = false
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .light))
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    if appState.sessions.isEmpty {
                        Text("チャット履歴がありません")
                            .font(.system(.footnote, weight: .light))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(appState.sessions) { s in
                        let active = s.id == appState.currentSessionId
                        Button {
                            appState.switchSession(s.id)
                            appState.showDrawer = false
                        } label: {
                            HStack(spacing: 10) {
                                Circle().fill(active ? Color.green : Color.clear).frame(width: 7, height: 7)
                                Text(s.title.isEmpty ? "無題のセッション" : s.title)
                                    .font(.system(.subheadline, weight: active ? .medium : .light))
                                    .foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(active ? Color.primary.opacity(0.06) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            drawerLink("オートメーション", "clock") { showAutomations = true; appState.showDrawer = false }
            drawerLink("設定", "gearshape") { showSettings = true; appState.showDrawer = false }
                .padding(.bottom, 10)
        }
    }

    private func drawerLink(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                Text(title).font(.system(.subheadline)).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
