import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Calendar views (Docmost 0.98) by the web's rules (`calendar-adapter.ts`): the month's window, entries by their date
/// and their order, a new entry's date, the day list's times and the time zone notice. Loading:
/// `DatabaseDocmost098Tests`.
@MainActor
struct BaseCalendarTests {
    private let berlin: TimeZone
    private let newYork: TimeZone
    private let german = Locale(identifier: "de_DE")
    private let title: BaseProperty
    /// A date property, `d`.
    private let date: BaseProperty
    /// A date property with time, `w`.
    private let moment: BaseProperty
    /// November 2026, weeks from Monday: October 26 to December 6.
    private let november: BaseCalendarMonth

    init() throws {
        berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        newYork = try #require(TimeZone(identifier: "America/New_York"))
        title = try Self.decode(["id": "t", "name": "Title", "type": "text", "isPrimary": true])
        date = try Self.decode(["id": "d", "name": "Date", "type": "date"])
        moment = try Self.decode(["id": "w", "name": "When", "type": "date", "typeOptions": ["includeTime": true]])
        november = BaseCalendarMonth(containing: try #require(CalendarDay("2026-11-21")), weekStart: 1)
    }

    // MARK: Window

    /// Six weeks from the week start on or before the 1st, as the web's month layout loads them; the device names the
    /// week's start.
    @Test func monthWindowStartsOnTheWeekStart() throws {
        // November 1, 2026 is a Sunday.
        #expect(try november.first == day("2026-11-01"))
        #expect(try november.from == day("2026-10-26") && november.to == day("2026-12-06"))
        #expect(try november.days.count == 42 && november.days[1] == day("2026-10-27"))
        let sunday = BaseCalendarMonth(containing: try day("2026-11-30"), weekStart: 0)
        #expect(try sunday.from == day("2026-11-01") && sunday.to == day("2026-12-12"))
        #expect(try BaseCalendarMonth(containing: day("2026-11-01"), weekStart: 6).from == day("2026-10-31"))
        #expect(try november.contains(day("2026-11-30")) && !november.contains(day("2026-10-31")))
        #expect(try november == BaseCalendarMonth(containing: day("2026-11-03"), weekStart: 1), "one month, whichever its day")
    }

    /// Previous and next month go to the 1st, also across a year (the web's `shiftCalendarDate`).
    @Test func monthsMoveToTheFirst() throws {
        #expect(try november.first.adding(months: -1) == day("2026-10-01"))
        #expect(try day("2026-12-01").adding(months: 1) == day("2027-01-01"))
        #expect(try day("2026-01-01").adding(months: -1) == day("2025-12-01"))
        #expect(try day("2028-02-29").firstOfMonth == day("2028-02-01"))
    }

    // MARK: Entries

    /// A day shows on its day, a range of days on each it covers, the same in every time zone; also a day older servers
    /// stored as midnight UTC. Without a title an entry is "Untitled".
    @Test(arguments: ["Europe/Berlin", "America/New_York", "Pacific/Kiritimati"])
    func daysShowOnTheirDays(zone: String) throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        let rows = try decodeRows([
            ["id": "single", "cells": ["t": "Single", "d": ["start": "2026-11-21"]]],
            ["id": "range", "cells": ["t": "  ", "d": ["start": "2026-11-24", "end": "2026-11-26"]]],
            ["id": "legacy", "cells": ["d": "2026-11-10T00:00:00.000Z"]],
        ])
        let entries = BaseCalendarLayout.entries(of: rows, property: date, title: title, in: november, timeZone: timeZone)
        #expect(entries.map(\.rowId) == ["legacy", "single", "range"])
        #expect(entries.allSatisfy { $0.isAllDay })
        #expect(entries.map(\.title) == [nil, "Single", nil])
        let byDay = BaseCalendarLayout.entriesByDay(entries, in: november)
        let days = ["2026-11-10", "2026-11-21", "2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26", "2026-11-27"]
        #expect(try days.map { byDay[try day($0)]?.map(\.rowId) } == [["legacy"], ["single"], [], ["range"], ["range"], ["range"], []])
    }

    /// A moment shows on its day in the reader's time zone. Without an end it lasts an hour, but not into the next day;
    /// one that ends at midnight ends on the day before (the web's `toDisplaySpan` and `eventDayRange`).
    @Test func momentsShowInTheReadersTimeZone() throws {
        let rows = try decodeRows([
            // 9:00, 23:30 and 22:00 to midnight in Berlin.
            ["id": "morning", "cells": ["w": ["start": "2026-11-21T08:00:00.000Z"]]],
            ["id": "late", "cells": ["w": ["start": "2026-11-21T22:30:00.000Z"]]],
            ["id": "midnight", "cells": ["w": ["start": "2026-11-21T21:00:00.000Z", "end": "2026-11-22T23:00:00.000Z"]]],
        ])
        let entries = BaseCalendarLayout.entries(of: rows, property: moment, title: title, in: november, timeZone: berlin)
        #expect(entries.map(\.rowId) == ["morning", "midnight", "late"])
        #expect(entries.allSatisfy { !$0.isAllDay })
        let morning = try #require(entries.first)
        #expect(try morning.end == morning.start.addingTimeInterval(3_600) && morning.lastDay == day("2026-11-21"))
        let late = try #require(entries.last)
        #expect(try late.end == instant("2026-11-21T22:59:59.000Z") && late.lastDay == day("2026-11-21"))
        #expect(try entries[1].firstDay == day("2026-11-21") && entries[1].lastDay == day("2026-11-22"))
        // 23:30 UTC is 0:30 on the 22nd in Berlin, still the 21st in New York.
        let east = try decodeRows([["id": "r", "cells": ["w": ["start": "2026-11-21T23:30:00.000Z"]]]])
        #expect(try BaseCalendarLayout.entries(of: east, property: moment, title: title, in: november, timeZone: berlin).first?.firstDay
            == day("2026-11-22"))
        #expect(try BaseCalendarLayout.entries(of: east, property: moment, title: title, in: november, timeZone: newYork).first?.firstDay
            == day("2026-11-21"))
    }

    /// Rows without a date the app can read, and those outside the window, stay off the calendar; a range that began
    /// before the window shows on its days in it.
    @Test func undatedAndFarRowsStayOff() throws {
        let rows = try decodeRows([
            ["id": "none", "cells": ["t": "None"]],
            ["id": "empty", "cells": ["d": .null]],
            ["id": "text", "cells": ["d": "next week"]],
            ["id": "later", "cells": ["d": ["start": "2027-01-05"]]],
            ["id": "earlier", "cells": ["d": ["start": "2026-10-01", "end": "2026-10-25"]]],
            ["id": "into", "cells": ["d": ["start": "2026-10-20", "end": "2026-11-02"]]],
        ])
        let entries = BaseCalendarLayout.entries(of: rows, property: date, title: title, in: november, timeZone: berlin)
        #expect(entries.map(\.rowId) == ["into"])
        let byDay = BaseCalendarLayout.entriesByDay(entries, in: november)
        #expect(try byDay[day("2026-10-26")]?.map(\.rowId) == ["into"] && byDay[day("2026-11-03")] == [])
        #expect(try byDay[day("2026-10-20")] == nil, "before the window")
    }

    /// Entries go by start, the longer first where two start together, else in the answer's order (the web's
    /// `compareEvents`); a row the answer holds twice shows once.
    @Test func entriesGoByStartLongerFirst() throws {
        let rows = try decodeRows([
            ["id": "b", "cells": ["d": ["start": "2026-11-21"]]],
            ["id": "long", "cells": ["d": ["start": "2026-11-21", "end": "2026-11-23"]]],
            ["id": "a", "cells": ["d": ["start": "2026-11-21"]]],
            ["id": "early", "cells": ["d": ["start": "2026-11-20"]]],
            ["id": "b", "cells": ["d": ["start": "2026-11-01"]]],
        ])
        let entries = BaseCalendarLayout.entries(of: rows, property: date, title: title, in: november, timeZone: berlin)
        #expect(entries.map(\.rowId) == ["early", "long", "b", "a"])
    }

    /// "Created" and "Last edited" show entries at the row's own times, as moments.
    @Test func createdAndEditedShowTheRowsTimes() throws {
        let rows = try decodeRows([["id": "r", "cells": [:], "createdAt": "2026-11-21T07:36:18Z", "updatedAt": "2026-11-22T10:00:00Z"]])
        let created: BaseProperty = try Self.decode(["id": "c", "name": "Created", "type": "createdAt"])
        let edited: BaseProperty = try Self.decode(["id": "e", "name": "Edited", "type": "lastEditedAt"])
        let byCreation = BaseCalendarLayout.entries(of: rows, property: created, title: title, in: november, timeZone: berlin)
        #expect(try byCreation.map(\.firstDay) == [day("2026-11-21")] && byCreation.first?.isAllDay == false)
        #expect(try byCreation.first?.start == instant("2026-11-21T07:36:18.000Z"))
        #expect(BaseCalendarLayout.entries(of: rows, property: edited, title: title, in: november, timeZone: berlin).map(\.firstDay)
            == [try day("2026-11-22")])
    }

    // MARK: Date property

    /// A calendar goes by a date, "Created" or "Last edited" (not a formula); one naming none, or a property that is
    /// gone or holds no dates, has none. Only a date that isn't being converted takes a new entry's day.
    @Test func calendarsGoByTheirDateProperty() throws {
        let base: Base = try Self.decode([
            "id": "b", "views": [],
            "properties": [
                ["id": "d", "name": "Date", "type": "date"],
                ["id": "c", "name": "Created", "type": "createdAt"],
                ["id": "f", "name": "Due", "type": "formula", "typeOptions": ["resultType": "date"]],
                ["id": "x", "name": "Moved", "type": "date", "pendingType": "date", "pendingTypeOptions": ["includeTime": true]],
            ],
        ])
        func calendar(_ config: JSONValue) throws -> BaseView {
            try Self.decode(["id": "v", "name": "Calendar", "type": "calendar", "config": ["calendar": config]])
        }
        #expect(try ["d", "c", "f", "x", "gone"].map { BaseCalendarLayout.dateProperty(base: base, view: try calendar(["datePropertyId": .string($0)]))?.id }
            == ["d", "c", nil, "x", nil])
        #expect(BaseCalendarLayout.dateProperty(base: base, view: try calendar(["layout": "month"])) == nil)
        #expect(BaseCalendarLayout.datePropertyId(of: try calendar(["layout": "month"])) == nil)
        #expect(BaseCalendarLayout.datePropertyId(of: try calendar(["datePropertyId": "gone"])) == "gone")
        #expect(base.properties.map(BaseCalendarLayout.isEditable) == [true, false, false, false])
    }

    /// "New Entry" gives the chosen day; with time 9:00 there, where the web starts a new date (also on the day summer
    /// time begins), in Docmost 0.98's form.
    @Test func newEntryTakesTheChosenDay() throws {
        #expect(BaseCalendarLayout.value(on: try day("2026-11-21"), kind: .date, timeZone: berlin) == ["start": "2026-11-21"])
        #expect(BaseCalendarLayout.value(on: try day("2026-11-21"), kind: .datetime, timeZone: berlin) == ["start": "2026-11-21T08:00:00.000Z"])
        #expect(BaseCalendarLayout.value(on: try day("2026-03-29"), kind: .datetime, timeZone: berlin) == ["start": "2026-03-29T07:00:00.000Z"])
        #expect(BaseCalendarLayout.value(on: try day("2026-11-21"), kind: .datetime, timeZone: newYork) == ["start": "2026-11-21T14:00:00.000Z"])
    }

    // MARK: Day list

    /// The day's list says "All day" for a day, both days of a range, a moment's time, both times of a range within a
    /// day, else both ends with their days (the web's `formatEventWhen`).
    @Test func dayListNamesTheTimes() throws {
        func when(_ value: JSONValue, timed: Bool = false, options: JSONValue? = nil) throws -> String {
            let property = timed ? moment : date
            let rows = try decodeRows([["id": "r", "cells": .object([property.id: value])]])
            let entry = try #require(BaseCalendarLayout.entries(of: rows, property: property, title: title, in: november, timeZone: berlin).first)
            return BaseCalendarLayout.when(entry, options: options, timeZone: berlin, locale: german)
        }
        #expect(try when(["start": "2026-11-21"]) == String(localized: "All day"))
        #expect(try when(["start": "2026-11-24", "end": "2026-11-26"], options: ["dateFormat": "full"]) == "24. Nov. 2026 → 26. Nov. 2026")
        #expect(try when(["start": "2026-11-21T08:00:00.000Z"], timed: true) == "9:00")
        #expect(try when(["start": "2026-11-21T08:00:00.000Z", "end": "2026-11-21T09:30:00.000Z"], timed: true) == "9:00 – 10:30")
        #expect(try when(["start": "2026-11-21T08:00:00.000Z", "end": "2026-11-22T09:30:00.000Z"], timed: true)
            == "21. Nov. 2026 9:00 → 22. Nov. 2026 10:30")
        #expect(try when(["start": "2026-11-21T20:00:00.000Z"], timed: true, options: ["timeFormat": "12h"]).hasPrefix("9:00"))
    }

    /// A server that read the dates in another time zone is named where that matters: for moments, or for a filter by a
    /// date the server resolves; a zone with the reader's offsets all year is the reader's.
    @Test func otherTimeZoneIsNamedWhereItMatters() throws {
        let now = try instant("2026-11-21T08:00:00.000Z")
        let byToday: JSONValue = ["op": "and", "children": [["op": "or", "children": [
            ["propertyId": "d", "op": "onOrAfter", "value": ["mode": "relative", "preset": "today"]],
        ]]]]
        let byText: JSONValue = ["op": "and", "children": [["propertyId": "t", "op": "contains", "value": "x"]]]
        func named(_ zone: String?, _ kind: BaseDateKind, _ filter: JSONValue? = nil) -> String? {
            BaseCalendarLayout.foreignTimeZone(zone, kind: kind, filter: filter, reader: berlin, now: now)
        }
        #expect(named("UTC", .datetime) == "UTC")
        #expect(named("UTC", .date) == nil)
        #expect(named("UTC", .date, byText) == nil)
        #expect(named("UTC", .date, byToday) == "UTC")
        #expect(named("Europe/Berlin", .datetime) == nil && named("Europe/Paris", .datetime) == nil && named(nil, .datetime) == nil)
    }

    // MARK: Helpers

    private func day(_ text: String) throws -> CalendarDay {
        try #require(CalendarDay(text))
    }

    private func instant(_ text: String) throws -> Date {
        try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Rows as the server sends them, their own times without milliseconds.
    private func decodeRows(_ json: [JSONValue]) throws -> [BaseRow] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([BaseRow].self, from: JSONEncoder().encode(JSONValue.array(json)))
    }

    /// The models have no public initializers; build them as the server sends them.
    private static func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }
}
