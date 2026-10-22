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
    }

    public let id: String
    public let name: String
    public let type: String
    public let position: String?
    public let isPrimary: Bool?
    public var typeOptions: JSONValue?

    /// `nil` for types this app version doesn't know yet; the UI shows them as "Only in the web app".
    public var kind: Kind? { Kind(rawValue: type) }
}

/// Saved database view. `config`: filters, sorting, visible properties and, for kanban boards, the grouping property.
public struct BaseView: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case table, kanban
    }

    public let id: String
    public let name: String
    public let type: String
    public let position: String?
    public let config: JSONValue?

    /// Unknown types and `calendar` (no UI in the web client, checked up to 0.96) render as a table (web parity).
    public var kind: Kind { Kind(rawValue: type) == .kanban ? .kanban : .table }
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

public struct BaseReferences: Codable, Sendable, Hashable {
    public let users: [String: UserRef]?
    public let pages: [String: PageRef]?
}
