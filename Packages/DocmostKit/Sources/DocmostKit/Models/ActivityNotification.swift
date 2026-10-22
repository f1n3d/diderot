import Foundation

/// Notification from `POST /api/notifications`. Types include `comment.user_mention`, `comment.created`,
/// `comment.resolved`, `page.user_mention`, `page.updated`, `page.permission_granted`.
public struct ActivityNotification: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String
    public let data: JSONValue?
    public var readAt: Date?
    public let createdAt: Date?
    public let actor: UserRef?
    public let page: PageRef?
    public let space: SpaceRef?

    public var isUnread: Bool { readAt == nil }
}

public struct UnreadCount: Decodable, Sendable, Hashable {
    public let count: Int
}
