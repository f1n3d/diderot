import Foundation

extension Endpoints {
    public enum Comments {
        public struct ListBody: Encodable, Sendable {
            public let pageId: String
            public var limit: Int?
            public var cursor: String?
        }

        /// A page's comments, oldest first; replies link to their parent via `parentCommentId`.
        public static func list(pageId: String, cursor: String? = nil, limit: Int = 100) -> Endpoint<Paginated<PageComment>> {
            .post("comments", body: ListBody(pageId: pageId, limit: limit, cursor: cursor))
        }
    }

    public enum History {
        public struct ListBody: Encodable, Sendable {
            public let pageId: String
            public var limit: Int?
            public var cursor: String?
        }

        public static func list(pageId: String, cursor: String? = nil, limit: Int = 50) -> Endpoint<Paginated<PageHistoryEntry>> {
            .post("pages/history", body: ListBody(pageId: pageId, limit: limit, cursor: cursor))
        }

        public struct InfoBody: Encodable, Sendable {
            public let historyId: String
        }

        public static func info(historyId: String) -> Endpoint<PageHistoryEntry> {
            .post("pages/history/info", body: InfoBody(historyId: historyId))
        }
    }

    public enum Transclusions {
        public struct Reference: Encodable, Sendable, Hashable {
            public let sourcePageId: String
            public let transclusionId: String

            public init(sourcePageId: String, transclusionId: String) {
                self.sourcePageId = sourcePageId
                self.transclusionId = transclusionId
            }
        }

        public struct LookupBody: Encodable, Sendable {
            public let references: [Reference]
        }

        /// At most 50 references per call.
        public static func lookup(_ references: [Reference]) -> Endpoint<TransclusionLookup> {
            .post("pages/transclusion/lookup", body: LookupBody(references: Array(references.prefix(50))))
        }

        /// Pages that use a synced block (source and references, visible ones only).
        public static func references(sourcePageId: String, transclusionId: String) -> Endpoint<TransclusionReferences> {
            .post("pages/transclusion/references", body: Reference(sourcePageId: sourcePageId, transclusionId: transclusionId))
        }

        public struct UnsyncBody: Encodable, Sendable {
            public let referencePageId: String
            public let sourcePageId: String
            public let transclusionId: String
        }

        /// Unsyncs a reference: the server copies the attachments and returns the content
        /// (`{type: "doc", content: […]}`) that replaces the reference in the page.
        public static func unsyncReference(referencePageId: String, sourcePageId: String, transclusionId: String) -> Endpoint<TransclusionUnsync> {
            .post("pages/transclusion/unsync-reference", body: UnsyncBody(
                referencePageId: referencePageId, sourcePageId: sourcePageId, transclusionId: transclusionId
            ))
        }
    }
}
