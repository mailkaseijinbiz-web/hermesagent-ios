import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    @ToolbarContentBuilder
    private var sheetDone: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { Button("完了") { appState.activeSheet = nil } }
    }

    var body: some View {
        Group {
            if appState.canShowMain {
                // Footer tab bar: ホーム / ニュース / タスク / 社員. The chat thread opens
                // full-screen over the tabs; the drawer (☰ on ホーム) holds the extras.
                ZStack(alignment: .leading) {
                    TabView(selection: $appState.tab) {
                        NavigationStack { HomeView() }
                            .tabItem { Label("ホーム", systemImage: "house.fill") }
                            .tag(AppState.MainTab.home)
                        NavigationStack { NewsView() }
                            .tabItem { Label("ニュース", systemImage: "newspaper.fill") }
                            .tag(AppState.MainTab.news)
                        NavigationStack { TasksView() }
                            .tabItem { Label("タスク", systemImage: "checklist") }
                            .tag(AppState.MainTab.tasks)
                        NavigationStack { CompanyView() }
                            .tabItem { Label("社員", systemImage: "person.2.fill") }
                            .tag(AppState.MainTab.employees)
                    }

                    if appState.showDrawer {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture { appState.showDrawer = false }
                            .transition(.opacity)

                        DrawerView()
                            .frame(width: 312)
                            .frame(maxHeight: .infinity)
                            .background(Color(.systemBackground))
                            .transition(.move(edge: .leading))
                            .zIndex(1)
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: appState.showDrawer)
                // 画面左端からの右スワイプでメニュー（ドロワー）を開く／開いている時の
                // 左スワイプで閉じる。縦スクロールと干渉しないよう横方向の動きだけを判定。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18, coordinateSpace: .global)
                        .onEnded { value in
                            let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.4
                            guard horizontal else { return }
                            if !appState.showDrawer,
                               value.startLocation.x < 32,
                               value.translation.width > 60 {
                                appState.showDrawer = true
                            } else if appState.showDrawer, value.translation.width < -60 {
                                appState.showDrawer = false
                            }
                        }
                )
                // Chat opens full-screen over the tabs (from home/employee/history/push/deeplink).
                .fullScreenCover(isPresented: $appState.showingChat) {
                    NavigationStack { ChatView() }
                }
                // Single enum-driven sheet for the secondary screens.
                .sheet(item: $appState.activeSheet) { sheet in
                    switch sheet {
                    case .settings:
                        NavigationStack { SettingsView().toolbar { sheetDone } }
                    case .automations:
                        NavigationStack { AutomationsView().toolbar { sheetDone } }
                    case .profile:
                        NavigationStack { ProfileView() }
                    case .selfGraph:
                        NavigationStack { SelfGraphView().toolbar { sheetDone } }
                    case .selfResources:
                        NavigationStack { SelfResourcesView() }
                    case .apps:
                        NavigationStack { AppsView().toolbar { sheetDone } }
                    case .employee(let id):
                        NavigationStack { EmployeeDetailView(employeeId: id).toolbar { sheetDone } }
                    case .appWeb(let app):
                        AppWebView(app: app)
                    case .collection:
                        NavigationStack { CollectionView().toolbar { sheetDone } }
                    }
                }
            } else {
                ConnectView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.canShowMain)
        .onChange(of: appState.tab) { _, tab in
            guard tab == .employees else { return }
            Task {
                await appState.autoConnectIfPossible()
                await appState.fetchEmployees()
            }
        }
        .task {
            // Auto-connect using the saved/default server URL — no QR needed.
            await appState.autoConnectIfPossible()
            await HealthManager.shared.syncNow(via: appState.apiClient)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Reconnect + resync when returning to the foreground, and start the
                // health monitor so the connection badge tracks the Mac server's state.
                appState.clearAppBadge()   // user is looking at the app → clear the icon badge
                LocationManager.shared.recordNow()
                AppUsageTracker.shared.onForeground()
                Task {
                    await appState.autoConnectIfPossible()
                    appState.startHealthMonitor()
                    if appState.isConnected {
                        appState.startEvents()
                        appState.startPresenceReporting()
                        await appState.resyncNow()
                        appState.clearAppBadge()
                    }
                    await HealthManager.shared.syncNow(via: appState.apiClient)
                    await PhotosManager.shared.syncNow()
                }
            case .background:
                LifeLogLiveActivityManager.refreshFromLocal(
                    macSummary: appState.lifelogSummary.isEmpty ? nil : appState.lifelogSummary
                )
                // Stop the SSE stream + health polling while backgrounded (battery),
                // and clear presence so the device gets push again while away.
                AppUsageTracker.shared.onBackground()
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Hermes").font(.system(.title3, weight: .semibold))
                    Spacer()
                    Button {
                        appState.openNewChat(); appState.showDrawer = false
                    } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .light))
                    }
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        drawerLink("ホーム", "house") { appState.tab = .home; appState.showDrawer = false }
                        NavigationLink {
                            CollectionView()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "tray.full").frame(width: 22).foregroundStyle(.secondary)
                                Text("コレクション").font(.system(.subheadline)).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 18).padding(.vertical, 12).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        drawerLink("自分について", "person.text.rectangle") { appState.activeSheet = .profile; appState.showDrawer = false }
                        drawerLink("頭の中を見る", "circle.hexagongrid.fill") { appState.activeSheet = .selfGraph; appState.showDrawer = false }
                        drawerLink("自分のリソース", "cpu") { appState.activeSheet = .selfResources; appState.showDrawer = false }
                        drawerLink("アプリ", "square.grid.2x2.fill") { appState.activeSheet = .apps; appState.showDrawer = false }
                        drawerLink("設定", "gearshape") { appState.activeSheet = .settings; appState.showDrawer = false }
                    }
                }
                .frame(maxHeight: 320)
                .padding(.bottom, 10)
            }
        }
    }

    private func drawerSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
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
    @ObservedObject private var health = HealthManager.shared

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

            // HealthKit
            Section {
                if let s = health.lastSummary {
                    LabeledRow(label: "最新", value: s)
                }
                if let t = health.lastSync {
                    LabeledRow(label: "最終同期", value: t.formatted(date: .omitted, time: .shortened))
                }
                Button {
                    Task { await health.syncNow(via: appState.apiClient) }
                } label: {
                    HStack {
                        Image(systemName: "heart.text.square")
                        Text("今すぐ同期")
                    }
                }
            } header: {
                Text("ヘルスケア連携")
            } footer: {
                Text("歩数・心拍・睡眠などをMacのHermesに送り、健康アドバイザーと連携します。読み出しの許可は iOS設定 > プライバシー > ヘルスケア > Hermes で変更できます。")
            }

            // Automations
            Section {
                NavigationLink {
                    AutomationsView()
                } label: {
                    Label("オートメーション", systemImage: "clock")
                }
            } footer: {
                Text("Mac上のHermesで定期実行するエージェントタスク（Cronジョブ）を管理します。")
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
