import Foundation

/// Page tree entry (`pages/sidebar-pages`).
public struct SidebarPage: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let slugId: String?
    public let title: String?
    public let icon: String?
    public let position: String?
    public let parentPageId: String?
    public let spaceId: String?
    public let isBase: Bool?
    public let hasChildren: Bool?
    public let canEdit: Bool?
    /// Since Docmost 0.97 (sub-pages sorted by "Recent").
    public let updatedAt: Date?

    public init(
        id: String, slugId: String? = nil, title: String?, icon: String? = nil, position: String? = nil,
        parentPageId: String? = nil, spaceId: String? = nil, isBase: Bool? = nil, hasChildren: Bool? = nil,
        canEdit: Bool? = nil, updatedAt: Date? = nil
    ) {
        self.id = id
        self.slugId = slugId
        self.title = title
        self.icon = icon
        self.position = position
        self.parentPageId = parentPageId
        self.spaceId = spaceId
        self.isBase = isBase
        self.hasChildren = hasChildren
        self.canEdit = canEdit
        self.updatedAt = updatedAt
    }

    public var displayTitle: String { PageTitle.display(title) }
    public var mayHaveChildren: Bool { hasChildren ?? false }
}

/// Abbreviated page as embedded in favorites, notifications, database references and synced-block usages.
public struct PageRef: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let slugId: String?
    public let title: String?
    public let icon: String?
    public let spaceId: String?
    public let isBase: Bool?

    public init(
        id: String, slugId: String? = nil, title: String? = nil, icon: String? = nil, spaceId: String? = nil,
        isBase: Bool? = nil
    ) {
        self.id = id
        self.slugId = slugId
        self.title = title
        self.icon = icon
        self.spaceId = spaceId
        self.isBase = isBase
    }

    public var displayTitle: String { PageTitle.display(title) }
}

/// Breadcrumb item (`pages/breadcrumbs`), root first.
public struct Breadcrumb: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let icon: String?

    public var displayTitle: String { PageTitle.display(title) }
}

/// Page from endpoints such as `pages/recent` or `pages/info` (the latter includes `content`).
public struct Page: Codable, Sendable, Hashable, Identifiable {
    public struct Permissions: Codable, Sendable, Hashable {
        public let canEdit: Bool?
    }

    public let id: String
    public let slugId: String?
    public let title: String?
    public let icon: String?
    public let spaceId: String?
    public let isBase: Bool?
    /// TipTap/ProseMirror JSON; a string when requested with `format: markdown|html`.
    public let content: JSONValue?
    public let space: SpaceRef?
    public let creator: UserRef?
    public let lastUpdatedBy: UserRef?
    public let deletedBy: UserRef?
    public let permissions: Permissions?
    public let updatedAt: Date?
    public let deletedAt: Date?

    public var displayTitle: String { PageTitle.display(title) }
    public var isInTrash: Bool { deletedAt != nil }
    public var canEdit: Bool { permissions?.canEdit ?? false }
}

public enum PageTitle {
    /// The kit has no String Catalog: its texts resolve through the app's (`swift test` gets the English key).
    public static var untitled: String { String(localized: "Untitled", bundle: .main) }

    public static func display(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? untitled : trimmed
    }
}
