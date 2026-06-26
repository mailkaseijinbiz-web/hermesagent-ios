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
        List {
            statusSection

            Section {
                // "Talk to no one in particular" — clears the active employee.
                Button { select(nil) } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color(.tertiarySystemFill)).frame(width: 38, height: 38)
                            Image(systemName: "person.crop.circle.dashed")
                                .font(.system(size: 17)).foregroundStyle(.secondary)
                        }
                        Text("全体（社員なし）").font(.system(.body, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        if appState.activeEmployeeId == nil {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(appState.sortedEmployees) { e in
                    Button { select(e.id) } label: { employeeRow(e) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("社員")
            } footer: {
                if appState.employees.isEmpty {
                    Text("社員がいません。Macの「会社」タブで採用してください。")
                }
            }
        }
        .navigationTitle("会社")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.fetchEmployees() }
        .task { await appState.fetchEmployees() }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack {
                Label(appState.isConnected ? "接続中" : "オフライン",
                      systemImage: appState.isConnected ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                    .font(.system(.subheadline, weight: .light))
                    .foregroundStyle(appState.isConnected ? Color.green : .secondary)
                Spacer()
                Text("社員 \(appState.employees.count)名")
                    .font(.system(.subheadline, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func employeeRow(_ e: MobileEmployee) -> some View {
        let active = appState.activeEmployeeId == e.id
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: e.accent).opacity(0.18)).frame(width: 38, height: 38)
                Text(e.emoji).font(.system(size: 19))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).font(.system(.body, weight: .semibold)).foregroundStyle(.primary)
                    Text(e.roleTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: e.accent))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(hex: e.accent).opacity(0.14))
                        .clipShape(Capsule())
                }
                if !e.blurb.isEmpty {
                    Text(e.blurb).font(.system(.caption, weight: .light)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(formatModelName(e.model))
                    .font(.system(size: 10, weight: .light, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if active {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func select(_ id: String?) {
        appState.switchEmployee(id)   // no-op while streaming; guards the in-flight turn
        dismiss()
    }

    private func formatModelName(_ model: String) -> String {
        if let lastSlash = model.lastIndex(of: "/") {
            return String(model[model.index(after: lastSlash)...])
        }
        return model
    }
}

#Preview {
    NavigationStack { CompanyView() }
        .environmentObject(AppState())
}
