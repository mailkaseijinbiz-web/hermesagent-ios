import SwiftUI

// MARK: - LIFEのBOOK 風デイリーページ（ほぼ日手帳アプリ参考）

enum LifeLogBookPalette {
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.14, green: 0.13, blue: 0.12)
            : Color(red: 0.99, green: 0.98, blue: 0.95)
    }

    static func pageStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    static var accentWarm: Color { Color(red: 0.72, green: 0.45, blue: 0.28) }
}

struct LifeLogBookPage<Content: View>: View {
    let date: Date
    let isToday: Bool
    var canGoForward: Bool = true
    var onPreviousDay: (() -> Void)? = nil
    var onNextDay: (() -> Void)? = nil
    var onJumpToToday: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LifeLogBookDateHeader(
                date: date,
                isToday: isToday,
                canGoForward: canGoForward,
                onPrevious: onPreviousDay,
                onNext: onNextDay,
                onJumpToToday: onJumpToToday
            )
            content()
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeLogBookPalette.paper(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LifeLogBookPalette.pageStroke(colorScheme), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.07), radius: 14, y: 5)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

struct LifeLogBookDateHeader: View {
    let date: Date
    let isToday: Bool
    var canGoForward: Bool = true
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onJumpToToday: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let onPrevious {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LifeLogBookPalette.accentWarm)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 36, height: 36)
            }

            Button {
                onJumpToToday?()
            } label: {
                VStack(alignment: .center, spacing: 4) {
                    Text(isToday ? "今日のページ" : "この日のページ")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LifeLogBookPalette.accentWarm)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Text(bookDateLine)
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(onJumpToToday == nil)

            if let onNext {
                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canGoForward ? LifeLogBookPalette.accentWarm : Color.secondary.opacity(0.35))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(!canGoForward)
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
    }

    private var bookDateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: date)
    }
}

struct LifeLogBookHint: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
                .font(.system(size: 12))
                .foregroundStyle(LifeLogBookPalette.accentWarm)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct LifeLogBookAside<Trailing: View>: View {
    let title: String
    let bodyText: String
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        bodyText: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.bodyText = bodyText
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LifeLogBookPalette.accentWarm)
                Spacer()
                trailing()
            }
            Text(bodyText)
                .font(.system(size: 16, design: .serif))
                .lineSpacing(6)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(LifeLogBookPalette.accentWarm.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct LifeLogBookCompactAside: View {
    let title: String
    let primaryText: String
    var secondaryText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(primaryText)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(.primary)
            if let secondaryText, !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct LifeLogBookStatsRow: View {
    let steps: Int
    let sleepHours: Double
    let restingHR: Int

    var body: some View {
        HStack(spacing: 16) {
            if steps > 0 {
                stat("figure.walk", "\(steps)", "歩")
            }
            if sleepHours > 0 {
                stat("bed.double.fill", String(format: "%.1f", sleepHours), "h")
            }
            if restingHR > 0 {
                stat("heart.fill", "\(restingHR)", "bpm")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private func stat(_ icon: String, _ value: String, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(value).fontWeight(.semibold).foregroundStyle(.primary)
            Text(unit)
        }
    }
}
