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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
                    Text("社員がいません。Macの「会社」タブで採用してください。")
                        .font(.system(.footnote, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            }
        }
        .navigationTitle("社員")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.fetchEmployees() }
        .task { await appState.fetchEmployees() }
    }

    private func employeeRow(_ e: MobileEmployee) -> some View {
        let active = appState.activeEmployeeId == e.id
        let hasUnread = !active && appState.hasUnreadActivity(e.id)
        let recent = appState.recentSession(for: e.id)

        return HStack(spacing: 14) {
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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(e.roleTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: e.accent))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(hex: e.accent).opacity(0.14))
                        .clipShape(Capsule())
                }
                // blurb (persona description)
                if !e.blurb.isEmpty {
                    Text(e.blurb)
                        .font(.system(.caption, weight: .light))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Recent session preview (さわり)
                if let session = recent, !session.preview.isEmpty {
                    Text(session.preview)
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let session = recent, !session.title.isEmpty, session.title != "新しいチャット" {
                    Text(session.title)
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()
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
}
