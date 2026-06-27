import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if appState.visibleSessions.isEmpty && !appState.isLoadingSessions {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("セッション")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.newSession()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18, weight: .light))
                }
            }
        }
        .refreshable {
            await appState.fetchSessions()
        }
        .task {
            await appState.fetchSessions()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)

            Text("セッションがありません")
                .font(.system(.title3, weight: .light))
                .foregroundStyle(.secondary)

            Text("チャットを始めると\nセッションが作成されます")
                .font(.system(.subheadline, weight: .light))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            // Current session indicator
            if let currentId = appState.currentSessionId {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 14))

                        Text("現在のセッション")
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(currentId.prefix(8) + "...")
                            .font(.system(.caption2, design: .monospaced, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Session list
            Section {
                ForEach(appState.visibleSessions) { session in
                    SessionRowView(
                        session: session,
                        isActive: session.id == appState.currentSessionId
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.switchSession(session.id)
                        dismiss()   // close the sheet → back to chat
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await appState.deleteSession(session.id) }
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("すべてのセッション")
                    Spacer()
                    if appState.isLoadingSessions {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text("\(appState.visibleSessions.count)件")
                            .font(.system(.caption2, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let session: Session
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Active indicator
            Circle()
                .fill(isActive ? Color.green : Color.clear)
                .frame(width: 8, height: 8)

            // Content
            VStack(alignment: .leading, spacing: 5) {
                // Title
                Text(session.title.isEmpty ? "無題のセッション" : session.title)
                    .font(.system(.body, weight: isActive ? .medium : .light))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Preview
                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(.system(.caption, weight: .light))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SessionListView()
    }
    .environmentObject(AppState())
}
