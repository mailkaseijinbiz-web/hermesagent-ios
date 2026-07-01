import SwiftUI

struct CollectionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            if appState.collectionItems.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("まだコレクションがありません")
                            .font(.system(size: 15, weight: .medium))
                        Text("共有シートから保存したURL・テキスト・写真がここに集まります。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(appState.collectionItems) { item in
                    collectionRow(item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await appState.deleteCollectionItem(id: item.id) }
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle("コレクション")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.fetchCollection() }
        .task { await appState.fetchCollection() }
    }

    private func collectionRow(_ item: CollectionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent(for: item.kind))
                .frame(width: 30, height: 30)
                .background(accent(for: item.kind).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)

                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !item.text.isEmpty, item.kind != "text" || item.title.isEmpty {
                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let link = URL(string: item.url), !item.url.isEmpty {
                    Link(item.url, destination: link)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(item.relativeDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if item.imageCount > 0 {
                        Text("📷 \(item.imageCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func accent(for kind: String) -> Color {
        switch kind {
        case "url":   return .blue
        case "image": return .purple
        case "video": return .orange
        default:      return .secondary
        }
    }
}
