import Foundation

/// Typed page document for rendering. Unknown nodes are kept as `.unknown`.
public struct ContentDocument: Sendable, Hashable {
    public let blocks: [Block]
    public let footnotes: [Footnote]
    /// Anchor (heading `id`, synced-block `id`, footnote `id` and `data-id`) → block or footnote ID.
    public let anchors: [String: String]

    public static let empty = ContentDocument(blocks: [], footnotes: [], anchors: [:])

    public var isEmpty: Bool { blocks.isEmpty }
}

extension ContentDocument {
    /// Parses `Page.content`; `nil` or a string (Markdown/HTML format) yields an empty document.
    /// A comment as the web's comment editor makes and shows it (text, lists, quotes, code, links, mentions). Other
    /// blocks (media, math, diagrams, embeds, synced blocks, databases), which only crafted comments carry, show as
    /// unsupported and load nothing: they told other hosts who read the comments, or loaded huge files.
    public init(commentJSON json: JSONValue?) {
        self.init(blocks: ContentDocument(json: json).blocks.map(Self.commentBlock), footnotes: [], anchors: [:])
    }

    private static func commentBlock(_ block: Block) -> Block {
        func items(_ items: [ListItem]) -> [ListItem] {
            items.map { ListItem(id: $0.id, number: $0.number, blocks: $0.blocks.map(commentBlock)) }
        }
        switch block.kind {
        case .paragraph, .heading, .horizontalRule:
            return block
        // The web shows a Mermaid source in a comment as plain code.
        case .codeBlock(let language, let code):
            return language == "mermaid" ? Block(id: block.id, kind: .codeBlock(language: nil, code: code)) : block
        case .blockquote(let blocks): return Block(id: block.id, kind: .blockquote(blocks.map(commentBlock)))
        case .bulletList(let list): return Block(id: block.id, kind: .bulletList(items(list)))
        case .orderedList(let list): return Block(id: block.id, kind: .orderedList(items(list)))
        case .image: return Block(id: block.id, kind: .unknown(type: "image", []))
        case .media(let media): return Block(id: block.id, kind: .unknown(type: media.kind.rawValue, []))
        case .unknown(let type, _): return Block(id: block.id, kind: .unknown(type: type, []))
        default: return Block(id: block.id, kind: .unknown(type: "block", []))
        }
    }

    public init(json: JSONValue?) {
        guard let json, let node = PMNode(json: json) else {
            self = .empty
            return
        }
        self = ContentParser.parse(node)
    }
}

public struct Block: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: Kind

    public indirect enum Kind: Sendable, Hashable {
        case paragraph(TextBlock)
        case heading(level: Int, TextBlock)
        case blockquote([Block])
        case bulletList([ListItem])
        case orderedList([ListItem])
        case taskList([TaskItem])
        case codeBlock(language: String?, code: String)
        case horizontalRule
        case callout(kind: CalloutKind, icon: String?, [Block])
        case details(open: Bool, summary: [Inline], [Block])
        case image(ImageBlock)
        case media(MediaBlock)
        case table(TableBlock)
        /// Column contents and their width shares (see `ContentParser.columnWeights(of:)`).
        case columns([[Block]], weights: [Double])
        case mathBlock(String)
        case subpages(sortBy: SubpagesSort)
        /// Tabs: one shows at a time (Docmost 0.97).
        case tabs([TabItem])
        /// A link to another service shown as a card (Docmost 0.97).
        case integrationCard(IntegrationLink)
        case transclusionSource([Block])
        case transclusionReference(sourcePageId: String?, transclusionId: String?)
        case base(pageId: String?)
        case pageBreak
        case unknown(type: String, [Block])
    }
}

public enum TextAlign: String, Sendable, Hashable {
    case left, center, right, justify
}

public struct TextBlock: Sendable, Hashable {
    public let inlines: [Inline]
    public let align: TextAlign?
    public let indent: Int

    public init(inlines: [Inline], align: TextAlign? = nil, indent: Int = 0) {
        self.inlines = inlines
        self.align = align
        self.indent = indent
    }
}

public struct ListItem: Sendable, Hashable, Identifiable {
    public let id: String
    /// Running number in ordered lists (`start` + index).
    public let number: Int?
    public let blocks: [Block]
}

public struct TaskItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let checked: Bool
    public let blocks: [Block]
}

public enum CalloutKind: String, Sendable, Hashable, CaseIterable {
    case `default`, info, note, success, warning, danger
}

/// One tab of a tabs block.
public struct TabItem: Sendable, Hashable, Identifiable {
    /// The tab's `id`, or one from its position while the id is missing or an earlier tab has it (Docmost gives the
    /// tab a new id with the next edit).
    public let id: String
    /// The label as plain text; empty if the tab has none.
    public let label: String
    public let blocks: [Block]
}

/// A link to an issue, pull request, design, message … in another service, which the server can describe
/// (`Endpoints.Integrations.unfurl`).
public struct IntegrationLink: Sendable, Hashable {
    public let url: String
    /// The service, e.g. `github`, `linear`, `figma`.
    public let provider: String

    public init(url: String, provider: String) {
        self.url = url
        self.provider = provider
    }
}

/// The order of a sub-pages block's pages, as the web offers it.
public enum SubpagesSort: String, Sendable, Hashable, CaseIterable {
    /// As in the page tree.
    case manual = "default"
    case titleAscending = "title-asc"
    case recent
}

/// Width/height of a media node: pixels/points or percent of the container.
public enum Length: Sendable, Hashable {
    case points(Double)
    case percent(Double)

    public init?(json: JSONValue?) {
        guard let json else { return nil }
        // Finite only: "nan%" or "inf" from crafted content can't size anything.
        if let number = json.doubleValue {
            guard number.isFinite else { return nil }
            self = .points(number)
        } else if let text = json.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            if text.hasSuffix("%"), let value = Double(text.dropLast()), value.isFinite {
                self = .percent(value)
            } else if let value = Double(text.replacingOccurrences(of: "px", with: "")), value.isFinite {
                self = .points(value)
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
}

public enum MediaAlign: String, Sendable, Hashable {
    case left, center, right
}

public struct ImageBlock: Sendable, Hashable {
    public let src: String?
    public let alt: String?
    public let width: Length?
    public let aspectRatio: Double?
    public let align: MediaAlign
}

public struct MediaBlock: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case video, audio, attachment, pdf, drawio, excalidraw, embed, youtube
    }

    public let kind: Kind
    /// The node's `src` or `url`.
    public let src: String?
    public let attachmentId: String?
    public let name: String?
    public let size: Int?
    public let provider: String?
}

public struct TableBlock: Sendable, Hashable {
    public struct Cell: Sendable, Hashable, Identifiable {
        public let id: String
        public let isHeader: Bool
        public let colspan: Int
        public let colwidth: [Double]?
        public let backgroundColor: String?
        public let backgroundColorName: String?
        public let blocks: [Block]
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public let id: String
        public let cells: [Cell]
    }

    public let rows: [Row]
}

public struct Footnote: Sendable, Hashable, Identifiable {
    public let id: String
    public let blocks: [Block]
}

// MARK: - Inline

public enum Inline: Sendable, Hashable {
    case text(String, InlineStyle)
    case hardBreak
    case mention(Mention)
    case mathInline(String)
    case status(text: String, color: String)
    case footnoteReference(number: String?, dataId: String?)
    /// A link to another service shown inline (Docmost 0.97).
    case integrationMention(IntegrationLink)
    /// An atom (mention, formula, status …) with marks: the web keeps formatting, links and comments on the whole atom.
    indirect case marked(Inline, InlineStyle)
    case unknown(type: String)
}

public struct InlineStyle: Sendable, Hashable {
    public var bold = false
    public var italic = false
    public var strike = false
    public var underline = false
    public var code = false
    public var superscript = false
    public var `subscript` = false
    public var link: Link?
    public var highlight: Highlight?
    public var textColor: String?
    public var comment: CommentMark?
}

public struct Link: Sendable, Hashable {
    public let href: String
    /// The service the web recognized the link as (Docmost 0.97), e.g. `github`.
    public let integrationProvider: String?

    public init(href: String, integrationProvider: String? = nil) {
        self.href = href
        self.integrationProvider = integrationProvider
    }
}

public struct Highlight: Sendable, Hashable {
    public let color: String?
    public let colorName: String?
}

public struct CommentMark: Sendable, Hashable {
    public let commentId: String?
    public let resolved: Bool
}

public struct Mention: Sendable, Hashable {
    public enum EntityType: String, Sendable, Hashable {
        case user, page
    }

    public let label: String?
    public let entityType: EntityType?
    public let entityId: String?
    public let slugId: String?
    public let anchorId: String?
}
