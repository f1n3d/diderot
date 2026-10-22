import Foundation

/// Entry from `workspace/members`.
public struct WorkspaceMember: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let email: String?
    public let avatarUrl: String?
    public let role: String?

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return email ?? ""
    }
}
