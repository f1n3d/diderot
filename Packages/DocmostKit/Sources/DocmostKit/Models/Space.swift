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

    public var role: SpaceRole? { membership?.spaceRole }
}

/// Abbreviated space as embedded in pages.
public struct SpaceRef: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let slug: String?
}
