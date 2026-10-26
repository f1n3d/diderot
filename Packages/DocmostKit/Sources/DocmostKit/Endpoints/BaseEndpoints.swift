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
        }

        /// Rows in position order, max 100 per call. The endpoint knows no views: pass a view's `filter` and `sorts`.
        public static func rows(
            pageId: String, filter: JSONValue? = nil, sorts: JSONValue? = nil, cursor: String? = nil, limit: Int = 100
        ) -> Endpoint<BaseRowsPage> {
            .post("bases/rows", body: RowsBody(pageId: pageId, filter: filter, sorts: sorts, limit: limit, cursor: cursor))
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
            public var afterRowId: String?
        }

        /// New row. Without `position`/`afterRowId` the server appends it; the response is the complete row.
        public static func createRow(
            pageId: String, cells: [String: JSONValue] = [:], position: String? = nil, afterRowId: String? = nil
        ) -> Endpoint<BaseRow> {
            .post("bases/rows/create", body: CreateRowBody(pageId: pageId, cells: cells, position: position, afterRowId: afterRowId))
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
