import Foundation

enum Format {
    /// "2:05:31" — the live readout on a running timer.
    static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }

    /// "2h 05m" — compact totals in tables and summaries.
    static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return String(format: "%dh %02dm", hours, minutes)
    }

    /// "2.09" — decimal hours, the unit invoices are actually built from.
    static func hours(_ seconds: Int) -> String {
        String(format: "%.2f", Double(max(0, seconds)) / 3600)
    }

    static func money(_ cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "$0.00"
    }

    /// Parses "250", "250.00", "$250" into cents. Returns nil on junk.
    static func parseMoney(_ text: String) -> Int? {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty, let value = Double(cleaned) else { return nil }
        return Int((value * 100).rounded())
    }

    /// One field of a duration. Blank counts as zero so you can fill in just
    /// hours, just minutes, or both. Returns nil only on genuinely bad input.
    private static func parseDurationField(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        guard let value = Double(trimmed), value >= 0, value.isFinite else { return nil }
        return value
    }

    /// Turns "1" hour and "45" minutes into 6300 seconds — which the app then
    /// reports as 1.75 decimal hours. Hours accepts a decimal too ("1.5"), so
    /// either habit works. Returns nil if a field is present but unreadable.
    static func parseDuration(hours: String, minutes: String) -> Int? {
        guard let hourValue = parseDurationField(hours),
              let minuteValue = parseDurationField(minutes) else { return nil }
        return Int((hourValue * 3600 + minuteValue * 60).rounded())
    }

    static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static let compactDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static let timeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "Mar 3 – Mar 16, 2026" for a period header.
    static func rangeLabel(_ range: DateRange, kind: PeriodKind) -> String {
        switch kind {
        case .day:
            return shortDate.string(from: range.start)
        case .week, .twoWeeks:
            let last = range.lastDay
            return "\(compactDate.string(from: range.start)) – \(shortDate.string(from: last))"
        }
    }
}
