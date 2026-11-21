import Foundation

public enum SpaceRole: String, Sendable, Hashable, Codable {
    case admin, writer, reader
}

/// The current user's role in the space; `permissions` only comes from `spaces/info`.
public struct SpaceMembership: Codable, Sendable, Hashable {
    public struct Rule: Codable, Sendable, Hashable {
        public let action: String
        public let subject: String
    }

    public let role: String?
    public let permissions: [Rule]?

    public var spaceRole: SpaceRole? {
        role.flatMap(SpaceRole.init(rawValue:))
    }

    /// `manage` includes every action.
    public func can(_ action: String, _ subject: String) -> Bool {
        guard let permissions else {
            return spaceRole == .admin || (action == "read") || (subject == "page" && spaceRole == .writer)
        }
        return permissions.contains { $0.subject == subject && ($0.action == action || $0.action == "manage") }
    }

    public var canEditPages: Bool { can("edit", "page") }
}

public struct Space: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let slug: String
    public let description: String?
    public let logo: String?
    public let settings: JSONValue?
    public let memberCount: Int?
    public let membership: SpaceMembership?
    /// When it was archived (Docmost 0.98); nil while active and on older servers. An archived space stays editable.
    public let archivedAt: Date?
    /// Who archived it; `spaces/info` only.
    public let archivedBy: UserRef?
    /// The page the web opens the space on (Docmost 0.98); `spaces/info` only, and nil where none is set or the page is
    /// gone or out of the person's reach.
    public let homePage: SpaceHomePage?

    public var role: SpaceRole? { membership?.spaceRole }
    public var isArchived: Bool { archivedAt != nil }
}

/// A space's home page as `spaces/info` names it.
public struct SpaceHomePage: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let slugId: String?
    public let title: String?
    public let icon: String?
}

/// Abbreviated space as embedded in pages.
public struct SpaceRef: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let slug: String?
    /// When it was archived (Docmost 0.98), as favorites name it.
    public let archivedAt: Date?

    public var isArchived: Bool { archivedAt != nil }
}
