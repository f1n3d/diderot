import Foundation

extension Endpoints {
    /// Page templates (the Enterprise license feature `templates`, Docmost 0.90). Creating and editing them stays on
    /// the web.
    public enum Templates {
        public struct ListBody: Encodable, Sendable {
            public var spaceId: String?
            public var limit: Int?
            public var cursor: String?
        }

        /// The templates a space offers; without `spaceId` every template the user can see.
        public static func list(spaceId: String? = nil, cursor: String? = nil, limit: Int = 50) -> Endpoint<Paginated<PageTemplate>> {
            .post("templates", body: ListBody(spaceId: spaceId, limit: limit, cursor: cursor))
        }

        public struct TemplateBody: Encodable, Sendable {
            public let templateId: String
        }

        /// A template with its content.
        public static func info(templateId: String) -> Endpoint<PageTemplate> {
            .post("templates/info", body: TemplateBody(templateId: templateId))
        }

        public struct UseBody: Encodable, Sendable {
            public let templateId: String
            public let spaceId: String
            public var parentPageId: String?
        }

        /// A new page from a template in a space, under `parentPageId` or at the top.
        public static func use(templateId: String, spaceId: String, parentPageId: String? = nil) -> Endpoint<Page> {
            .post("templates/use", body: UseBody(templateId: templateId, spaceId: spaceId, parentPageId: parentPageId))
        }
    }
}
