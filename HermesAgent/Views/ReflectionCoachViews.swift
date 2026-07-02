import SwiftUI

// MARK: - 気分トレンド（夜の振り返りのmoodScoreを14日分）

struct MoodTrendChart: View {
    let entries: [ReflectionEntry]

    private var scored: [ReflectionEntry] { entries.filter { $0.moodScore != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("気分の推移")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let avg = averageText {
                    Text(avg).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if scored.isEmpty {
                Text("夜の振り返りに答えると、ここに気分の推移が表示されます")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(entries, id: \.dateKey) { e in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barColor(e.moodScore))
                                .frame(height: barHeight(e.moodScore))
                            Text(dayLabel(e.dateKey))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 52)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var averageText: String? {
        let scores = scored.compactMap(\.moodScore)
        guard !scores.isEmpty else { return nil }
        let avg = Double(scores.reduce(0, +)) / Double(scores.count)
        return String(format: "平均 %.1f / 5", avg)
    }

    private func barHeight(_ mood: Int?) -> CGFloat {
        guard let mood else { return 3 }
        return CGFloat(mood) / 5.0 * 36 + 4
    }

    private func barColor(_ mood: Int?) -> Color {
        guard let mood else { return Color.primary.opacity(0.08) }
        switch mood {
        case ..<2:  return .red.opacity(0.7)
        case 2:     return .orange.opacity(0.7)
        case 3:     return .yellow.opacity(0.75)
        case 4:     return .green.opacity(0.7)
        default:    return .green
        }
    }

    private func dayLabel(_ dateKey: String) -> String {
        let day = String(dateKey.suffix(2))
        return day.hasPrefix("0") ? String(day.suffix(1)) : day
    }
}

// MARK: - 自己グラフ差分提案（承認制）

struct GraphProposalList: View {
    let proposals: [SelfGraphProposal]
    let onDecide: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("自己グラフへの提案")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(proposals.count)")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(proposals) { p in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(kindLabel(p))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.purple.opacity(0.12))
                                .clipShape(Capsule())
                            Text(changeSummary(p))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        Text(p.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { onDecide(p.id, true) } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    Button { onDecide(p.id, false) } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func kindLabel(_ p: SelfGraphProposal) -> String {
        switch p.kind {
        case "addNode":        return "ノード追加"
        case "addLink":        return "リンク追加"
        case "strengthenLink": return "リンク強化"
        default:               return p.kind
        }
    }

    private func changeSummary(_ p: SelfGraphProposal) -> String {
        switch p.kind {
        case "addNode":
            return "「\(p.nodeLabel ?? "?")」を追加"
        default:
            return "「\(p.sourceLabel ?? "?")」↔「\(p.targetLabel ?? "?")」"
        }
    }
}
