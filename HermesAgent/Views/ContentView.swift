import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showAutomations = false
    @State private var showCompany = false

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

                        DrawerView(showSettings: $showSettings,
                                   showAutomations: $showAutomations,
                                   showCompany: $showCompany)
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
                .sheet(isPresented: $showCompany) {
                    NavigationStack {
                        CompanyView().toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("完了") { showCompany = false } }
                        }
                    }
                }
                .sheet(item: $appState.companySheet) { sheet in
                    NavigationStack {
                        Group {
                            switch sheet {
                            case .news:      NewsView()
                            case .dashboard: DashboardView()
                            case .schedule:  ScheduleView()
                            case .apps:      AppsView()
                            case .gmail:     GmailView()
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("完了") { appState.companySheet = nil } }
                        }
                    }
                }
                .sheet(item: $appState.employeeDetailTarget) { target in
                    NavigationStack {
                        EmployeeDetailView(employeeId: target.id).toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("完了") { appState.employeeDetailTarget = nil } }
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
            await HealthManager.shared.syncNow(via: appState.apiClient)
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
                    // HealthKit(歩数・心拍・睡眠など)を読み取りMacハブへ同期。接続ゲートの外で、
                    // 前面化のたび試行（サーバに届かなければ静かに失敗し次回再送）。
                    await HealthManager.shared.syncNow(via: appState.apiClient)
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
    @Binding var showCompany: Bool

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
                    employeesSection

                    // History scoped to the active employee (mirrors the Mac sidebar).
                    drawerSectionHeader(appState.activeEmployee.map { "\($0.name) のチャット" } ?? "履歴")
                    let visible = appState.visibleSessions
                    if visible.isEmpty {
                        Text(appState.activeEmployee == nil ? "チャット履歴がありません" : "この社員のチャットはまだありません")
                            .font(.system(.footnote, weight: .light))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(visible) { s in
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

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    drawerLink("ダッシュボード", "square.grid.2x2") { appState.companySheet = .dashboard; appState.showDrawer = false }
                    drawerLink("ニュース", "newspaper") { appState.companySheet = .news; appState.showDrawer = false }
                    drawerLink("スケジュール", "calendar") { appState.companySheet = .schedule; appState.showDrawer = false }
                    drawerLink("アプリ", "hammer") { appState.companySheet = .apps; appState.showDrawer = false }
                    drawerLink("Gmail", "envelope") { appState.companySheet = .gmail; appState.showDrawer = false }
                    drawerLink("会社・社員", "person.2") { showCompany = true; appState.showDrawer = false }
                    drawerLink("オートメーション", "clock") { showAutomations = true; appState.showDrawer = false }
                    drawerLink("設定", "gearshape") { showSettings = true; appState.showDrawer = false }
                }
            }
            .frame(maxHeight: 320)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Employees (company quick-switch)

    /// Compact roster at the top of the drawer: tap a 社員 to make them active and
    /// start a fresh chat. Managers appear first (`sortedEmployees`).
    @ViewBuilder
    private var employeesSection: some View {
        if !appState.employees.isEmpty {
            HStack {
                drawerSectionHeader("社員")
                Spacer()
                Button {
                    showCompany = true; appState.showDrawer = false
                } label: {
                    Text("会社").font(.system(.caption, weight: .medium)).foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }

            Button {
                appState.switchEmployee(nil)
                appState.showDrawer = false
            } label: {
                employeeChipRow(emoji: "person.crop.circle.dashed", isSystemImage: true,
                                title: "全体（社員なし）", subtitle: nil,
                                accent: nil, active: appState.activeEmployeeId == nil)
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            .disabled(appState.isStreaming)

            ForEach(appState.sortedEmployees) { e in
                Button {
                    appState.switchEmployee(e.id)
                    appState.showDrawer = false
                } label: {
                    employeeChipRow(emoji: e.emoji, isSystemImage: false,
                                    title: e.name, subtitle: e.roleTitle,
                                    accent: Color(hex: e.accent),
                                    active: appState.activeEmployeeId == e.id)
                }
                .buttonStyle(.plain).padding(.horizontal, 8)
                .disabled(appState.isStreaming)
                .contextMenu {
                    Button { appState.switchEmployee(e.id); appState.showDrawer = false } label: { Label("この社員と話す", systemImage: "bubble.left") }
                    Button { appState.employeeDetailTarget = EmployeeDetailTarget(id: e.id); appState.showDrawer = false } label: { Label("詳細を管理", systemImage: "square.grid.2x2") }
                }
            }

            Divider().padding(.vertical, 8)
        }
    }

    private func employeeChipRow(emoji: String, isSystemImage: Bool, title: String,
                                 subtitle: String?, accent: Color?, active: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill((accent ?? .secondary).opacity(0.16)).frame(width: 26, height: 26)
                if isSystemImage {
                    Image(systemName: emoji).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(emoji).font(.system(size: 14))
                }
            }
            Text(title)
                .font(.system(.subheadline, weight: active ? .semibold : .light))
                .foregroundStyle(.primary).lineLimit(1)
            if let subtitle = subtitle {
                Text(subtitle).font(.system(size: 10, weight: .light)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if active {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(active ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
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
