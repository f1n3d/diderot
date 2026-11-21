import Foundation

/// A person's profile (`users/info`, Docmost 0.98), as the web's profile page and a mention's card show it. A deleted
/// person has no email; deactivated and deleted people are there only for those who manage members (others get 404).
public struct UserProfile: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let avatarUrl: String?
    public let email: String?
    public let role: String?
    public let deactivatedAt: Date?
    public let deletedAt: Date?

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return email ?? ""
    }
}

/// A space on a profile (`users/spaces`, Docmost 0.98: the active spaces both people are members of, by name), and the
/// space of a recent page.
public struct UserProfileSpace: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let slug: String?
    public let logo: String?

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return slug ?? ""
    }
}

/// A page someone created or edited last (`users/recent-pages`, Docmost 0.98), newest first: only pages the user may
/// open, in the user's active spaces.
public struct UserRecentPage: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let slugId: String?
    public let title: String?
    public let icon: String?
    public let isBase: Bool?
    public let spaceId: String?
    public let space: UserProfileSpace?
    /// `edited` when they were the last to change the page, `created` when they made it and nobody changed it since or
    /// someone else did last; `activityAt` is when.
    public let activity: String?
    public let activityAt: Date?

    public var displayTitle: String { PageTitle.display(title) }
    /// As the web reads it (`RecentPageRow`): anything but `edited` counts as created.
    public var wasEdited: Bool { activity == "edited" }
}
