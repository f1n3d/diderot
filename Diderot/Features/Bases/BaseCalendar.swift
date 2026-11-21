import Foundation
import DocmostKit

/// The month a calendar view shows (Docmost 0.98): six weeks from the week start on or before its 1st, the window the
/// web loads for its month layout (`getCalendarWindow`). Days are Gregorian, as Docmost's are.
nonisolated struct BaseCalendarMonth: Equatable, Sendable {
    /// The month's 1st.
    let first: CalendarDay
    /// The 42 days shown, week by week.
    let days: [CalendarDay]

    /// The month of `day`; `weekStart` counts from 0 for Sunday, as `ViewerDateContext.weekStart` does.
    init(containing day: CalendarDay, weekStart: Int) {
        first = day.firstOfMonth
        let start = first.adding(days: -((first.weekday - weekStart + 7) % 7))
        days = (0..<42).map { start.adding(days: $0) }
    }

    /// The window's first and last day.
    var from: CalendarDay { days[0] }
    var to: CalendarDay { days[days.count - 1] }

    /// Whether `day` is of the month itself, not of the weeks around it.
    func contains(_ day: CalendarDay) -> Bool { day.firstOfMonth == first }
}

/// An entry of a calendar: a row by its date, on each day it covers in the reader's time zone.
nonisolated struct BaseCalendarEntry: Identifiable, Equatable, Sendable {
    let rowId: String
    /// The row's title; nil without one ("Untitled").
    let title: String?
    /// The row's date as read.
    let cell: BaseDateCell
    /// Whole days, not a moment: a date property without time, or a day in one with time while the server converts it.
    let isAllDay: Bool
    /// Days from the first one's midnight to the last one's end; a moment from its start to its end, or an hour later
    /// but not past midnight (the web's `toDisplaySpan`).
    let start: Date
    let end: Date
    /// The days it shows on.
    let firstDay: CalendarDay
    let lastDay: CalendarDay

    var id: String { rowId }

    func covers(_ day: CalendarDay) -> Bool { firstDay <= day && day <= lastDay }
}

/// Calendar views (Docmost 0.98) by the web's rules (`calendar-adapter.ts`): the date property, a window's entries and
/// their order, and the date of a new entry.
enum BaseCalendarLayout {
    /// The property types a calendar can go by (the web's `CALENDAR_DATE_SOURCE_TYPES`): dates, "Created" and "Last
    /// edited"; formulas can't.
    static func isDateSource(_ property: BaseProperty) -> Bool {
        property.kind == .date || property.kind == .createdAt || property.kind == .lastEditedAt
    }

    /// The property the view names (`config.calendar.datePropertyId`), also one that is gone.
    static func datePropertyId(of view: BaseView) -> String? {
        view.config?["calendar"]?["datePropertyId"]?.stringValue
    }

    /// The view's date property; nil while it names none, or one that is gone or holds no dates.
    static func dateProperty(base: Base, view: BaseView) -> BaseProperty? {
        guard let id = datePropertyId(of: view), let property = base.property(id: id), isDateSource(property) else { return nil }
        return property
    }

    /// Whether the calendar can give entries a date: by a date property, not while the server converts it (the web's
    /// `isEditableCalendarSource`); "Created" and "Last edited" are the server's.
    static func isEditable(_ property: BaseProperty) -> Bool {
        property.kind == .date && !property.isConverting
    }

    /// Days or moments; "Created" and "Last edited" are moments.
    static func kind(of property: BaseProperty) -> BaseDateKind {
        BaseDateKind(of: property) ?? .datetime
    }

    /// The entries of `rows` in the month's window, in the web's order (`toCalendarEvents`): by start, the longer one
    /// first where two start together. A row without a date the app can read is left out, as is one outside the window.
    static func entries(
        of rows: [BaseRow], property: BaseProperty, title: BaseProperty?, in month: BaseCalendarMonth,
        timeZone: TimeZone = .current
    ) -> [BaseCalendarEntry] {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let kind = kind(of: property)
        var seen: Set<String> = []
        var entries: [BaseCalendarEntry] = []
        for row in rows where seen.insert(row.id).inserted {
            guard let cell = date(of: row, property: property) else { continue }
            let entry = entry(row, cell: cell, kind: kind, title: title, calendar: local)
            guard entry.lastDay >= month.from, entry.firstDay <= month.to else { continue }
            entries.append(entry)
        }
        // The answer's order last, for entries alike.
        return entries.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end > b.element.end }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Each day's entries in the month's window, an entry of several days on each one it covers.
    static func entriesByDay(_ entries: [BaseCalendarEntry], in month: BaseCalendarMonth) -> [CalendarDay: [BaseCalendarEntry]] {
        Dictionary(uniqueKeysWithValues: month.days.map { day in (day, entries.filter { $0.covers(day) }) })
    }

    /// The date "New Entry" gives a row on `day`: the day, or with time 9:00 there, where the web starts a new date
    /// (`pickDay`); in Docmost 0.98's form, as calendars came with it.
    static func value(on day: CalendarDay, kind: BaseDateKind, timeZone: TimeZone = .current) -> JSONValue {
        guard kind == .datetime else { return BaseDateCell(start: .day(day)).value(asObject: true) }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let midnight = day.start(in: timeZone)
        let nine = local.date(bySettingHour: 9, minute: 0, second: 0, of: midnight) ?? midnight
        return BaseDateCell(start: .instant(nine)).value(asObject: true)
    }

    /// What the day's list says of an entry's time, as the web's phone layout does (`formatEventWhen`): "All day" for a
    /// day, a range of days in full; a moment's time, a range within one day as both times, a longer one in full.
    /// `options`: the date property's formats ("Created" and "Last edited" have none); a range's days show as "medium".
    static func when(
        _ entry: BaseCalendarEntry, options: JSONValue?, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        var medium = options?.objectValue ?? [:]
        medium["dateFormat"] = "medium"
        if entry.isAllDay {
            guard entry.cell.end != nil else { return String(localized: "All day") }
            return BaseFormat.date(entry.cell, kind: .date, options: .object(medium), timeZone: timeZone, locale: locale)
        }
        guard case .instant(let start) = entry.cell.start else { return "" }
        let startTime = BaseFormat.time(start, options: options, timeZone: timeZone, locale: locale)
        guard case .instant(let end)? = entry.cell.end else { return startTime }
        guard CalendarDay(containing: start, in: timeZone) == CalendarDay(containing: end, in: timeZone) else {
            return BaseFormat.date(entry.cell, kind: .datetime, options: .object(medium), timeZone: timeZone, locale: locale)
        }
        return startTime + " – " + BaseFormat.time(end, options: options, timeZone: timeZone, locale: locale)
    }

    /// The time zone a calendar's answer names (`meta.timeZone`; the server takes one it doesn't know for UTC) where it
    /// differs from the reader's and it matters: for moments, or for a filter by date, which the server resolves in it
    /// (the web's `notifyRowsZone`).
    static func foreignTimeZone(
        _ zone: String?, kind: BaseDateKind, filter: JSONValue?, reader: TimeZone = .current, now: Date = .now
    ) -> String? {
        guard let zone, kind == .datetime || filtersByDate(filter), !isSameTimeZone(zone, reader, now: now) else { return nil }
        return zone
    }

    /// Whether a filter compares with a date the server resolves (the web's `rowsDateKey`): a condition whose value has
    /// the `mode` exact, relative or range.
    static func filtersByDate(_ node: JSONValue?) -> Bool {
        if let children = node?["children"]?.arrayValue { return children.contains { filtersByDate($0) } }
        guard let mode = node?["value"]?["mode"]?.stringValue else { return false }
        return ["exact", "relative", "range"].contains(mode)
    }

    /// The row's date: its cell, or its own time for "Created" and "Last edited".
    private static func date(of row: BaseRow, property: BaseProperty) -> BaseDateCell? {
        switch property.kind {
        case .createdAt: row.createdAt.map { BaseDateCell(start: .instant($0)) }
        case .lastEditedAt: row.updatedAt.map { BaseDateCell(start: .instant($0)) }
        default: BaseDateCell(row.cells[property.id])
        }
    }

    private static func entry(
        _ row: BaseRow, cell: BaseDateCell, kind: BaseDateKind, title: BaseProperty?, calendar: Calendar
    ) -> BaseCalendarEntry {
        let text = title.flatMap { row.cells[$0.id]?.stringValue }
        let title = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
        let timeZone = calendar.timeZone
        guard kind == .datetime, case .instant(let start) = cell.start else {
            let firstDay = cell.start.day(in: timeZone)
            let lastDay = max(firstDay, (cell.end ?? cell.start).day(in: timeZone))
            return BaseCalendarEntry(
                rowId: row.id, title: title, cell: cell, isAllDay: true, start: firstDay.start(in: timeZone),
                end: lastDay.adding(days: 1).start(in: timeZone).addingTimeInterval(-1), firstDay: firstDay, lastDay: lastDay
            )
        }
        let firstDay = CalendarDay(containing: start, in: timeZone)
        let end: Date
        if case .instant(let last)? = cell.end {
            end = last
        } else if calendar.component(.hour, from: start) == 23 {
            end = firstDay.adding(days: 1).start(in: timeZone).addingTimeInterval(-1)
        } else {
            end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
        }
        // One that ends at midnight ends on the day before (the web's `eventDayRange`).
        var lastDay = CalendarDay(containing: end, in: timeZone)
        let clock = calendar.dateComponents([.hour, .minute, .second], from: end)
        if lastDay > firstDay, clock.hour == 0, clock.minute == 0, clock.second == 0 { lastDay = lastDay.adding(days: -1) }
        return BaseCalendarEntry(
            rowId: row.id, title: title, cell: cell, isAllDay: false, start: start, end: end, firstDay: firstDay, lastDay: lastDay
        )
    }

    /// The web's `isSameTimeZone`: the same name, or the same offset now and in half a year.
    private static func isSameTimeZone(_ name: String, _ zone: TimeZone, now: Date) -> Bool {
        guard name != zone.identifier else { return true }
        guard let other = TimeZone(identifier: name) else { return false }
        return [now, now.addingTimeInterval(182 * 86_400)].allSatisfy { other.secondsFromGMT(for: $0) == zone.secondsFromGMT(for: $0) }
    }
}

nonisolated extension CalendarDay {
    /// Days count in the Gregorian calendar, at midnight UTC as `CalendarDay` keeps them.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    func adding(days: Int) -> CalendarDay {
        CalendarDay(containing: Self.utc.date(byAdding: .day, value: days, to: date) ?? date, in: .gmt)
    }

    func adding(months: Int) -> CalendarDay {
        CalendarDay(containing: Self.utc.date(byAdding: .month, value: months, to: date) ?? date, in: .gmt)
    }

    /// The 1st of the day's month.
    var firstOfMonth: CalendarDay { adding(days: 1 - Self.utc.component(.day, from: date)) }

    /// The day of the week, 0 for Sunday.
    var weekday: Int { Self.utc.component(.weekday, from: date) - 1 }

    /// The day's first moment in `timeZone`.
    func start(in timeZone: TimeZone) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        return local.date(from: Self.utc.dateComponents([.year, .month, .day], from: date)) ?? date
    }
}
