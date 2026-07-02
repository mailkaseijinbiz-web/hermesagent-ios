import SwiftUI

// MARK: - Macハブの正準DayRecordを描画するコンポーネント群
// （24時間タイムバンド / メトリクス帯 / 今日の気づき / 週パルス）

// MARK: - 24時間タイムバンド

/// 1日を00〜24時の横バーで表す。帯の色は 睡眠=indigo / 在宅=teal / 外出=orange / Mac=purple。
struct DayTimeBandView: View {
    let bands: [TimeBand]
    var showNowMarker: Bool = false

    /// 帯の属する日の0時（epoch秒）。帯全体の中央時刻からその日の開始を求める。
    private var dayStartEpoch: Double {
        guard let minStart = bands.map(\.start).min(),
              let maxEnd = bands.map(\.end).max() else {
            return Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        }
        let mid = Date(timeIntervalSince1970: (minStart + maxEnd) / 2)
        return Calendar.current.startOfDay(for: mid).timeIntervalSince1970
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let day0 = dayStartEpoch
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                    ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                        let x0 = max(0.0, min(1.0, (band.start - day0) / 86400.0))
                        let x1 = max(0.0, min(1.0, (band.end - day0) / 86400.0))
                        if x1 > x0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(bandColor(band.kind))
                                .frame(width: max(2, CGFloat(x1 - x0) * width), height: 24)
                                .offset(x: CGFloat(x0) * width)
                        }
                    }
                    if showNowMarker {
                        let nowX = max(0.0, min(1.0, (Date().timeIntervalSince1970 - day0) / 86400.0))
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 1.5, height: 24)
                            .offset(x: CGFloat(nowX) * width)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 24)

            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text("\(hour)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if hour != 24 { Spacer() }
                }
            }
        }
    }

    private func bandColor(_ kind: String) -> Color {
        switch kind {
        case "sleep": return .indigo
        case "home": return .teal
        case "out": return .orange
        case "mac": return .purple
        default: return .gray
        }
    }
}

// MARK: - メトリクス帯

/// 歩数/睡眠/気分/安静心拍/運動分の横並びチップ。値のあるものだけ表示。
struct DayMetricsStrip: View {
    let metrics: DayMetrics

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let steps = metrics.steps {
                    chip(icon: "figure.walk", text: "\(steps)歩")
                }
                if let hours = metrics.sleepHours {
                    chip(icon: "bed.double.fill", text: String(format: "%.1fh", hours))
                }
                if let mood = metrics.moodScore {
                    chip(icon: nil, text: "\(moodEmoji(mood)) 気分")
                }
                if let hr = metrics.restingHeartRate {
                    chip(icon: "heart.fill", text: "\(hr)bpm")
                }
                if let minutes = metrics.exerciseMinutes {
                    chip(icon: "flame.fill", text: "運動\(minutes)分")
                }
            }
        }
    }

    private func chip(icon: String?, text: String) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.gray.opacity(0.1)))
    }

    private func moodEmoji(_ score: Int) -> String {
        switch score {
        case ..<2: return "😞"
        case 2: return "😕"
        case 3: return "😐"
        case 4: return "🙂"
        default: return "😄"
        }
    }
}

// MARK: - 今日の気づき

/// ハブが検知したその日の異常・気づきをオレンジのカードで並べる。
struct DayAnomaliesCard: View {
    let anomalies: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日の気づき")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            ForEach(anomalies, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    Text(item)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - 週パルス（直近7日ヒートマップ）

/// 直近7日を1日1列のミニカラムで表す。上のセルは歩数（teal・濃淡）、
/// 下のドットは気分スコア（赤<=2 / 黄=3 / 緑>=4 / 記録なし=灰）。
struct WeekPulseView: View {
    let rows: [LifelogRangeDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("この7日のパルス")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(rows) { row in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.teal.opacity(stepOpacity(row.steps)))
                            .frame(height: 28)
                        Circle()
                            .fill(moodColor(row.moodScore))
                            .frame(width: 6, height: 6)
                        Text(dayNumber(row.dateKey))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stepOpacity(_ steps: Int?) -> Double {
        guard let steps, steps > 0 else { return 0.08 }
        // 1万歩前後で最大濃度になるようスケール
        return min(1.0, 0.15 + Double(steps) / 12000.0)
    }

    private func moodColor(_ score: Int?) -> Color {
        guard let score else { return .gray.opacity(0.4) }
        if score <= 2 { return .red }
        if score == 3 { return .yellow }
        return .green
    }

    private func dayNumber(_ dateKey: String) -> String {
        // "yyyy-MM-dd" の日部分だけ（先頭ゼロは落とす）
        let day = dateKey.suffix(2)
        return day.hasPrefix("0") ? String(day.dropFirst()) : String(day)
    }
}
