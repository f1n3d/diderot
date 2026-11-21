import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Database dates as Docmost 0.98 stores them (`{start, end?}`) and as older servers do (one ISO string): read in both
/// forms, shown as the web shows them, written in the server's form.
@MainActor
struct BaseDateTests {
    private let german = Locale(identifier: "de_DE")
    private let berlin: TimeZone
    private let newYork: TimeZone

    init() throws {
        berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        newYork = try #require(TimeZone(identifier: "America/New_York"))
    }

    // MARK: Reading

    @Test func readsBothForms() throws {
        let legacy = try #require(BaseDateCell("2026-10-09T00:00:00.000Z"))
        #expect(legacy.start == .instant(try instant("2026-10-09T00:00:00.000Z")) && legacy.end == nil && legacy.isLegacy)
        #expect(BaseDateCell("2026-10-09")?.start == .day(try day("2026-10-09")))
        let single = try #require(BaseDateCell(["start": "2026-10-01"]))
        #expect(single.start == .day(try day("2026-10-01")) && single.end == nil && !single.isLegacy)
        let range = try #require(BaseDateCell(["start": "2026-10-01", "end": "2026-10-03"]))
        #expect(range.end == .day(try day("2026-10-03")))
        let moments = try #require(BaseDateCell(["start": "2026-10-09T07:30:00.000Z", "end": "2026-10-09T09:00:00Z"]))
        #expect(moments.start == .instant(try instant("2026-10-09T07:30:00.000Z")))
        #expect(moments.end == .instant(try instant("2026-10-09T09:00:00.000Z")))
    }

    /// An end the web wouldn't keep (on the start, before it, a day for a moment) is none; a cell without a date reads as
    /// none.
    @Test func readsOnlyRealRanges() {
        #expect(BaseDateCell(["start": "2026-10-03", "end": "2026-10-03"])?.end == nil)
        #expect(BaseDateCell(["start": "2026-10-03", "end": "2026-10-01"])?.end == nil)
        #expect(BaseDateCell(["start": "2026-10-03T10:00:00.000Z", "end": "2026-10-04"])?.end == nil)
        let noDates: [JSONValue?] = [nil, .null, "next week", "2026-02-30", 5, ["start": 5], ["end": "2026-10-03"],
                                     ["__err": "TYPE_MISMATCH", "msg": "x", "v": 1]]
        for value in noDates {
            #expect(BaseDateCell(value) == nil, "\(String(describing: value))")
        }
    }

    /// What the app writes reads back as written, in either form.
    @Test func writtenCellsReadBack() throws {
        let range = BaseDateCell(start: .instant(try instant("2026-10-09T07:30:00.000Z")), end: .instant(try instant("2026-10-10T09:00:00.000Z")))
        #expect(range.value(asObject: true) == ["start": "2026-10-09T07:30:00.000Z", "end": "2026-10-10T09:00:00.000Z"])
        #expect(BaseDateCell(range.value(asObject: true)) == range)
        let single = BaseDateCell(start: .day(try day("2026-10-09")))
        #expect(single.value(asObject: false) == "2026-10-09T00:00:00.000Z")
        #expect(BaseDateCell(single.value(asObject: false))?.start.day(in: newYork) == (try day("2026-10-09")))
    }

    // MARK: Showing

    /// A day shows as the same day in every time zone: in 0.98's form, and as older servers' midnight UTC.
    @Test(arguments: [-10, 0, 2, 14])
    func dayShowsTheStoredDayEverywhere(hours: Int) throws {
        let zone = try #require(TimeZone(secondsFromGMT: hours * 3600))
        for value: JSONValue in [["start": "2026-10-09"], "2026-10-09T00:00:00.000Z", "2026-10-09"] {
            #expect(show(value, kind: .date, in: zone) == "9. Okt. 2026", "\(value)")
        }
    }

    /// Before 0.98 another instant, such as now() in a formula, showed its local day, as in the web client of the time.
    @Test func olderInstantShowsItsLocalDay() throws {
        let utcPlusTwo = try #require(TimeZone(secondsFromGMT: 2 * 3600))
        #expect(show("2026-10-09T23:00:00.000Z", kind: .date, in: utcPlusTwo) == "10. Okt. 2026")
    }

    /// With time a moment shows in the reader's time zone, on the clock the property names, else the locale's.
    @Test func momentShowsInTheReadersTimeZone() {
        let cell: JSONValue = ["start": "2026-10-09T13:05:00.000Z"]
        #expect(show(cell, kind: .datetime, in: berlin) == "9. Okt. 2026 15:05")
        #expect(show(cell, kind: .datetime, in: newYork) == "9. Okt. 2026 9:05")
        #expect(show(cell, kind: .datetime, options: ["timeFormat": "12h"], in: berlin).hasPrefix("9. Okt. 2026 3:05"))
        #expect(show(cell, kind: .datetime, options: ["timeFormat": "24h"], in: berlin, locale: Locale(identifier: "en_US")) == "Oct 9, 2026 15:05")
        // An older server's instant in a property with time; a day without time in it (while the server converts).
        #expect(show("2026-10-09T13:05:00.000Z", kind: .datetime, in: berlin) == "9. Okt. 2026 15:05")
        #expect(show(["start": "2026-10-09"], kind: .datetime, in: berlin) == "9. Okt. 2026")
    }

    /// A range shows both ends; within one day the end as its time.
    @Test func rangeShowsStartAndEnd() {
        #expect(show(["start": "2026-10-01", "end": "2026-10-03"], kind: .date) == "1. Okt. 2026 – 3. Okt. 2026")
        #expect(show(["start": "2026-10-09T07:00:00.000Z", "end": "2026-10-09T08:30:00.000Z"], kind: .datetime, in: berlin)
            == "9. Okt. 2026 9:00 – 10:30")
        #expect(show(["start": "2026-10-09T07:00:00.000Z", "end": "2026-10-10T08:30:00.000Z"], kind: .datetime, in: berlin)
            == "9. Okt. 2026 9:00 – 10. Okt. 2026 10:30")
        // Two moments of one day in a property without time (while the server converts it): that day.
        #expect(show(["start": "2026-10-09T07:00:00.000Z", "end": "2026-10-09T08:30:00.000Z"], kind: .date, in: berlin) == "9. Okt. 2026")
    }

    /// Docmost 0.98's date formats as the web shows them; one it doesn't know (older servers stored free text) is "medium".
    @Test func dateFormatsFollowTheWeb() {
        func shown(_ format: String) -> String { show(["start": "2026-10-09"], kind: .date, options: ["dateFormat": .string(format)]) }
        #expect(shown("full") == "9. Oktober 2026")
        #expect(shown("medium") == "9. Okt. 2026")
        #expect(shown("monthDayYear") == "10/09/2026")
        #expect(shown("dayMonthYear") == "09/10/2026")
        #expect(shown("yearMonthDay") == "2026/10/09")
        #expect(shown("MMM D, YYYY") == "9. Okt. 2026")
    }

    /// "Relative" names yesterday, today and tomorrow, in the reader's time zone, and shows other days as "medium".
    @Test func relativeNamesTheDaysAroundToday() throws {
        let options: JSONValue = ["dateFormat": "relative"]
        // 22:00 in Berlin.
        let now = try instant("2026-10-09T20:00:00.000Z")
        func shown(_ value: JSONValue, kind: BaseDateKind = .date, at now: Date) -> String {
            show(value, kind: kind, options: options, in: berlin, now: now)
        }
        #expect(shown(["start": "2026-10-09"], at: now) == "Heute")
        #expect(shown(["start": "2026-10-08"], at: now) == "Gestern")
        #expect(shown(["start": "2026-10-10"], at: now) == "Morgen")
        #expect(shown(["start": "2026-10-11"], at: now) == "11. Okt. 2026")
        // 23:30 UTC is the next day in Berlin already.
        #expect(shown(["start": "2026-10-10"], at: try instant("2026-10-09T23:30:00.000Z")) == "Heute")
        #expect(shown(["start": "2026-10-09T13:05:00.000Z"], kind: .datetime, at: now) == "Heute 15:05")
    }

    /// Formulas hold dates where their result is one: days, or from Docmost 0.98 (`datetime`) moments.
    @Test func formulaDatesAreDates() throws {
        func property(_ type: String, _ options: JSONValue? = nil) throws -> BaseProperty {
            try Self.decode(["id": "p", "name": "P", "type": .string(type), "typeOptions": options ?? .null])
        }
        #expect(BaseDateKind(of: try property("formula", ["resultType": "date"])) == .date)
        #expect(BaseDateKind(of: try property("formula", ["resultType": "datetime"])) == .datetime)
        #expect(BaseDateKind(of: try property("formula", ["resultType": "number"])) == nil)
        #expect(BaseDateKind(of: try property("date", ["includeTime": false])) == .date)
        #expect(BaseDateKind(of: try property("date", ["includeTime": true])) == .datetime)
        #expect(BaseDateKind(of: try property("date")) == .date)
        #expect(BaseDateKind(of: try property("text")) == nil)
    }

    // MARK: Writing

    /// The picked day goes out in the server's form: one string at midnight UTC before Docmost 0.98 (also with time, which
    /// the web's picker there leaves out), `{start}` since, with time the picked moment. The day is Gregorian in every
    /// device calendar (`-testRegion TH`), at any hour.
    @Test(arguments: [0, 23])
    func pickedDayGoesOutInTheServersForm(hour: Int) throws {
        let picked = try #require(gregorian(in: berlin).date(from: DateComponents(year: 2026, month: 10, day: 9, hour: hour, minute: 30)))
        func written(_ kind: BaseDateKind, onDocmost098: Bool) -> JSONValue {
            BaseValue.date(picked, kind: kind, replacing: nil, onDocmost098: onDocmost098, timeZone: berlin)
        }
        #expect(written(.date, onDocmost098: false) == "2026-10-09T00:00:00.000Z")
        #expect(written(.datetime, onDocmost098: false) == "2026-10-09T00:00:00.000Z")
        #expect(written(.date, onDocmost098: true) == ["start": "2026-10-09"])
        #expect(written(.datetime, onDocmost098: true) == ["start": .string(hour == 0 ? "2026-10-08T22:30:00.000Z" : "2026-10-09T21:30:00.000Z")])
    }

    /// The picker opens on the day the cell shows, at the device's midnight: for an older server's midnight UTC west of
    /// UTC too, and another instant on its local day; with time at the moment itself.
    @Test func pickerOpensOnTheShownDay() throws {
        let local = gregorian(in: newYork)
        func opened(_ value: JSONValue, withTime: Bool = false) throws -> [Int?] {
            let cell = try #require(BaseDateCell(value))
            let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: BaseValue.pickerDate(cell, withTime: withTime, timeZone: newYork))
            return [parts.year, parts.month, parts.day, parts.hour, parts.minute]
        }
        #expect(try opened(["start": "2026-10-09"]) == [2026, 10, 9, 0, 0])
        #expect(try opened("2026-10-09T00:00:00.000Z") == [2026, 10, 9, 0, 0])
        #expect(try opened("2026-10-10T02:00:00.000Z") == [2026, 10, 9, 0, 0], "22:00 on the 9th in New York")
        #expect(try opened(["start": "2026-10-09T13:05:00.000Z"], withTime: true) == [2026, 10, 9, 9, 5])
        #expect(try opened(["start": "2026-10-09"], withTime: true) == [2026, 10, 9, 0, 0])
    }

    /// A new start keeps the range's end while that comes after it, as the web's picker does, and drops it once it
    /// doesn't. Older servers know no ranges.
    @Test func newStartKeepsALaterEnd() throws {
        let range = try #require(BaseDateCell(["start": "2026-10-01", "end": "2026-10-05"]))
        func picked(_ day: Int, onDocmost098: Bool = true) throws -> JSONValue {
            let date = try #require(gregorian(in: berlin).date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12)))
            return BaseValue.date(date, kind: .date, replacing: range, onDocmost098: onDocmost098, timeZone: berlin)
        }
        #expect(try picked(3) == ["start": "2026-10-03", "end": "2026-10-05"])
        #expect(try picked(5) == ["start": "2026-10-05"])
        #expect(try picked(7) == ["start": "2026-10-07"])
        let older = try #require(BaseDateCell("2026-10-01T00:00:00.000Z"))
        let date = try #require(gregorian(in: berlin).date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        #expect(BaseValue.date(date, kind: .date, replacing: older, onDocmost098: false, timeZone: berlin) == "2026-10-03T00:00:00.000Z")
    }

    /// With time, a new time on the start's day moves the end with it, so the range keeps its length; a new day keeps the
    /// end while it comes later (the web's `setTimeOfDay` and `pickDay`).
    @Test func newTimeMovesTheRange() throws {
        // 9:00 to 10:30 in Berlin on October 9.
        let range = try #require(BaseDateCell(["start": "2026-10-09T07:00:00.000Z", "end": "2026-10-09T08:30:00.000Z"]))
        func picked(_ moment: String) throws -> JSONValue {
            BaseValue.date(try instant(moment), kind: .datetime, replacing: range, onDocmost098: true, timeZone: berlin)
        }
        #expect(try picked("2026-10-09T09:00:00.000Z") == ["start": "2026-10-09T09:00:00.000Z", "end": "2026-10-09T10:30:00.000Z"])
        #expect(try picked("2026-10-08T07:00:00.000Z") == ["start": "2026-10-08T07:00:00.000Z", "end": "2026-10-09T08:30:00.000Z"])
        #expect(try picked("2026-10-12T07:00:00.000Z") == ["start": "2026-10-12T07:00:00.000Z"])
    }

    /// A cell in 0.98's form gets its new value in that form also where the server's version is unknown: as a string, its
    /// range lost the end.
    @Test func newFormStaysWhereTheVersionIsUnknown() throws {
        let range = try #require(BaseDateCell(["start": "2026-10-01", "end": "2026-10-05"]))
        let older = try #require(BaseDateCell("2026-10-01T00:00:00.000Z"))
        #expect(BaseValue.writesDateObject(onDocmost098: false, replacing: range))
        #expect(!BaseValue.writesDateObject(onDocmost098: false, replacing: older))
        #expect(!BaseValue.writesDateObject(onDocmost098: false, replacing: nil))
        #expect(BaseValue.writesDateObject(onDocmost098: true, replacing: older))
        let picked = try #require(gregorian(in: berlin).date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        #expect(BaseValue.date(picked, kind: .date, replacing: range, onDocmost098: false, timeZone: berlin)
            == ["start": "2026-10-03", "end": "2026-10-05"])
    }

    /// "Add Date" sets today in the reader's time zone; with time on 0.98 at 9:00, where the web's picker starts one.
    @Test func addDateSetsToday() throws {
        // 22:00 in Berlin.
        let now = try instant("2026-10-09T20:00:00.000Z")
        #expect(BaseValue.today(kind: .date, onDocmost098: true, now: now, timeZone: berlin) == ["start": "2026-10-09"])
        #expect(BaseValue.today(kind: .datetime, onDocmost098: true, now: now, timeZone: berlin) == ["start": "2026-10-09T07:00:00.000Z"])
        #expect(BaseValue.today(kind: .datetime, onDocmost098: false, now: now, timeZone: berlin) == "2026-10-09T00:00:00.000Z")
        let lateNow = try instant("2026-10-09T23:30:00.000Z")
        #expect(BaseValue.today(kind: .date, onDocmost098: false, now: lateNow, timeZone: berlin) == "2026-10-10T00:00:00.000Z")
    }

    // MARK: Helpers

    /// The cell's text, in German so the expected texts are fixed.
    private func show(
        _ value: JSONValue, kind: BaseDateKind, options: JSONValue? = nil, in timeZone: TimeZone = .gmt, locale: Locale? = nil,
        now: Date = .now
    ) -> String {
        guard let cell = BaseDateCell(value) else { return "" }
        return BaseFormat.date(cell, kind: kind, options: options, timeZone: timeZone, locale: locale ?? german, now: now)
    }

    private func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func instant(_ text: String) throws -> Date {
        try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func day(_ text: String) throws -> CalendarDay {
        try #require(CalendarDay(text))
    }

    /// The models have no public initializers; build them as the server sends them.
    private static func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }
}
