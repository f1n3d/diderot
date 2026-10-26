import Foundation

/// Write calls. The server applies content via Yjs, so appending is safe during concurrent web edits.
extension Endpoints.Pages {
    public struct CreateBody: Encodable, Sendable {
        public let spaceId: String
        public var parentPageId: String?
        public var title: String?
        public var icon: String?
        public var content: String?
        public var format: String?
    }

    /// New page; the server converts Markdown into content and the Y.Doc.
    public static func create(spaceId: String, parentPageId: String? = nil, title: String?, icon: String? = nil, markdown: String? = nil) -> Endpoint<Page> {
        .post("pages/create", body: CreateBody(
            spaceId: spaceId, parentPageId: parentPageId, title: title, icon: icon,
            content: markdown, format: markdown == nil ? nil : "markdown"
        ))
    }

    public struct UpdateBody: Encodable, Sendable {
        public let pageId: String
        public var title: String?
        public var icon: String?
        public var content: String?
        public var operation: String?
        public var format: String?
    }

    /// Changes title and/or icon (not part of the Y.Doc).
    public static func update(pageId: String, title: String? = nil, icon: String? = nil) -> Endpoint<Page> {
        .post("pages/update", body: UpdateBody(pageId: pageId, title: title, icon: icon))
    }

    /// Appends Markdown; needs Redis sync on the server (`COLLAB_DISABLE_REDIS` unset), else content stays unchanged.
    public static func appendMarkdown(pageId: String, _ markdown: String) -> Endpoint<Page> {
        .post("pages/update", body: UpdateBody(pageId: pageId, content: markdown, operation: "append", format: "markdown"))
    }

    public struct DeleteBody: Encodable, Sendable {
        public let pageId: String
        public var permanentlyDelete: Bool?
    }

    /// Moves to trash (with subpages); `permanently` is for space admins only.
    public static func delete(pageId: String, permanently: Bool = false) -> Endpoint<NoContent> {
        .post("pages/delete", body: DeleteBody(pageId: pageId, permanentlyDelete: permanently ? true : nil))
    }

    public static func restore(pageId: String) -> Endpoint<Page> {
        .post("pages/restore", body: PageIdBody(pageId: pageId))
    }
}

extension Endpoints.Comments {
    public struct CreateBody: Encodable, Sendable {
        public let pageId: String
        /// ProseMirror JSON as a string; the server deliberately expects a string here.
        public let content: String
        public var type: String?
        /// Selected text for inline comments.
        public var selection: String?
        public var parentCommentId: String?
    }

    /// Page comment or reply (only one reply level).
    public static func create(pageId: String, text: String, parentCommentId: String? = nil) throws -> Endpoint<PageComment> {
        .post("comments/create", body: CreateBody(
            pageId: pageId, content: try CommentContent.json(for: text), type: "page", parentCommentId: parentCommentId
        ))
    }

    /// Inline comment; as on the web, the editor then applies the `comment` mark with the returned ID to the selection.
    public static func createInline(pageId: String, text: String, selection: String) throws -> Endpoint<PageComment> {
        .post("comments/create", body: CreateBody(
            pageId: pageId, content: try CommentContent.json(for: text), type: "inline", selection: selection
        ))
    }

    public struct ResolveBody: Encodable, Sendable {
        public let commentId: String
        public let pageId: String
        public let resolved: Bool
    }

    /// Resolves or reopens a comment (license feature `comment:resolution`); the server updates its `comment` mark.
    public static func resolve(commentId: String, pageId: String, resolved: Bool) -> Endpoint<PageComment> {
        .post("comments/resolve", body: ResolveBody(commentId: commentId, pageId: pageId, resolved: resolved))
    }

    public struct UpdateBody: Encodable, Sendable {
        public let commentId: String
        public let content: String
    }

    public static func update(commentId: String, text: String) throws -> Endpoint<PageComment> {
        .post("comments/update", body: UpdateBody(commentId: commentId, content: try CommentContent.json(for: text)))
    }

    public struct CommentIdBody: Encodable, Sendable {
        public let commentId: String
    }

    public static func delete(commentId: String) -> Endpoint<NoContent> {
        .post("comments/delete", body: CommentIdBody(commentId: commentId))
    }
}

extension Endpoints.Attachments {
    public struct AttachmentIdBody: Encodable, Sendable {
        public let attachmentId: String
    }

    /// Deletes a page's uploaded file; the server allows it to space admins who can edit the page (403 otherwise).
    public static func delete(attachmentId: String) -> Endpoint<NoContent> {
        .post("attachments/delete", body: AttachmentIdBody(attachmentId: attachmentId))
    }
}

/// Builds a comment's ProseMirror document from plain text (one paragraph per line).
public enum CommentContent {
    public static func document(for text: String) -> JSONValue {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> JSONValue in
            let trimmed = String(line)
            if trimmed.isEmpty {
                return ["type": "paragraph"]
            }
            return ["type": "paragraph", "content": [["type": "text", "text": .string(trimmed)]]]
        }
        return ["type": "doc", "content": .array(paragraphs)]
    }

    public static func json(for text: String) throws -> String {
        let data = try JSONEncoder().encode(document(for: text))
        return String(decoding: data, as: UTF8.self)
    }

    /// A comment's plain text for editing: one line per paragraph, mentions as "@Name".
    public static func plainText(of content: JSONValue?) -> String {
        lines(of: content ?? .null).joined(separator: "\n")
    }

    private static func lines(of node: JSONValue) -> [String] {
        switch node["type"]?.stringValue {
        case "paragraph", "heading", "codeBlock":
            return [inlineText(of: node)]
        default:
            return (node["content"]?.arrayValue ?? []).flatMap(lines(of:))
        }
    }

    private static func inlineText(of node: JSONValue) -> String {
        if let text = node["text"]?.stringValue { return text }
        switch node["type"]?.stringValue {
        case "mention": return "@" + (node["attrs"]?["label"]?.stringValue ?? "")
        case "hardBreak": return "\n"
        default: return (node["content"]?.arrayValue ?? []).map(inlineText(of:)).joined()
        }
    }
}
