import SwiftUI

/// Intention cards for iOS home — tap to confirm, × to dismiss.
struct IntentionCardsSection: View {
    let vitalHint: String
    let vitalityMode: String
    let cards: [IntentionCard]
    let isLoading: Bool
    let isOffline: Bool
    var onConfirm: (IntentionCard) -> Void
    var onDismiss: (IntentionCard) -> Void
    var onRegenerate: () -> Void

    private var isSilent: Bool { cards.isEmpty && !isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if !vitalityMode.isEmpty { IOSVitalityBadge(mode: vitalityMode) }
                        if isOffline {
                            Text("オフライン")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    if !vitalHint.isEmpty {
                        Text(vitalHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button(action: onRegenerate) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
            .padding(.horizontal, 16)

            if cards.isEmpty {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("文脈を読み取っています…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                } else if isSilent {
                    Text("今日は静かに過ごすのも正解です。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        IntentionCardButton(
                            card: card,
                            onTap: { onConfirm(card) },
                            onDismiss: { onDismiss(card) }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct IOSVitalityBadge: View {
    let mode: String

    private var label: String {
        switch mode {
        case "depleted": return "消耗"
        case "recovering": return "回復"
        case "peak": return "集中向き"
        default: return "安定"
        }
    }

    private var color: Color {
        switch mode {
        case "depleted": return .orange
        case "recovering": return .green
        case "peak": return .purple
        default: return .blue
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct IntentionCardButton: View {
    let card: IntentionCard
    let onTap: () -> Void
    let onDismiss: () -> Void

    private var accent: Color {
        switch card.kind {
        case "recover": return .green
        case "rest":    return .indigo
        case "explore": return .orange
        case "task":    return .blue
        default:       return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: card.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(card.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let rationale = card.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.2), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onTap)
    }
}
