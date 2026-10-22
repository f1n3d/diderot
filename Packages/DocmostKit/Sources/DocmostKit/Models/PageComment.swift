import Foundation

/// Page comment. `content` is ProseMirror JSON (StarterKit, links, mentions).
public struct PageComment: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let content: JSONValue?
    /// Selected text of inline comments (max. 250 characters).
    public let selection: String?
    public let type: String?
    public let parentCommentId: String?
    public let creatorId: String?
    public let resolvedAt: Date?
    public let editedAt: Date?
    public let createdAt: Date?
    public let creator: UserRef?

    public var isInline: Bool { type == "inline" }
    public var isResolved: Bool { resolvedAt != nil }
    public var isReply: Bool { parentCommentId != nil }
}

/// Version entry from `pages/history`.
public struct PageHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let icon: String?
    public let createdAt: Date?
    public let lastUpdatedBy: UserRef?
    /// Only set by `pages/history/info`.
    public let content: JSONValue?

    public var displayTitle: String { PageTitle.display(title) }
}

/// Response of `pages/transclusion/references`.
public struct TransclusionReferences: Decodable, Sendable, Hashable {
    /// Page holding the source; `nil` if the user can't see it.
    public let source: PageRef?
    public let references: [PageRef]
}

/// Response of `pages/transclusion/unsync-reference`.
public struct TransclusionUnsync: Decodable, Sendable {
    public let content: JSONValue?

    /// Blocks that replace the reference.
    public var nodes: [PMNode] {
        PMNode(json: content ?? .null)?.children ?? []
    }
}

/// Response of `pages/transclusion/lookup`: content or a status per reference.
public struct TransclusionLookup: Decodable, Sendable {
    public struct Item: Decodable, Sendable, Hashable {
        public let content: JSONValue?
        /// `not_found` or `no_access` when no content is returned.
        public let status: String?
    }

    public let items: [Item]
}
