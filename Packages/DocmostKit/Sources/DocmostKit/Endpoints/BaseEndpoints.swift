import Foundation

extension Endpoints {
    /// Databases ("bases"). Reading needs no license; writing needs the `bases` license feature (Business and up).
    public enum Bases {
        public struct PageBody: Encodable, Sendable {
            public let pageId: String
        }

        /// Database with properties, views and permissions; `id` is the ID of its page.
        public static func info(pageId: String) -> Endpoint<Base> {
            .post("bases/info", body: PageBody(pageId: pageId))
        }

        public struct RowsBody: Encodable, Sendable {
            public let pageId: String
            public var filter: JSONValue?
            public var sorts: JSONValue?
            public var limit: Int?
            public var cursor: String?
            public var timeZone: String
            public var today: String
            public var weekStart: Int
        }

        /// Rows in position order, max 100 per call. The endpoint knows no views: pass a view's `filter` and `sorts`. A
        /// cursor whose row changed meanwhile fails (`APIError.isStaleBaseCursor`): the list starts again without one.
        public static func rows(
            pageId: String, filter: JSONValue? = nil, sorts: JSONValue? = nil, cursor: String? = nil, limit: Int = 100,
            viewer: ViewerDateContext = ViewerDateContext()
        ) -> Endpoint<BaseRowsPage> {
            .post("bases/rows", body: RowsBody(
                pageId: pageId, filter: filter, sorts: sorts, limit: limit, cursor: cursor,
                timeZone: viewer.timeZone, today: viewer.today, weekStart: viewer.weekStart
            ))
        }

        public struct CalendarRowsBody: Encodable, Sendable {
            public let pageId: String
            public let propertyId: String
            public let from: String
            public let to: String
            public var filter: JSONValue?
            public var limit: Int
            public var timeZone: String
            public var today: String
            public var weekStart: Int
        }

        /// The most rows a calendar window gets, the server's limit, which the web asks for (`CALENDAR_WINDOW_LIMIT`).
        public static let calendarRowLimit = 1000

        /// A calendar's rows (Docmost 0.98): those whose date in `propertyId` (a date property, "Created" or "Last
        /// edited"; another type fails) meets the days `from` to `to` in the reader's time zone, at most `limit`, with
        /// the view's `filter`. No sorts and no cursor: the answer says how many rows there are.
        public static func calendarRows(
            pageId: String, propertyId: String, from: CalendarDay, to: CalendarDay, filter: JSONValue? = nil,
            limit: Int = calendarRowLimit, viewer: ViewerDateContext = ViewerDateContext()
        ) -> Endpoint<BaseCalendarRows> {
            .post("bases/rows/calendar", body: CalendarRowsBody(
                pageId: pageId, propertyId: propertyId, from: from.value, to: to.value, filter: filter, limit: limit,
                timeZone: viewer.timeZone, today: viewer.today, weekStart: viewer.weekStart
            ))
        }

        // MARK: Writing (license feature `bases`)

        public struct CreateBody: Encodable, Sendable {
            public let parentPageId: String
            public var template: String?
        }

        /// Response of `bases/create`: the new database page.
        public struct Created: Decodable, Sendable, Hashable {
            public let id: String
        }

        /// New database as a subpage, like the web editor's database and kanban slash commands. `template: "kanban"`
        /// creates it with a kanban view; without a template it gets a table view.
        public static func create(parentPageId: String, template: String? = nil) -> Endpoint<Created> {
            .post("bases/create", body: CreateBody(parentPageId: parentPageId, template: template))
        }

        public struct ConvertBody: Encodable, Sendable {
            public let pageId: String
            public var template: String?
        }

        /// Turns an empty page into a database (Docmost 0.95), as the web's "Get started with" does: with `template:
        /// "kanban"` it gets a kanban view, otherwise a table view.
        public static func convert(pageId: String, template: String? = nil) -> Endpoint<NoContent> {
            .post("bases/convert", body: ConvertBody(pageId: pageId, template: template))
        }

        public struct CreateRowBody: Encodable, Sendable {
            public let pageId: String
            public var cells: [String: JSONValue]
            public var position: String?
        }

        /// New row. Without `position` the server appends it; the response is the complete row.
        public static func createRow(
            pageId: String, cells: [String: JSONValue] = [:], position: String? = nil
        ) -> Endpoint<BaseRow> {
            .post("bases/rows/create", body: CreateRowBody(pageId: pageId, cells: cells, position: position))
        }

        public struct UpdateRowBody: Encodable, Sendable {
            public let rowId: String
            public let pageId: String
            public var cells: [String: JSONValue]
            public var position: String?
        }

        /// Patches cells: only the given properties change, `null` clears a cell. With `position` the row also moves
        /// (kanban board: column and order in one call).
        public static func updateRow(
            pageId: String, rowId: String, cells: [String: JSONValue], position: String? = nil
        ) -> Endpoint<BaseRow> {
            .post("bases/rows/update", body: UpdateRowBody(rowId: rowId, pageId: pageId, cells: cells, position: position))
        }

        public struct RowBody: Encodable, Sendable {
            public let rowId: String
            public let pageId: String
        }

        /// One row by id, also one outside the loaded pages or the view's filter (a link to an entry).
        public static func rowInfo(pageId: String, rowId: String) -> Endpoint<BaseRow> {
            .post("bases/rows/info", body: RowBody(rowId: rowId, pageId: pageId))
        }

        public static func deleteRow(pageId: String, rowId: String) -> Endpoint<NoContent> {
            .post("bases/rows/delete", body: RowBody(rowId: rowId, pageId: pageId))
        }

        public struct UpdatePropertyBody: Encodable, Sendable {
            public let propertyId: String
            public let pageId: String
            public var typeOptions: JSONValue
        }

        /// Changes a property's options (e.g. a new select option). Without a type change no background job runs.
        public static func updateProperty(pageId: String, propertyId: String, typeOptions: JSONValue) -> Endpoint<UpdatePropertyResult> {
            .post("bases/properties/update", body: UpdatePropertyBody(propertyId: propertyId, pageId: pageId, typeOptions: typeOptions))
        }
    }
}

/// The reader's calendar, which a rows request names as the web's does (`useViewerDateContext`): from Docmost 0.98 the
/// server resolves date filters in it ("today", "this week", a day in its time zone). Older servers drop the fields
/// unread, as their validation drops every field it doesn't know.
public struct ViewerDateContext: Sendable, Hashable {
    /// IANA name; the server falls back to UTC for one it doesn't know.
    public var timeZone: String
    /// Today in that time zone, `YYYY-MM-DD`.
    public var today: String
    /// First day of the week, 0 for Sunday; the server refuses a number outside 0–6.
    public var weekStart: Int

    /// The device's time zone and first day of the week, today as of `now`.
    public init(timeZone: TimeZone = .current, calendar: Calendar = .current, now: Date = .now) {
        self.timeZone = timeZone.identifier
        today = CalendarDay(containing: now, in: timeZone).value
        // `firstWeekday` counts from 1 for Sunday.
        weekStart = min(max(calendar.firstWeekday - 1, 0), 6)
    }
}

extension APIError {
    /// A rows request whose cursor refers to a row that changed or went since its page loaded (Docmost 0.98: a cursor
    /// too large for the sort values it would hold names their row instead). The web starts the list again from its
    /// first page; another try with the same cursor fails again.
    public var isStaleBaseCursor: Bool {
        guard case .validation(_, let code) = self else { return false }
        return code == "BASE_CURSOR_STALE"
    }
}
