import Foundation
import SwiftUI
import DocmostKit

/// Node identity in the view: UniqueID (paragraphs, headings) or path from the root.
struct NodeRef: Hashable, Sendable {
    let path: [Int]
    let id: String?
    /// Source node's type, so a path target misses another kind of block; not part of the identity.
    var type: String?

    init(path: [Int], node: PMNode) {
        self.path = path
        // A tab may have an empty id until Docmost gives it one: no identity.
        self.id = node.string("id").flatMap { $0.isEmpty ? nil : $0 }
        self.type = node.type
    }

    init(path: [Int], id: String?) {
        self.path = path
        self.id = id
    }

    static func == (lhs: NodeRef, rhs: NodeRef) -> Bool { lhs.path == rhs.path && lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(id)
    }

    var identity: String { id ?? "path:" + path.map(String.init).joined(separator: ".") }
    var target: BlockTarget { id.map { .id($0) } ?? .path(path, type: type) }
    /// Anchor ID as in the reader (`ContentParser`): UniqueID or path "0.3.1".
    var anchorId: String { id ?? path.map(String.init).joined(separator: ".") }
    var isTopLevel: Bool { path.count == 1 }
}

/// Node plus its identity for `ForEach`.
struct NodeEntry: Identifiable {
    let ref: NodeRef
    let node: PMNode
    var id: String { ref.identity }

    static func entries(_ nodes: [PMNode], parentPath: [Int]) -> [NodeEntry] {
        nodes.enumerated().map { NodeEntry(ref: NodeRef(path: parentPath + [$0.offset], node: $0.element), node: $0.element) }
    }
}

enum CursorRequest: Equatable {
    case start, end
    case offset(Int)
    /// A tap, relative to the block's text (top left of its first line): the text position there, once the editor
    /// shows the block. Not the window: the page moves the block meanwhile, to the middle of the space above the keyboard.
    case point(CGPoint)
}

/// Templates for new blocks.
enum BlockTemplate: String, CaseIterable, Identifiable {
    case paragraph, heading1, heading2, heading3, bulletList, orderedList, taskList, quote, callout, toggle, codeBlock, table, divider

    var id: String { rawValue }

    /// Localized title (key = English title) for the toolbar and the insert menu.
    var titleResource: LocalizedStringResource {
        switch self {
        case .paragraph: "Paragraph"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulletList: "Bullet list"
        case .orderedList: "Numbered list"
        case .taskList: "Task list"
        case .quote: "Quote"
        case .callout: "Callout"
        case .toggle: "Toggle"
        case .codeBlock: "Code block"
        case .table: "Table"
        case .divider: "Divider"
        }
    }

    var symbol: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1: "1.square"
        case .heading2: "2.square"
        case .heading3: "3.square"
        case .bulletList: "list.bullet"
        case .orderedList: "list.number"
        case .taskList: "checklist"
        case .quote: "text.quote"
        case .callout: "info.bubble"
        case .toggle: "chevron.right.square"
        case .codeBlock: "chevron.left.forwardslash.chevron.right"
        case .table: "tablecells"
        case .divider: "minus"
        }
    }

    /// A new, empty block of this kind.
    func node() -> PMNode {
        let paragraph = PMNode(type: "paragraph")
        switch self {
        case .paragraph: return paragraph
        case .heading1, .heading2, .heading3:
            return PMNode(type: "heading", attrs: ["level": .number(Double(self == .heading1 ? 1 : self == .heading2 ? 2 : 3))])
        case .bulletList: return PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [paragraph])])
        case .orderedList: return PMNode(type: "orderedList", attrs: ["start": 1], content: [PMNode(type: "listItem", content: [paragraph])])
        case .taskList: return PMNode(type: "taskList", content: [PMNode(type: "taskItem", attrs: ["checked": false], content: [paragraph])])
        case .quote: return PMNode(type: "blockquote", content: [paragraph])
        case .callout: return PMNode(type: "callout", attrs: ["type": "info"], content: [paragraph])
        case .toggle:
            return PMNode(type: "details", attrs: ["open": true], content: [
                PMNode(type: "detailsSummary"),
                PMNode(type: "detailsContent", content: [PMNode(type: "paragraph")]),
            ])
        case .codeBlock: return PMNode(type: "codeBlock", attrs: ["language": .null])
        case .table:
            func cell(_ type: String) -> PMNode { PMNode(type: type, attrs: ["colspan": 1, "rowspan": 1], content: [PMNode(type: "paragraph")]) }
            let header = PMNode(type: "tableRow", content: [cell("tableHeader"), cell("tableHeader"), cell("tableHeader")])
            let rows = (0..<2).map { _ in PMNode(type: "tableRow", content: [cell("tableCell"), cell("tableCell"), cell("tableCell")]) }
            return PMNode(type: "table", content: [header] + rows)
        case .divider: return PMNode(type: "horizontalRule")
        }
    }

    /// Path (relative to the new node) of the first editable text.
    var firstTextPath: [Int]? {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3, .codeBlock: []
        case .bulletList, .orderedList, .taskList: [0, 0]
        case .quote, .callout, .toggle: [0]
        case .table: [0, 0, 0]
        case .divider: nil
        }
    }
}

/// Mention suggestion: a person or a page.
struct MentionSuggestion: Identifiable, Hashable {
    enum Kind: Hashable { case user, page }

    let kind: Kind
    let entityId: String
    let title: String
    let subtitle: String?
    let icon: String?
    let avatarUrl: String?
    let slugId: String?

    var id: String { (kind == .user ? "user-" : "page-") + entityId }

    static func from(_ suggestions: SearchSuggestions) -> [MentionSuggestion] {
        let users = (suggestions.users ?? []).map {
            MentionSuggestion(kind: .user, entityId: $0.id, title: $0.name?.isEmpty == false ? $0.name! : ($0.email ?? ""), subtitle: $0.email, icon: nil, avatarUrl: $0.avatarUrl, slugId: nil)
        }
        let pages = (suggestions.pages ?? []).map {
            MentionSuggestion(kind: .page, entityId: $0.id, title: PageTitle.display($0.title), subtitle: $0.space?.name, icon: $0.icon, avatarUrl: nil, slugId: $0.slugId)
        }
        return pages + users
    }
}

/// Media picker the model asks the UI for.
enum PendingMediaAction: Equatable {
    /// Photo library.
    case images, videos
    case camera
    /// Files app.
    case audio, pdf
    /// Any file, always as an attachment card (like "File attachment" on the web).
    case attachment
}

/// Media pick request; its own ID makes a repeat of the same kind (e.g. after a cancel) reopen the picker.
struct MediaRequest: Equatable {
    let id = UUID()
    let action: PendingMediaAction
}

/// Where the files of a closed media picker go.
struct MediaTarget {
    let placement: BlockPlacement
    let asAttachment: Bool
}

/// Where a new block goes.
enum BlockPlacement: Equatable {
    /// In place of the block if it is an empty paragraph, else after it (same container).
    case replaceOrAfter(NodeRef)
    /// After the top-level block containing `NodeRef`, or in its place if that is an empty paragraph.
    case afterTopLevel(NodeRef)
    /// End of the document, before the footnotes.
    case end
}

/// Where the cursor lands after inserting a block.
enum InsertFocus: Equatable {
    /// End of the new block's first text (path relative to the block).
    case inside([Int])
    /// Start of the next block (as the web does after a divider): a paragraph is added if no block follows; editing
    /// ends if the next block isn't text.
    case after
}

/// Editor input sheet (status, math, embed) for inserting or editing.
enum EditorSheet: Identifiable, Equatable {
    /// Inline atom target: insert at the active block's cursor, or edit the block's `index`-th atom of this type.
    enum AtomTarget: Equatable {
        case insert(offset: Int)
        case edit(ref: NodeRef, index: Int)
    }

    /// Block target: insert a new one or change an existing one.
    enum BlockSlot: Equatable {
        case insert(BlockPlacement)
        case edit(NodeRef)
    }

    case status(AtomTarget, text: String, color: String)
    case mathInline(AtomTarget, latex: String)
    case mathBlock(BlockSlot, latex: String)
    case embed(BlockSlot, provider: EmbedProvider, link: String)

    var id: String {
        switch self {
        case .status: "status"
        case .mathInline: "math-inline"
        case .mathBlock: "math-block"
        case .embed: "embed"
        }
    }
}

/// How the page's one text editor draws the active block's text: as the block would (font, leading, alignment).
struct EditorStyle: Equatable {
    var font: Font
    var leading: CGFloat
    var alignment: TextAlignment
    /// A code block: no autocorrection or capitalization.
    var isCode = false
}
