import Foundation

/// A half-open date range [start, end).
struct DateRange: Hashable {
    var start: Date
    var end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// The inclusive last day, for display ("Mar 3 – Mar 16" rather than "– Mar 17").
    var lastDay: Date { end.addingTimeInterval(-1) }
}

enum PeriodKind: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case twoWeeks = "Two Weeks"

    var id: String { rawValue }

    /// How far one tap of the ‹ › arrows moves.
    var strideDays: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .twoWeeks: return 14
        }
    }
}

enum Periods {
    static func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func day(containing date: Date, firstWeekday: Int) -> DateRange {
        let calendar = calendar(firstWeekday: firstWeekday)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateRange(start: start, end: end)
    }

    static func week(containing date: Date, firstWeekday: Int) -> DateRange {
        let calendar = calendar(firstWeekday: firstWeekday)
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        // How many days back to the configured first weekday.
        let offset = (weekday - firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: startOfDay) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        return DateRange(start: start, end: end)
    }

    /// Two-week periods tile the calendar outward from `anchor` in both directions.
    static func twoWeeks(containing date: Date, anchor: Date, firstWeekday: Int) -> DateRange {
        let calendar = calendar(firstWeekday: firstWeekday)
        let anchorDay = calendar.startOfDay(for: anchor)
        let targetDay = calendar.startOfDay(for: date)
        let daysSinceAnchor = calendar.dateComponents([.day], from: anchorDay, to: targetDay).day ?? 0
        // Floor division so periods before the anchor tile correctly too.
        let periodIndex = Int(floor(Double(daysSinceAnchor) / 14.0))
        let start = calendar.date(byAdding: .day, value: periodIndex * 14, to: anchorDay) ?? anchorDay
        let end = calendar.date(byAdding: .day, value: 14, to: start) ?? start.addingTimeInterval(14 * 86_400)
        return DateRange(start: start, end: end)
    }

    static func range(_ kind: PeriodKind, containing date: Date, settings: AppSettings) -> DateRange {
        switch kind {
        case .day: return day(containing: date, firstWeekday: settings.firstWeekday)
        case .week: return week(containing: date, firstWeekday: settings.firstWeekday)
        case .twoWeeks: return twoWeeks(containing: date, anchor: settings.periodAnchor, firstWeekday: settings.firstWeekday)
        }
    }

    /// Every day-start within a range, used to build the daily bar chart.
    static func days(in range: DateRange, firstWeekday: Int) -> [Date] {
        let calendar = calendar(firstWeekday: firstWeekday)
        var result: [Date] = []
        var cursor = calendar.startOfDay(for: range.start)
        while cursor < range.end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}
