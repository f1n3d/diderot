import Foundation

public enum FavoriteType: String, Sendable, Hashable, Codable {
    case page, space, template
}

/// Entry from `POST /api/favorites`; `page` or `space` is set depending on `type`.
public struct Favorite: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String
    public let pageId: String?
    public let spaceId: String?
    public let page: PageRef?
    public let space: SpaceRef?

    public var favoriteType: FavoriteType? { FavoriteType(rawValue: type) }
}

/// `POST /api/favorites/ids` → IDs of the favorited pages or spaces (up to 250).
public struct FavoriteIds: Decodable, Sendable {
    public let items: [String]
}
