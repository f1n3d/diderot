import Foundation

/// Custom attributes for Docmost marks that have no Foundation equivalent.
public enum DocmostAttributes {
    public enum HighlightAttribute: CodableAttributedStringKey {
        public typealias Value = String   // colorName or hex
        public static let name = "docmost.highlight"
    }

    public enum TextColorAttribute: CodableAttributedStringKey {
        public typealias Value = String   // hex
        public static let name = "docmost.textColor"
    }

    public enum UnderlineAttribute: CodableAttributedStringKey {
        public typealias Value = Bool
        public static let name = "docmost.underline"
    }

    public enum SuperscriptAttribute: CodableAttributedStringKey {
        public typealias Value = Bool
        public static let name = "docmost.superscript"
    }

    public enum SubscriptAttribute: CodableAttributedStringKey {
        public typealias Value = Bool
        public static let name = "docmost.subscript"
    }

    public enum CommentAttribute: CodableAttributedStringKey {
        public typealias Value = String   // commentId
        public static let name = "docmost.comment"
    }

    /// The comment here is resolved (set by the server on resolve); preserved while editing.
    public enum CommentResolvedAttribute: CodableAttributedStringKey {
        public typealias Value = Bool
        public static let name = "docmost.commentResolved"
    }

    /// The service a link points to (the link mark's `integrationProvider`, Docmost 0.97); kept while editing.
    public enum LinkProviderAttribute: CodableAttributedStringKey {
        public typealias Value = String
        public static let name = "docmost.linkProvider"
    }

    /// Non-editable inline node (mention, status, math …), stored as JSON text plus a key unique to the atom (see
    /// `InlineAttributedText.atomKeySeparator`).
    public enum InlineNodeAttribute: CodableAttributedStringKey {
        public typealias Value = String
        public static let name = "docmost.inlineNode"
    }

    /// The marks of the node a run came from, as JSON, as the server stored them: each goes back as it was while the run
    /// shows it the same (see `InlineAttributedText.marks(for:)`).
    public enum StoredMarksAttribute: CodableAttributedStringKey {
        public typealias Value = String
        public static let name = "docmost.storedMarks"
    }

    /// The attributes of the hard break a line break came from, as JSON, as the server stored them (its text direction,
    /// which the editor doesn't show): they go back with it.
    public enum StoredBreakAttribute: CodableAttributedStringKey {
        public typealias Value = String
        public static let name = "docmost.storedBreak"
    }
}

public struct DocmostAttributeScope: AttributeScope {
    public let highlight: DocmostAttributes.HighlightAttribute
    public let textColor: DocmostAttributes.TextColorAttribute
    public let underline: DocmostAttributes.UnderlineAttribute
    public let superscript: DocmostAttributes.SuperscriptAttribute
    public let `subscript`: DocmostAttributes.SubscriptAttribute
    public let comment: DocmostAttributes.CommentAttribute
    public let commentResolved: DocmostAttributes.CommentResolvedAttribute
    public let linkProvider: DocmostAttributes.LinkProviderAttribute
    public let inlineNode: DocmostAttributes.InlineNodeAttribute
    public let storedMarks: DocmostAttributes.StoredMarksAttribute
    public let storedBreak: DocmostAttributes.StoredBreakAttribute
    public let foundation: AttributeScopes.FoundationAttributes
}

extension AttributeScopes {
    public var docmost: DocmostAttributeScope.Type { DocmostAttributeScope.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<DocmostAttributeScope, T>) -> T {
        self[T.self]
    }
}

/// Converts ProseMirror inline content to `AttributedString` (for `TextEditor`) and back; marks map to Foundation
/// presentation intents and custom attributes.
public enum InlineAttributedText {
    /// `hardBreak` in the editor text: a line separator, so a typed `\n` stays recognizable as Return.
    public static let lineBreak: Character = "\u{2028}"
    /// Separates an atom's JSON from its unique key: two equal atoms side by side would merge into one run otherwise
    /// (and turn into text). JSON escapes control characters, so it never contains this one.
    static let atomKeySeparator: Character = "\u{1F}"

    public static func attributedString(from inlines: [PMNode]) -> AttributedString {
        var result = AttributedString()
        for node in inlines {
            switch node.type {
            case "text":
                // A line break inside the text (pasted, imported) becomes a hardBreak, which it shows as; read as it is,
                // it would count as Return and split the block.
                var run = AttributedString(String((node.text ?? "").map { $0.isNewline ? lineBreak : $0 }))
                apply(marks: node.marks ?? [], to: &run)
                keep(node.marks, in: &run)
                result.append(run)
            case "hardBreak":
                // Formatting a range on the web formats the breaks in it, and setting its direction sets theirs.
                var run = AttributedString(String(lineBreak))
                apply(marks: node.marks ?? [], to: &run)
                keep(node.marks, in: &run)
                if let attrs = node.attrs, let data = try? JSONEncoder().encode(attrs) {
                    run.docmost.storedBreak = String(decoding: data, as: UTF8.self)
                }
                result.append(run)
            default:
                // Inline atom: display text with the atom's marks, plus the node as an attribute so it survives the
                // round trip.
                var run = AttributedString(displayText(for: node))
                apply(marks: node.marks ?? [], to: &run)
                keep(node.marks, in: &run)
                if let data = try? JSONEncoder().encode(node), let json = String(data: data, encoding: .utf8) {
                    run.docmost.inlineNode = json + String(atomKeySeparator) + UUID().uuidString
                }
                result.append(run)
            }
        }
        return result
    }

    public static func inlines(from text: AttributedString) -> [PMNode] {
        var nodes: [PMNode] = []
        // An atom spans all adjacent runs with its JSON, since formatting part of it splits its run.
        for (value, range) in text.runs[\.inlineNode] {
            if let json = value?.split(separator: atomKeySeparator).first,
               let node = try? JSONDecoder().decode(PMNode.self, from: Data(json.utf8)),
               // If the display text was edited, only plain text remains.
               String(text[range].characters) == displayText(for: node)
            {
                // Formatting, links and comments on any part apply to the whole atom, as the web stores them (there a
                // selection covers an atom whole or not at all). Per type the first wins: each mark type excludes itself.
                var atomMarks: [PMMark] = []
                for run in text[range].runs {
                    for mark in marks(for: run) where !atomMarks.contains(where: { $0.type == mark.type }) {
                        atomMarks.append(mark)
                    }
                }
                nodes.append(PMNode(type: node.type, attrs: node.attrs, content: node.content,
                                    marks: atomMarks.isEmpty ? nil : atomMarks, text: node.text))
                continue
            }
            for run in text[range].runs {
                let marks = marks(for: run)
                // Hard breaks are separate nodes, with the run's marks as text has them; one inserted in the app has no
                // attributes, and the engine gives it the default direction.
                let breakAttrs = run.docmost.storedBreak.flatMap {
                    try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
                }
                let parts = String(text[run.range].characters).split(separator: lineBreak, omittingEmptySubsequences: false)
                for (index, part) in parts.enumerated() {
                    if index > 0 { nodes.append(PMNode(type: "hardBreak", attrs: breakAttrs, marks: marks.isEmpty ? nil : marks)) }
                    if !part.isEmpty {
                        nodes.append(PMNode(type: "text", marks: marks.isEmpty ? nil : marks, text: String(part)))
                    }
                }
            }
        }
        return mergeAdjacentText(nodes)
    }

    // MARK: - Marks ↔ attributes

    private static func apply(marks: [PMMark], to run: inout AttributedString) {
        var intents: InlinePresentationIntent = []
        for mark in marks {
            switch mark.type {
            case "bold": intents.insert(.stronglyEmphasized)
            case "italic": intents.insert(.emphasized)
            case "strike": intents.insert(.strikethrough)
            case "code": intents.insert(.code)
            case "underline": run.docmost.underline = true
            case "superscript": run.docmost.superscript = true
            case "subscript": run.docmost.subscript = true
            case "link":
                if let href = mark.string("href"), let url = URL(string: href) {
                    run.link = url
                    if let provider = mark.string("integrationProvider") { run.docmost.linkProvider = provider }
                }
            case "highlight":
                run.docmost.highlight = mark.string("colorName") ?? mark.string("color") ?? "yellow"
            case "textStyle":
                if let color = mark.string("color") { run.docmost.textColor = color }
            case "comment":
                if let id = mark.string("commentId") {
                    run.docmost.comment = id
                    if mark.bool("resolved") == true { run.docmost.commentResolved = true }
                }
            default: break
            }
        }
        if !intents.isEmpty { run.inlinePresentationIntent = intents }
    }

    /// Remembers the node's marks as stored, for `marks(for:)`.
    private static func keep(_ marks: [PMMark]?, in run: inout AttributedString) {
        guard let marks, !marks.isEmpty, let data = try? JSONEncoder().encode(marks) else { return }
        run.docmost.storedMarks = String(decoding: data, as: UTF8.self)
    }

    /// The run's marks: a stored one the run still shows as it was goes back unchanged, one the editor can't show (an
    /// unknown mark, a text style without color) stays, and the rest is built from what the run shows now (a changed
    /// link, a new format). All built from the attributes, they changed whenever the paragraph was edited: a link lost
    /// `rel` and `title` and got `target` `_blank`, a highlight took its name's color (`#f9e79f` "yellow" became
    /// `#faf594`), and the block's difference to its base grew, so the engine's rebase gave up more often.
    private static func marks(for run: AttributedString.Runs.Run) -> [PMMark] {
        let shown = shownMarks(for: run)
        guard let json = run.docmost.storedMarks, let stored = try? JSONDecoder().decode([PMMark].self, from: Data(json.utf8)) else {
            return shown
        }
        var marks: [PMMark] = []
        var added = shown
        for mark in stored {
            guard let back = shownMark(of: mark) else {
                marks.append(mark)
                continue
            }
            if let index = added.firstIndex(of: back) {
                marks.append(mark)
                added.remove(at: index)
            }
        }
        return marks + added
    }

    /// What the editor makes of `mark` alone: the mark `shownMarks(for:)` builds back from the attributes it shows as;
    /// nil if it shows as none.
    private static func shownMark(of mark: PMMark) -> PMMark? {
        var run = AttributedString(" ")
        apply(marks: [mark], to: &run)
        return run.runs.first.flatMap { shownMarks(for: $0).first }
    }

    /// The marks the run's attributes show.
    private static func shownMarks(for run: AttributedString.Runs.Run) -> [PMMark] {
        var marks: [PMMark] = []
        let intents = run.inlinePresentationIntent ?? []
        if intents.contains(.stronglyEmphasized) { marks.append(PMMark(type: "bold")) }
        if intents.contains(.emphasized) { marks.append(PMMark(type: "italic")) }
        if intents.contains(.strikethrough) { marks.append(PMMark(type: "strike")) }
        if intents.contains(.code) { marks.append(PMMark(type: "code")) }
        if run.docmost.underline == true { marks.append(PMMark(type: "underline")) }
        if run.docmost.superscript == true { marks.append(PMMark(type: "superscript")) }
        if run.docmost.subscript == true { marks.append(PMMark(type: "subscript")) }
        if let url = run.link {
            // Only relative links are internal; mailto: and tel: have no host, but the web must open them externally.
            let isInternal = url.scheme == nil
            var attrs: [String: JSONValue] = ["href": .string(url.absoluteString), "target": "_blank", "internal": .bool(isInternal)]
            if let provider = run.docmost.linkProvider { attrs["integrationProvider"] = .string(provider) }
            marks.append(PMMark(type: "link", attrs: attrs))
        }
        if let highlight = run.docmost.highlight {
            if highlight.hasPrefix("#") {
                marks.append(PMMark(type: "highlight", attrs: ["color": .string(highlight), "colorName": .null]))
            } else {
                marks.append(PMMark(type: "highlight", attrs: ["color": .string(HighlightColors.hex(for: highlight)), "colorName": .string(highlight)]))
            }
        }
        if let color = run.docmost.textColor { marks.append(PMMark(type: "textStyle", attrs: ["color": .string(color)])) }
        if let comment = run.docmost.comment {
            marks.append(PMMark(type: "comment", attrs: ["commentId": .string(comment), "resolved": .bool(run.docmost.commentResolved == true)]))
        }
        return marks
    }

    private static func mergeAdjacentText(_ nodes: [PMNode]) -> [PMNode] {
        var merged: [PMNode] = []
        for node in nodes {
            if node.type == "text", let last = merged.last, last.type == "text", last.marks == node.marks {
                merged[merged.count - 1] = PMNode(type: "text", marks: last.marks, text: (last.text ?? "") + (node.text ?? ""))
            } else {
                merged.append(node)
            }
        }
        return merged
    }

    /// On one line: a line break in an atom's text (a formula written with Shift-Return) would count as Return and split
    /// the block. The atom's JSON keeps the real text.
    public static func displayText(for node: PMNode) -> String {
        String(atomText(for: node).map { $0.isNewline ? " " : $0 })
    }

    private static func atomText(for node: PMNode) -> String {
        switch node.type {
        case "mention":
            let label = node.string("label") ?? "…"
            return node.string("entityType") == "user" ? "@\(label)" : label
        // Empty math and status nodes (the web allows them) need a character, or they vanish while editing.
        case "mathInline", "status": return nonEmpty(node.string("text"))
        case "footnoteReference": return "[\(node.string("referenceNumber") ?? "?")]"
        case "integrationMention": return IntegrationLinks.describe(node.string("url") ?? "").inline
        default: return "\u{FFFC}"
        }
    }

    private static func nonEmpty(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "\u{00A0}" }
        return text
    }
}

/// The web client's highlight colors (`color-selector.tsx`) in its order, name → hex. Exact values: the web picks its
/// light and dark highlight styles by hex.
public enum HighlightColors {
    public static let named: KeyValuePairs<String, String> = [
        "blue": "#98d8f2", "green": "#7edb6c", "purple": "#e0d6ed", "red": "#ffc6c2", "yellow": "#faf594",
        "orange": "#f5c8a9", "pink": "#f5cfe0", "gray": "#dfdfd7", "brown": "#d7c4b7",
    ]
    public static let names = named.map(\.key)

    public static func hex(for name: String) -> String {
        named.first { $0.key == name.lowercased() }?.value ?? "#faf594"
    }
}
