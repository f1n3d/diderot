import Foundation

extension Endpoints {
    public enum Search {
        public struct Body: Encodable, Sendable {
            public var query: String
            public var spaceId: String?
            public var titleOnly: Bool?
            public var limit: Int?
            public var offset: Int?
        }

        /// Docmost after 0.96 refuses longer queries (search and suggestions); this one and older ones search the start.
        static let maxQueryLength = 200

        /// Whole characters up to `maxQueryLength` code points: the server's `MaxLength` counts code points, not
        /// characters, and refused a long query in Hindi or with skin-tone emoji that fit 200 characters.
        static func clipped(_ query: String) -> String {
            var count = 0
            return String(query.prefix { character in
                count += character.unicodeScalars.count
                return count <= maxQueryLength
            })
        }

        /// Full-text search (prefix match), paged via `offset`.
        public static func search(query: String, spaceId: String? = nil, titleOnly: Bool? = nil, limit: Int = 25, offset: Int = 0) -> Endpoint<SearchResponse> {
            .post("search", body: Body(query: clipped(query), spaceId: spaceId, titleOnly: titleOnly, limit: limit, offset: offset))
        }

        public struct SuggestBody: Encodable, Sendable {
            public var query: String
            public var includeUsers: Bool?
            public var includePages: Bool?
            public var spaceId: String?
            public var limit: Int?
        }

        public static func suggest(query: String, users: Bool = true, pages: Bool = true, spaceId: String? = nil, limit: Int = 10) -> Endpoint<SearchSuggestions> {
            .post("search/suggest", body: SuggestBody(query: clipped(query), includeUsers: users, includePages: pages, spaceId: spaceId, limit: limit))
        }
    }

    public enum Favorites {
        public struct ListBody: Encodable, Sendable {
            public var type: String?
            public var spaceId: String?
            public var limit: Int?
            public var cursor: String?
        }

        public static func list(type: FavoriteType? = nil, spaceId: String? = nil, cursor: String? = nil, limit: Int = 100) -> Endpoint<Paginated<Favorite>> {
            .post("favorites", body: ListBody(type: type?.rawValue, spaceId: spaceId, limit: limit, cursor: cursor))
        }

        public struct IdsBody: Encodable, Sendable {
            public let type: String
            public var spaceId: String?
        }

        public static func ids(type: FavoriteType, spaceId: String? = nil) -> Endpoint<FavoriteIds> {
            .post("favorites/ids", body: IdsBody(type: type.rawValue, spaceId: spaceId))
        }

        public struct ToggleBody: Encodable, Sendable {
            public let type: String
            public var pageId: String?
            public var spaceId: String?
        }

        public static func addPage(_ pageId: String) -> Endpoint<NoContent> {
            .post("favorites/add", body: ToggleBody(type: FavoriteType.page.rawValue, pageId: pageId))
        }

        public static func removePage(_ pageId: String) -> Endpoint<NoContent> {
            .post("favorites/remove", body: ToggleBody(type: FavoriteType.page.rawValue, pageId: pageId))
        }

        public static func addSpace(_ spaceId: String) -> Endpoint<NoContent> {
            .post("favorites/add", body: ToggleBody(type: FavoriteType.space.rawValue, spaceId: spaceId))
        }

        public static func removeSpace(_ spaceId: String) -> Endpoint<NoContent> {
            .post("favorites/remove", body: ToggleBody(type: FavoriteType.space.rawValue, spaceId: spaceId))
        }
    }

    public enum Notifications {
        public enum Filter: String, Sendable {
            case direct, updates, all
        }

        public struct ListBody: Encodable, Sendable {
            public var type: String
            public var limit: Int?
            public var cursor: String?
        }

        public static func list(filter: Filter = .all, cursor: String? = nil, limit: Int = 30) -> Endpoint<Paginated<ActivityNotification>> {
            .post("notifications", body: ListBody(type: filter.rawValue, limit: limit, cursor: cursor))
        }

        public static var unreadCount: Endpoint<UnreadCount> { .post("notifications/unread-count") }

        public struct MarkReadBody: Encodable, Sendable {
            public let notificationIds: [String]
        }

        public static func markRead(_ ids: [String]) -> Endpoint<NoContent> {
            .post("notifications/mark-read", body: MarkReadBody(notificationIds: ids))
        }

        public static var markAllRead: Endpoint<NoContent> { .post("notifications/mark-all-read") }
    }
}
