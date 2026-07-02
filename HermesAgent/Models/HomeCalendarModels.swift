import Foundation

/// ホーム画面の時間スコープ（日 / 週 / 月 / 年）。
enum HomeTimeScope: String, CaseIterable, Identifiable {
    case day, week, month, year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day:   return "日"
        case .week:  return "週"
        case .month: return "月"
        case .year:  return "年"
        }
    }
}

/// 日付キー・ナビゲーション・表示ラベルの共通ヘルパー。
enum HomeDateHelpers {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    static func dayKeyToDate(_ key: String, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        return f.date(from: key)
    }

    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func isToday(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDateInToday(date)
    }

    /// 週の開始日（カレンダーの firstWeekday に合わせる）。
    static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
        let day = startOfDay(date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: day)
        let first = calendar.firstWeekday
        let delta = (weekday - first + 7) % 7
        return calendar.date(byAdding: .day, value: -delta, to: day) ?? day
    }

    static func weekDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start = weekStart(for: date, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func monthStart(for date: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? startOfDay(date, calendar: calendar)
    }

    static func yearStart(for date: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year], from: date)
        return calendar.date(from: comps) ?? startOfDay(date, calendar: calendar)
    }

    static func navigate(_ date: Date, scope: HomeTimeScope, direction: Int, calendar: Calendar = .current) -> Date {
        let day = startOfDay(date, calendar: calendar)
        switch scope {
        case .day:
            return calendar.date(byAdding: .day, value: direction, to: day) ?? day
        case .week:
            return calendar.date(byAdding: .day, value: 7 * direction, to: day) ?? day
        case .month:
            return calendar.date(byAdding: .month, value: direction, to: day) ?? day
        case .year:
            return calendar.date(byAdding: .year, value: direction, to: day) ?? day
        }
    }

    static func jumpToToday(calendar: Calendar = .current) -> Date {
        startOfDay(Date(), calendar: calendar)
    }

    static func headerTitle(for date: Date, scope: HomeTimeScope, calendar: Calendar = .current) -> String {
        let ja = Locale(identifier: "ja_JP")
        switch scope {
        case .day:
            let f = DateFormatter()
            f.locale = ja
            f.dateFormat = "yyyy年M月d日（E）"
            return f.string(from: date)
        case .week:
            let days = weekDays(containing: date, calendar: calendar)
            guard let first = days.first, let last = days.last else { return "" }
            let f1 = DateFormatter()
            f1.locale = ja
            f1.dateFormat = "yyyy年M月d日"
            let f2 = DateFormatter()
            f2.locale = ja
            f2.dateFormat = "M月d日"
            if calendar.isDate(first, equalTo: last, toGranularity: .year) {
                return "\(f1.string(from: first)) – \(f2.string(from: last))"
            }
            return "\(f1.string(from: first)) – \(f1.string(from: last))"
        case .month:
            let f = DateFormatter()
            f.locale = ja
            f.dateFormat = "yyyy年M月"
            return f.string(from: date)
        case .year:
            let f = DateFormatter()
            f.locale = ja
            f.dateFormat = "yyyy年"
            return f.string(from: date)
        }
    }

    static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        guard isToday(date, calendar: calendar) else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M月d日の記録"
            return f.string(from: date)
        }
        switch calendar.component(.hour, from: Date()) {
        case 5..<11: return "おはようございます"
        case 11..<17: return "こんにちは"
        default: return "こんばんは"
        }
    }

    static func daysInMonth(for date: Date, calendar: Calendar = .current) -> [Date?] {
        let start = monthStart(for: date, calendar: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: start),
              let monthEnd = calendar.date(byAdding: .day, value: range.count - 1, to: start) else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        var d = start
        while d <= monthEnd {
            cells.append(d)
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? monthEnd.addingTimeInterval(86400)
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    static func monthNames(for yearDate: Date, calendar: Calendar = .current) -> [(month: Int, date: Date)] {
        let year = calendar.component(.year, from: yearDate)
        return (1...12).compactMap { m in
            var comps = DateComponents()
            comps.year = year
            comps.month = m
            comps.day = 1
            guard let d = calendar.date(from: comps) else { return nil }
            return (m, d)
        }
    }

    static func isSameDay(_ a: Date, _ b: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    static func dayRange(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = startOfDay(date, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start, end)
    }

    static func monthRange(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = monthStart(for: date, calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(86400 * 31)
        return (start, end)
    }

    static func yearRange(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = yearStart(for: date, calendar: calendar)
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start.addingTimeInterval(86400 * 366)
        return (start, end)
    }

    static func daysInWeek(containing date: Date, calendar: Calendar = .current) -> [Date] {
        weekDays(containing: date, calendar: calendar)
    }

    static func calendarGrid(for date: Date, calendar: Calendar = .current) -> [Date?] {
        daysInMonth(for: date, calendar: calendar)
    }

    static func monthsInYear(containing date: Date, calendar: Calendar = .current) -> [Date] {
        monthNames(for: date, calendar: calendar).map(\.date)
    }
}

typealias LifeLogDayKey = HomeDateHelpers

extension HomeTimeScope {
    func navigate(from date: Date, direction: Int, calendar: Calendar = .current) -> Date {
        HomeDateHelpers.navigate(date, scope: self, direction: direction, calendar: calendar)
    }
}
