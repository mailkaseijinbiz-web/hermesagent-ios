import SwiftUI

// MARK: - Color(hex:)

extension Color {
    /// Builds a color from a 6-digit hex string (with or without leading '#').
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(red: Double((v & 0xFF0000) >> 16) / 255,
                      green: Double((v & 0x00FF00) >> 8) / 255,
                      blue: Double(v & 0x0000FF) / 255)
        } else {
            self.init(.gray)
        }
    }
}

// MARK: - Company (roster + active employee picker)

/// The mobile "会社" screen: the AI-employee roster served by the Mac hub. Tapping a
/// member makes them the active employee and starts a fresh conversation with them.
struct CompanyView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                employeesStatusBanner

                Button { select(nil) } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color(.tertiarySystemFill)).frame(width: 50, height: 50)
                            Image(systemName: "person.crop.circle.dashed")
                                .font(.system(size: 21)).foregroundStyle(.secondary)
                        }
                        Text("全体（社員なし）").font(.system(.body, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 80)

                ForEach(appState.sortedEmployees) { e in
                    Button { select(e.id) } label: { employeeRow(e) }
                        .buttonStyle(.plain)
                    if e.id != appState.sortedEmployees.last?.id {
                        Divider().padding(.leading, 80)
                    }
                }

                if appState.employees.isEmpty {
                    emptyEmployeesHint
                        .padding(16)
                }
            }
        }
        .navigationTitle("社員")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await appState.autoConnectIfPossible()
            await appState.fetchEmployees()
            await appState.fetchSessions()
        }
        .task {
            await appState.autoConnectIfPossible()
            await appState.fetchEmployees()
            await appState.fetchSessions()
        }
        .onChange(of: appState.isConnected) { _, _ in
            Task { await appState.fetchEmployees() }
        }
    }

    @ViewBuilder
    private var employeesStatusBanner: some View {
        if let err = appState.employeesLoadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Button {
                    Task {
                        await appState.autoConnectIfPossible()
                        await appState.fetchEmployees()
                    }
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
        }
    }

    @ViewBuilder
    private var emptyEmployeesHint: some View {
        Group {
            if !appState.isConnected {
                Text("Macに接続されていません。ホーム画面の接続状態を確認してください。")
            } else if auth.isConfigured && !auth.isSignedIn {
                Text("Googleアカウントでサインインすると、Macの社員一覧を表示できます。")
            } else if let err = appState.employeesLoadError {
                Text(err)
            } else {
                Text("社員がいません。Macの「社員」タブで採用してください。")
            }
        }
        .font(.system(.footnote, weight: .light))
        .foregroundStyle(.secondary)
    }

    private func employeeRow(_ e: MobileEmployee) -> some View {
        let active = appState.activeEmployeeId == e.id
        let hasUnread = !active && appState.hasUnreadActivity(e.id)
        let snippet = appState.employeeSessionSnippet(for: e.id)

        return HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(Color(hex: e.accent).opacity(0.18))
                        .frame(width: 50, height: 50)
                    Text(e.emoji).font(.system(size: 23))
                }
                if hasUnread {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(e.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.primary)

                if let snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("まだ会話がありません")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func select(_ id: String?) {
        appState.talkTo(id)
    }
}

#Preview {
    NavigationStack { CompanyView() }
        .environmentObject(AppState())
        .environmentObject(AuthManager.shared)
}
