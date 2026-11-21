import Foundation

/// Database ("base", a licensed Docmost feature): a page with `isBase` that has properties (columns), rows and views
/// (table, kanban). Pages embed it via the `base` node (attribute `pageId`).
public struct Base: Codable, Sendable, Hashable, Identifiable {
    public struct Permissions: Codable, Sendable, Hashable {
        public let canEdit: Bool?
    }

    public let id: String
    public let slugId: String?
    public let title: String?
    public let icon: String?
    public let spaceId: String?
    /// Mutable to apply a changed property (e.g. a new select option) at once.
    public var properties: [BaseProperty]
    public let views: [BaseView]
    public let permissions: Permissions?

    public var displayTitle: String { PageTitle.display(title) }
    public var canEdit: Bool { permissions?.canEdit ?? false }
    /// The views to show, in Docmost's order. Form views (Docmost 0.98) stay hidden, as the web hides them while forms
    /// are in beta (unless the server sets `BETA_BASE_FORMS`, which it tells only its own web client).
    public var shownViews: [BaseView] {
        views.filter { $0.type != "form" }.sorted { ($0.position ?? "") < ($1.position ?? "") }
    }
    /// The title property of every row (always text).
    public var primaryProperty: BaseProperty? { properties.first { $0.isPrimary == true } }

    public func property(id: String) -> BaseProperty? {
        properties.first { $0.id == id }
    }

    /// Replaces a property (same ID) with its new version, e.g. after `bases/properties/update`.
    public mutating func replace(_ property: BaseProperty) {
        guard let index = properties.firstIndex(where: { $0.id == property.id }) else { return }
        properties[index] = property
    }
}

/// Database property. `typeOptions` depends on the type (select options, number format, date format …).
public struct BaseProperty: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case text, longText, number, select, status, multiSelect, date, person, page, file, checkbox, url, email
        case createdAt, lastEditedAt, lastEditedBy, formula
        /// The row's creator (Docmost 0.98), from the row's `creatorId` as "Last edited by" from its editor.
        case createdBy
    }

    public let id: String
    public let name: String
    public let type: String
    public let position: String?
    public let isPrimary: Bool?
    public var typeOptions: JSONValue?
    /// The type and options a background job is converting the property to (Docmost 0.98); `type` stays the old one
    /// until the job is done.
    public let pendingType: String?
    public let pendingTypeOptions: JSONValue?

    /// `nil` for types this app version doesn't know yet; the UI shows them as "Only in the web app".
    public var kind: Kind? { Kind(rawValue: type) }

    /// While the server converts the property's cells (the web's `isPropertyConverting`).
    public var isConverting: Bool { pendingType != nil || pendingTypeOptions != nil }
}

/// Saved database view. `config`: filters, sorting, visible properties, for kanban boards the grouping property and for
/// calendars the date property (`calendar.datePropertyId`).
public struct BaseView: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case table, kanban
        /// Entries by their date, a month at a time (Docmost 0.98).
        case calendar
    }

    public let id: String
    public let name: String
    public let type: String
    public let position: String?
    public let config: JSONValue?

    /// Unknown types render as a table.
    public var kind: Kind { Kind(rawValue: type) ?? .table }
}

/// Database row: cells by property ID; system properties (created, last edited) come from row fields, not `cells`.
public struct BaseRow: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// Mutable to show an edit immediately until the server response replaces it.
    public var cells: [String: JSONValue]
    /// Sort key (`fractional-indexing`), shared by all views.
    public var position: String?
    public let creatorId: String?
    public let lastUpdatedById: String?
    public let createdAt: Date?
    public let updatedAt: Date?
}

/// Response of `bases/properties/update`.
public struct UpdatePropertyResult: Decodable, Sendable {
    public let property: BaseProperty
}

/// Response of `bases/rows`: one page of rows plus the names of the people and pages they reference.
public struct BaseRowsPage: Decodable, Sendable {
    public let items: [BaseRow]
    public let meta: PaginationMeta
    public let references: BaseReferences?
}

/// Response of `bases/rows/calendar` (Docmost 0.98): a calendar window's rows by their date, the names they reference,
/// and how many there are, as the limit may cut them short.
public struct BaseCalendarRows: Decodable, Sendable {
    public struct Meta: Decodable, Sendable, Hashable {
        /// Rows in the window; more than the answer holds when `truncated`.
        public let total: Int
        public let truncated: Bool
        /// The time zone the server read the window and the dates in: the request's, UTC for one it doesn't know.
        public let timeZone: String?
    }

    public let items: [BaseRow]
    public let references: BaseReferences?
    public let meta: Meta
}

public struct BaseReferences: Codable, Sendable, Hashable {
    public let users: [String: UserRef]?
    public let pages: [String: PageRef]?
}
