import Foundation

extension Endpoints {
    public enum Spaces {
        /// Which of the user's spaces a list holds. Docmost 0.98 archives spaces and lists only active ones unless
        /// asked otherwise; older servers ignore it and list all.
        public enum Status: String, Encodable, Sendable {
            case active, archived, all
        }

        public struct ListBody: Encodable, Sendable {
            public var limit: Int?
            public var cursor: String?
            public var status: Status
        }

        /// Spaces the user is a member of, sorted by name; archived ones too unless `status` says otherwise.
        public static func list(_ pagination: PaginationOptions = PaginationOptions(), status: Status = .all) -> Endpoint<Paginated<Space>> {
            .post("spaces", body: ListBody(limit: pagination.limit, cursor: pagination.cursor, status: status))
        }

        public struct SpaceIdBody: Encodable, Sendable {
            public let spaceId: String
        }

        /// `spaceId` may be a UUID or a slug.
        public static func info(spaceId: String) -> Endpoint<Space> {
            .post("spaces/info", body: SpaceIdBody(spaceId: spaceId))
        }

        /// Restores an archived space (Docmost 0.98), for its admins; the answer is the space without its archive.
        public static func unarchive(spaceId: String) -> Endpoint<Space> {
            .post("spaces/unarchive", body: SpaceIdBody(spaceId: spaceId))
        }
    }

    public enum Pages {
        /// Root pages of a space or children of a page; `limit` is at most 100.
        public struct SidebarBody: Encodable, Sendable {
            public var spaceId: String?
            public var pageId: String?
            public var limit: Int?
            public var cursor: String?
        }

        public static func sidebar(spaceId: String, cursor: String? = nil, limit: Int = 100) -> Endpoint<Paginated<SidebarPage>> {
            .post("pages/sidebar-pages", body: SidebarBody(spaceId: spaceId, limit: limit, cursor: cursor))
        }

        public static func children(of pageId: String, cursor: String? = nil, limit: Int = 100) -> Endpoint<Paginated<SidebarPage>> {
            .post("pages/sidebar-pages", body: SidebarBody(pageId: pageId, limit: limit, cursor: cursor))
        }

        public struct PageIdBody: Encodable, Sendable {
            public let pageId: String
        }

        /// Root first, the page itself last. The envelope holds a plain array, not `Paginated`.
        public static func breadcrumbs(pageId: String) -> Endpoint<[Breadcrumb]> {
            .post("pages/breadcrumbs", body: PageIdBody(pageId: pageId))
        }

        public struct RecentBody: Encodable, Sendable {
            public var spaceId: String?
            public var limit: Int?
            public var cursor: String?
        }

        /// Recently changed pages, workspace-wide or per space.
        public static func recent(spaceId: String? = nil, cursor: String? = nil, limit: Int = 20) -> Endpoint<Paginated<Page>> {
            .post("pages/recent", body: RecentBody(spaceId: spaceId, limit: limit, cursor: cursor))
        }

        public struct InfoBody: Encodable, Sendable {
            public let pageId: String
            public var format: String?
        }

        /// `pageId` may be a UUID or slugId. Without `format`, `content` comes back as JSON.
        public static func info(pageId: String, format: String? = nil) -> Endpoint<Page> {
            .post("pages/info", body: InfoBody(pageId: pageId, format: format))
        }
    }
}
