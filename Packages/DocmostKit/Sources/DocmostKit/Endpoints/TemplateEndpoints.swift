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
            /// The template's revision the values are for (Docmost 0.98; older servers ignore it).
            public var templateUpdatedAt: String?
            /// Values of the template's fields by variable id (Docmost 0.98).
            public var variableValues: [String: String]?
        }

        /// A new page from a template in a space, under `parentPageId` or at the top. Docmost 0.98 refuses a template
        /// with fields without their values and the template's `revision` (400), or with an older revision (409).
        public static func use(template: PageTemplate, spaceId: String, parentPageId: String? = nil,
                               variableValues: [String: String]? = nil) -> Endpoint<Page> {
            .post("templates/use", body: UseBody(templateId: template.id, spaceId: spaceId, parentPageId: parentPageId,
                                                 templateUpdatedAt: template.revision, variableValues: variableValues))
        }

        public struct ApplyBody: Encodable, Sendable {
            public let templateId: String
            public let pageId: String
            public var templateUpdatedAt: String?
            public var variableValues: [String: String]?
        }

        /// The template's content for an empty page, its fields filled in and its files copied to the page (Docmost
        /// 0.98; the page takes the returned content as the web's "Get started with" does).
        public static func apply(template: PageTemplate, pageId: String, variableValues: [String: String]? = nil) -> Endpoint<PageTemplate> {
            .post("templates/apply", body: ApplyBody(templateId: template.id, pageId: pageId,
                                                     templateUpdatedAt: template.revision, variableValues: variableValues))
        }
    }
}
