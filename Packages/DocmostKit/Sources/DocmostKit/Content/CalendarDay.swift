import Foundation

/// A day as Docmost 0.98's `date` node stores it, `YYYY-MM-DD`, read as strictly as the web's `parseCalendarDate`: an
/// impossible day ("2026-02-30") or another form is no day.
public struct CalendarDay: Sendable, Hashable, Comparable {
    /// Midnight of the day in UTC, as the web reads it.
    public let date: Date

    public init?(_ value: String?) {
        // Read by hand: a Regex and a DateFormatter parse took about 80 µs a value, this about 1 µs, and a calendar
        // reads every row's date again on each tap.
        guard let value, value.utf8.count == 10 else { return nil }
        let bytes = Array(value.utf8)
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), let year = Self.number(bytes[0..<4]), year > 0,
              let month = Self.number(bytes[5..<7]), let day = Self.number(bytes[8..<10])
        else { return nil }
        let parts = DateComponents(year: year, month: month, day: day)
        guard parts.isValidDate(in: Self.calendar), let date = Self.calendar.date(from: parts) else { return nil }
        self.date = date
    }

    /// The day the calendar shows at `date` in `timeZone` (the web's `formatISO(new Date(), { representation: "date" })`
    /// takes the browser's).
    public init(containing date: Date, in timeZone: TimeZone = .current) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        self.date = Self.calendar.date(from: parts) ?? date
    }

    /// As stored: `YYYY-MM-DD`.
    public var value: String { Self.formatter.string(from: date) }

    /// The day as the web labels it, month abbreviated ("Nov 20, 2026", "20. Nov. 2026").
    public func label(locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: Self.calendar)
        style.timeZone = .gmt
        return date.formatted(style)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool { lhs.date < rhs.date }

    /// The number ASCII digits spell; nil if one is no digit.
    private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
        var number = 0
        for byte in digits {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            number = number * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return number
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}
