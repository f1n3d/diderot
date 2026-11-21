import Foundation
import DocmostKit

/// Whether a property's dates are days or moments (Docmost's `DateKind`, `packages/base-formula/src/property.ts`).
nonisolated enum BaseDateKind: Sendable {
    /// Days without time: a date property without "include time", a formula whose result is a date.
    case date
    /// Moments, shown in the reader's time zone: a date property with "include time", a formula whose result is a date
    /// with time (`resultType: datetime`, Docmost 0.98).
    case datetime

    /// The web's `dateKindOfProperty`; nil for a property that holds no dates. Created and edited times come from the
    /// row, not from a cell (`BaseFormat.timestamp`).
    init?(of property: BaseProperty) {
        switch property.kind {
        case .date:
            self = property.typeOptions?["includeTime"]?.boolValue == true ? .datetime : .date
        case .formula:
            switch property.typeOptions?["resultType"]?.stringValue {
            case "date": self = .date
            case "datetime": self = .datetime
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// A date cell, a day or moment or a range of two (`packages/base-formula/src/date/grammar.ts`). Docmost 0.98 stores
/// `{start, end?}`: days as `YYYY-MM-DD`, moments as UTC instants with milliseconds, an end only after the start. Older
/// servers store one ISO string, which 0.98 reads too (`legacyDateCell`): a cell from before the upgrade, or written by
/// an older client since.
nonisolated struct BaseDateCell: Equatable, Sendable {
    /// One end of the range.
    enum Part: Equatable, Sendable {
        /// A day without time.
        case day(CalendarDay)
        case instant(Date)
    }

    var start: Part
    /// The range's end, a later part of the start's kind; nil for a single date.
    var end: Part?
    /// Read from the single string of older servers.
    private(set) var isLegacy = false

    /// An end that isn't later than the start, or of another kind, is no range: the web drops one equal to the start.
    init(start: Part, end: Part? = nil) {
        self.start = start
        self.end = end.flatMap { $0.isAfter(start) ? $0 : nil }
    }

    /// Either form, as the web's `readDateCell` reads them; nil for an empty cell or one without a date.
    init?(_ value: JSONValue?) {
        switch value {
        case .string(let text)?:
            guard let start = Part(text) else { return nil }
            self.init(start: start)
            isLegacy = true
        case .object(let object)?:
            guard let start = object["start"]?.stringValue.flatMap(Part.init) else { return nil }
            self.init(start: start, end: object["end"]?.stringValue.flatMap(Part.init))
        default:
            return nil
        }
    }

    /// As Docmost 0.98 stores it (`asObject`), else as older servers do: one string for the start (they know no
    /// ranges), a day at midnight UTC as the app and their web client wrote it.
    func value(asObject: Bool) -> JSONValue {
        guard asObject else { return .string(start.legacyText) }
        var object: [String: JSONValue] = ["start": .string(start.text)]
        if let end { object["end"] = .string(end.text) }
        return .object(object)
    }
}

nonisolated extension BaseDateCell.Part {
    /// A stored part: `YYYY-MM-DD`, or an ISO instant (with or without milliseconds, in UTC or with an offset).
    init?(_ text: String) {
        if let day = CalendarDay(text) {
            self = .day(day)
        } else if let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                    ?? (try? Date(text, strategy: .iso8601)) {
            self = .instant(date)
        } else {
            return nil
        }
    }

    /// As Docmost 0.98 stores it: the day, or the instant in UTC with milliseconds (`2026-10-09T07:30:00.000Z`).
    var text: String {
        switch self {
        case .day(let day): day.value
        case .instant(let date): date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
    }

    /// As older servers store it: an instant, a day as its midnight UTC.
    var legacyText: String {
        switch self {
        case .day(let day): day.value + "T00:00:00.000Z"
        case .instant: text
        }
    }

    /// Later than `other`, of the same kind; days and instants don't compare.
    func isAfter(_ other: Self) -> Bool {
        switch (self, other) {
        case let (.day(day), .day(otherDay)): day > otherDay
        case let (.instant(date), .instant(otherDate)): date > otherDate
        default: false
        }
    }

    /// The day the part shows as without time: an instant's day in `timeZone`, except midnight UTC, how a day was stored
    /// before Docmost 0.98, which would show as the day before west of UTC.
    func day(in timeZone: TimeZone) -> CalendarDay {
        switch self {
        case .day(let day):
            return day
        case .instant(let date):
            return CalendarDay(containing: date, in: date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0 ? .gmt : timeZone)
        }
    }
}
