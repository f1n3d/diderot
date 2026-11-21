import Foundation
import Testing
@testable import DocmostKit

/// Dev instance responses for the kanban template ("Kanban-Test" with three cards).
struct BaseFixtureTests {
    @Test func baseInfo() throws {
        let base = try TestSupport.decodeFixture(Base.self, "base-info")
        #expect(base.displayTitle == "Kanban-Test")
        #expect(base.canEdit)
        #expect(base.primaryProperty?.name == "Title")
        #expect(base.primaryProperty?.kind == .text)
        let status = try #require(base.properties.first { $0.kind == .status })
        #expect(status.typeOptions?["choices"]?.arrayValue?.count == 3)
        let view = try #require(base.views.first)
        #expect(view.kind == .kanban)
        #expect(view.config?["groupByPropertyId"]?.stringValue == status.id)
    }

    @Test func baseRows() throws {
        let page = try TestSupport.decodeFixture(BaseRowsPage.self, "base-rows")
        #expect(page.items.count == 3)
        #expect(!page.meta.hasNextPage)
        let base = try TestSupport.decodeFixture(Base.self, "base-info")
        let title = try #require(base.primaryProperty)
        #expect(page.items.compactMap { $0.cells[title.id]?.stringValue }.sorted() == ["Karte 1", "Karte 2", "Karte 3"])
        #expect(page.items.allSatisfy { $0.position != nil && $0.createdAt != nil })
    }

    @Test func unknownTypesStayReadable() {
        let property = BaseProperty(
            id: "prpx", name: "Neu", type: "rollup", position: nil, isPrimary: false, typeOptions: nil, pendingType: nil,
            pendingTypeOptions: nil
        )
        #expect(property.kind == nil)
        let view = BaseView(id: "v", name: "Zeitleiste", type: "timeline", position: nil, config: nil)
        #expect(view.kind == .table)
    }

    /// Calendar views (Docmost 0.98) are calendars; they showed as a table. A property the server converts says so, as
    /// the web's "Converting…" badge does.
    @Test func calendarViewsAndConvertingProperties() throws {
        let base = try JSONDecoder().decode(Base.self, from: Data("""
        {"id": "b", "views": [{"id": "v", "name": "Kalender", "type": "calendar", "position": "a0",
                               "config": {"calendar": {"layout": "month", "datePropertyId": "prpd"}}}],
         "properties": [{"id": "prpd", "name": "Date", "type": "date", "typeOptions": null, "pendingType": null,
                         "pendingTypeOptions": null},
                        {"id": "prpe", "name": "Due", "type": "date", "pendingType": "date",
                         "pendingTypeOptions": {"includeTime": true}}]}
        """.utf8))
        #expect(base.views.first?.kind == .calendar)
        #expect(base.views.first?.config?["calendar"]?["datePropertyId"] == "prpd")
        #expect(base.properties.map(\.isConverting) == [false, true])
    }

    /// A calendar asks for its window's days, the view's filter and the reader's calendar, as the web's does; no sorts
    /// or cursor, which the server drops.
    @Test func calendarRowsRequest() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        var monday = Calendar(identifier: .gregorian)
        monday.firstWeekday = 2
        let viewer = ViewerDateContext(timeZone: berlin, calendar: monday, now: try Date("2026-11-21T08:00:00Z", strategy: .iso8601))
        let filter: JSONValue = ["op": "and", "children": [["propertyId": "prpt", "op": "contains", "value": "day"]]]
        let endpoint = Endpoints.Bases.calendarRows(
            pageId: "p1", propertyId: "prpd", from: try #require(CalendarDay("2026-10-26")), to: try #require(CalendarDay("2026-12-06")),
            filter: filter, viewer: viewer
        )
        #expect(endpoint.path == "bases/rows/calendar")
        #expect(try body(of: endpoint) == [
            "pageId": "p1", "propertyId": "prpd", "from": "2026-10-26", "to": "2026-12-06", "filter": filter, "limit": 1000,
            "timeZone": "Europe/Berlin", "today": "2026-11-21", "weekStart": 1,
        ])
        let unfiltered = Endpoints.Bases.calendarRows(
            pageId: "p1", propertyId: "prpd", from: try #require(CalendarDay("2026-10-26")), to: try #require(CalendarDay("2026-12-06"))
        )
        #expect(try body(of: unfiltered)["filter"] == nil)
    }

    /// Docmost 0.98's answer (from the dev instance: November 2026's window of "Calendar probe"): the rows meeting the
    /// window, a range that began before it first, and how many there are.
    @Test func calendarAnswer() throws {
        let answer = try TestSupport.decodeFixture(BaseCalendarRows.self, "base-calendar-rows")
        #expect(answer.items.compactMap { $0.cells["prpvsf6nojse"]?.stringValue }
            == ["Before window, into it", "Legacy midnight", "Single day", "Three days"])
        #expect(answer.items.first?.cells["prpzchk68la9"] == ["start": "2026-10-20", "end": "2026-11-02"])
        #expect(answer.meta == .init(total: 4, truncated: false, timeZone: "Europe/Berlin"))
        #expect(answer.references?.users?.values.map(\.name) == ["Dev Admin"])
    }

    /// Form views (Docmost 0.98) stay hidden, as on the web while forms are in beta; they showed as a table.
    @Test func formViewsStayHidden() throws {
        let base = try JSONDecoder().decode(Base.self, from: Data("""
        {"id": "b", "properties": [], "views": [
          {"id": "board", "name": "Board", "type": "kanban", "position": "a2"},
          {"id": "form", "name": "Formular", "type": "form", "position": "a0"},
          {"id": "table", "name": "Tabelle", "type": "table", "position": "a1"},
          {"id": "calendar", "name": "Kalender", "type": "calendar", "position": "a3"}]}
        """.utf8))
        #expect(base.shownViews.map(\.id) == ["table", "board", "calendar"])
    }

    /// A rows request names the reader's time zone, day and week as the web's does (Docmost 0.98 resolves date filters in
    /// them; older servers drop them unread).
    @Test func rowsRequestNamesTheReadersCalendar() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        var monday = Calendar(identifier: .gregorian)
        monday.firstWeekday = 2
        // 23:30 UTC on November 20 is November 21 in Berlin.
        let now = try Date("2026-11-20T23:30:00Z", strategy: .iso8601)
        let viewer = ViewerDateContext(timeZone: berlin, calendar: monday, now: now)
        #expect(viewer == ViewerDateContext(timeZone: berlin, calendar: monday, now: now))
        let endpoint = Endpoints.Bases.rows(pageId: "p1", cursor: "c", viewer: viewer)
        #expect(endpoint.path == "bases/rows")
        #expect(try body(of: endpoint) == [
            "pageId": "p1", "cursor": "c", "limit": 100, "timeZone": "Europe/Berlin", "today": "2026-11-21", "weekStart": 1,
        ])
        var sunday = Calendar(identifier: .gregorian)
        sunday.firstWeekday = 1
        #expect(ViewerDateContext(timeZone: .gmt, calendar: sunday, now: now).weekStart == 0)
        #expect(ViewerDateContext(timeZone: .gmt, calendar: sunday, now: now).today == "2026-11-20")
    }
}
