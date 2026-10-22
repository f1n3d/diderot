import Foundation

public enum WorkspaceRole: String, Sendable, Hashable, Codable {
    case owner, admin, member
}

public struct User: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let email: String
    public let name: String?
    public let avatarUrl: String?
    public let role: String?

    public var workspaceRole: WorkspaceRole {
        role.flatMap(WorkspaceRole.init(rawValue:)) ?? .member
    }

    public var displayName: String {
        name?.isEmpty == false ? name! : email
    }
}

/// Abbreviated user as embedded in `creator`, `lastUpdatedBy`, `actor`, etc.
public struct UserRef: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let avatarUrl: String?

    public init(id: String, name: String?, avatarUrl: String?) {
        self.id = id
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

/// Response of `POST /api/users/me`.
public struct CurrentUser: Codable, Sendable, Hashable {
    public let user: User
    public let workspace: Workspace
}
