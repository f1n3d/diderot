import SwiftUI
import DocmostKit

extension EnvironmentValues {
    /// Find on page; text blocks use it to highlight their matches.
    @Entry var pageFind: PageFind?
}

/// One match: the block (ref as its view assigns it), the occurrence index in it, and the enclosing top-level block
/// (to scroll to while the block isn't loaded yet).
struct FindMatch: Equatable {
    let ref: NodeRef
    let occurrence: Int
    let topLevel: NodeRef
}

/// Find like Safari's "Find on Page": matches in reading order; the page scrolls to the current one. Ignores
/// diacritics, and case while "Aa" is off. Searches paragraphs, headings and code, also inside lists, quotes,
/// callouts, tables, toggle blocks, columns, footnotes and this page's synced blocks. A collapsed toggle shows its
/// content while it holds a match, as on the web (`holdsMatch(inside:)`), and stays collapsed: nothing is saved.
@MainActor
@Observable
final class PageFind {
    private(set) var isShown = false
    var query = ""
    /// Match case ("Aa"); persisted in `UserDefaults`.
    var matchCase = UserDefaults.standard.bool(forKey: PageFind.matchCaseKey) {
        didSet { UserDefaults.standard.set(matchCase, forKey: Self.matchCaseKey) }
    }
    private(set) var matches: [FindMatch] = []
    private(set) var current = 0
    /// A comment's passage the page shows ("Show on Page"): its first text block, which the page centers as it centers
    /// the current match, above the keyboard. Nothing is highlighted for it. It is shown for `passageDuration`, while
    /// the keyboard that comes back with the editor once the comments are gone centers it rather than the caret; the
    /// user's scrolling or find's next step end it sooner (`endPassage`).
    private(set) var passage: FindMatch?
    /// The comments' sheet closes in about half a second and the editor's keyboard comes back with it, later on a slow
    /// device.
    static let passageDuration = Duration.seconds(2.5)
    /// Incremented whenever the page should scroll to `revealTarget`.
    private(set) var revealRequest = 0
    /// Frame (in document coordinates) of the block holding `revealTarget`, once it is rendered.
    var currentFrame: (ref: NodeRef, frame: CGRect)?
    /// Top edge of the find bar in window coordinates while it shows: the current match is centered above it.
    @ObservationIgnored var barTop: CGFloat?

    var currentMatch: FindMatch? { matches.indices.contains(current) ? matches[current] : nil }

    /// What the page goes to: a comment's passage while it is shown, else the current match.
    var revealTarget: FindMatch? { passage ?? currentMatch }

    private static let matchCaseKey = "pageFind.matchCase"

    var options: String.CompareOptions { matchCase ? [.diacriticInsensitive] : [.caseInsensitive, .diacriticInsensitive] }

    func show() {
        isShown = true
    }

    func close() {
        isShown = false
        query = ""
        matches = []
        current = 0
        currentFrame = nil
    }

    /// Recomputes matches for a new query (`restart`: jumps to the first match) or a changed document.
    func update(document: PMNode, baseURL: URL?, restart: Bool) {
        let previous = currentMatch
        matches = FindMatcher.matches(of: query, options: options, in: document, baseURL: baseURL)
        if restart {
            current = 0
        } else if let previous, let index = matches.firstIndex(of: previous) {
            current = index
        } else {
            current = min(current, max(matches.count - 1, 0))
        }
        if restart, !matches.isEmpty {
            passage = nil
            revealRequest += 1
        }
    }

    /// Shows a comment's passage as find shows its match: the page goes to its block and centers it above the keyboard.
    func reveal(passage: FindMatch) {
        self.passage = passage
        revealRequest += 1
        let request = revealRequest
        Task { [weak self] in
            try? await Task.sleep(for: Self.passageDuration)
            // Unless something was shown since: a match (which ended the passage) or another passage (with its own end).
            if let self, revealRequest == request { self.passage = nil }
        }
    }

    /// The passage gives way: the user scrolls.
    func endPassage() {
        passage = nil
    }

    /// Whether a match lies in the block at `path` or below it: a collapsed toggle shows its content then.
    func holdsMatch(inside path: [Int]) -> Bool {
        matches.contains { $0.ref.path.count > path.count && $0.ref.path.starts(with: path) }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = (current + delta + matches.count) % matches.count
        passage = nil
        revealRequest += 1
    }
}

/// Finds and highlights matches in the text the views display (`InlineTextBuilder`), with the order and block refs
/// that `NodeView` and friends assign.
enum FindMatcher {
    /// Non-overlapping occurrences.
    static func ranges(of query: String, options: String.CompareOptions, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: options, range: start..<text.endIndex), !range.isEmpty {
            result.append(range)
            start = range.upperBound
        }
        return result
    }

    /// Highlights the active search's occurrences, the current match (by occurrence index) more strongly.
    static func highlight(_ text: inout AttributedString, find: PageFind, ref: NodeRef) {
        guard !find.query.isEmpty else { return }
        let current = find.currentMatch?.ref == ref ? find.currentMatch?.occurrence : nil
        let string = String(text.characters)
        for (index, range) in ranges(of: find.query, options: find.options, in: string).enumerated() {
            // By UTF-8 offset: constant time in `string`, logarithmic in `text`, as both hold the same text. Counting
            // characters from the start for every match was quadratic: a long code block froze each keystroke.
            let lower = string.utf8.distance(from: string.startIndex, to: range.lowerBound)
            let upper = string.utf8.distance(from: string.startIndex, to: range.upperBound)
            let start = text.utf8.index(text.startIndex, offsetBy: lower)
            let end = text.utf8.index(text.startIndex, offsetBy: upper)
            text[start..<end].backgroundColor = index == current ? Color.orange.opacity(0.65) : Color.yellow.opacity(0.4)
        }
    }

    /// Text of a paragraph or heading as `TextNodeView` displays it.
    static func displayedText(of node: PMNode, baseURL: URL?) -> String {
        String(InlineTextBuilder(baseURL: baseURL).attributedString(for: ContentParser.inlines(of: node)).characters)
    }

    static func matches(of query: String, options: String.CompareOptions, in document: PMNode, baseURL: URL?) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        var result: [FindMatch] = []
        forEachTextBlock(in: document) { node, ref, topLevel in
            let text = node.type == "codeBlock" ? node.plainText : displayedText(of: node, baseURL: baseURL)
            for occurrence in ranges(of: query, options: options, in: text).indices {
                result.append(FindMatch(ref: ref, occurrence: occurrence, topLevel: topLevel))
            }
            return true
        }
        return result
    }

    /// The first text block holding a comment's mark: where "Show on Page" goes, as find goes to a match. Nil where find
    /// doesn't look (tabs).
    static func passage(ofComment id: String, in document: PMNode) -> FindMatch? {
        var passage: FindMatch?
        forEachTextBlock(in: document) { node, ref, topLevel in
            guard node.holdsComment(id) else { return true }
            passage = FindMatch(ref: ref, occurrence: 0, topLevel: topLevel)
            return false
        }
        return passage
    }

    /// The text blocks find searches, in reading order, with the refs the views give them and their top-level block:
    /// paragraphs, headings, toggle titles and code (not Mermaid, which shows a diagram), also inside lists, quotes,
    /// callouts, tables, toggles, columns, footnotes and synced blocks. `body` returns false to stop.
    private static func forEachTextBlock(in document: PMNode, _ body: (PMNode, NodeRef, NodeRef) -> Bool) {
        for entry in NodeEntry.entries(document.children, parentPath: []) {
            guard visit(entry.node, ref: entry.ref, topLevel: entry.ref, body) else { return }
        }
    }

    /// One block and the text blocks inside it; false once `body` stopped.
    private static func visit(_ node: PMNode, ref: NodeRef, topLevel: NodeRef, _ body: (PMNode, NodeRef, NodeRef) -> Bool) -> Bool {
        func children(_ nodes: [PMNode], parentPath: [Int]) -> Bool {
            NodeEntry.entries(nodes, parentPath: parentPath).allSatisfy { visit($0.node, ref: $0.ref, topLevel: topLevel, body) }
        }
        switch node.type {
        case "paragraph", "heading", "detailsSummary":
            return body(node, ref, topLevel)
        case "codeBlock":
            // Mermaid renders a diagram instead of the code.
            return node.string("language") == "mermaid" || body(node, ref, topLevel)
        case "bulletList", "orderedList", "taskList", "columns", "footnotes":
            return NodeEntry.entries(node.children, parentPath: ref.path).allSatisfy { children($0.node.children, parentPath: $0.ref.path) }
        case "table":
            return NodeEntry.entries(node.children, parentPath: ref.path).allSatisfy { row in
                NodeEntry.entries(row.node.children, parentPath: row.ref.path).allSatisfy { children($0.node.children, parentPath: $0.ref.path) }
            }
        case "blockquote", "callout", "details", "detailsContent", "transclusionSource":
            // A toggle's title at index 0 and its content from index 1, also while it's collapsed: it shows a match there
            // (`ToggleNodeView`), as the web's search does.
            return children(node.children, parentPath: ref.path)
        default:
            return true
        }
    }
}

extension PMNode {
    /// Whether the node or one inside it carries the comment's mark.
    func holdsComment(_ id: String) -> Bool {
        marks?.contains { $0.type == "comment" && $0.string("commentId") == id } == true || children.contains { $0.holdsComment(id) }
    }
}

/// Find bar at the bottom above the keyboard, as in Safari: search field with "n of m", up/down and "Done".
struct PageFindBar: View {
    @Bindable var find: PageFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find on Page", text: $find.query)
                    .focused($focused)
                    .submitLabel(.next)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        find.next()
                        focused = true
                    }
                    .accessibilityIdentifier("page-find-field")
                if !find.query.isEmpty {
                    Group {
                        if find.matches.isEmpty {
                            Text("No matches")
                        } else {
                            Text("\(find.current + 1) of \(find.matches.count)")
                        }
                    }
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("page-find-count")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(.tertiarySystemFill), in: Capsule())
            Button {
                find.matchCase.toggle()
            } label: {
                Text(verbatim: "Aa")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(find.matchCase ? Color.white : Color.primary)
                    .frame(minWidth: 32, minHeight: 32)
                    .background(find.matchCase ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Match Case")
            .accessibilityAddTraits(find.matchCase ? .isSelected : [])
            .accessibilityIdentifier("page-find-case")
            Button {
                find.previous()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Previous Match")
            .accessibilityIdentifier("page-find-previous")
            Button {
                find.next()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Next Match")
            .accessibilityIdentifier("page-find-next")
            Button("Done") {
                find.close()
            }
            .fontWeight(.semibold)
            .accessibilityIdentifier("page-find-done")
        }
        .font(.body)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onAppear { focused = true }
    }
}
