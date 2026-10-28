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
/// callouts, tables, open toggle blocks, columns, footnotes and this page's synced blocks.
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
    /// Incremented whenever the page should scroll to the current match.
    private(set) var revealRequest = 0
    /// Frame (in document coordinates) of the block with the current match, once it is rendered.
    var currentFrame: (ref: NodeRef, frame: CGRect)?

    var currentMatch: FindMatch? { matches.indices.contains(current) ? matches[current] : nil }

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
    func update(document: PMNode, baseURL: URL?, toggles: [[Int]: Bool], restart: Bool) {
        let previous = currentMatch
        matches = FindMatcher.matches(of: query, options: options, in: document, baseURL: baseURL, toggles: toggles)
        if restart {
            current = 0
        } else if let previous, let index = matches.firstIndex(of: previous) {
            current = index
        } else {
            current = min(current, max(matches.count - 1, 0))
        }
        if restart, !matches.isEmpty { revealRequest += 1 }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = (current + delta + matches.count) % matches.count
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

    /// `toggles`: `DocumentModel.readerToggles`.
    static func matches(
        of query: String, options: String.CompareOptions, in document: PMNode, baseURL: URL?, toggles: [[Int]: Bool] = [:]
    ) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        var result: [FindMatch] = []
        for entry in NodeEntry.entries(document.children, parentPath: []) {
            collect(entry.node, ref: entry.ref, topLevel: entry.ref, query: query, options: options, baseURL: baseURL, toggles: toggles, into: &result)
        }
        return result
    }

    private static func collect(
        _ node: PMNode, ref: NodeRef, topLevel: NodeRef, query: String, options: String.CompareOptions, baseURL: URL?,
        toggles: [[Int]: Bool], into result: inout [FindMatch]
    ) {
        func add(_ text: String) {
            for occurrence in ranges(of: query, options: options, in: text).indices {
                result.append(FindMatch(ref: ref, occurrence: occurrence, topLevel: topLevel))
            }
        }
        func visit(_ node: PMNode, ref: NodeRef) {
            collect(node, ref: ref, topLevel: topLevel, query: query, options: options, baseURL: baseURL, toggles: toggles, into: &result)
        }
        func children(_ nodes: [PMNode], parentPath: [Int]) {
            for entry in NodeEntry.entries(nodes, parentPath: parentPath) {
                visit(entry.node, ref: entry.ref)
            }
        }
        switch node.type {
        case "paragraph", "heading", "detailsSummary":
            add(displayedText(of: node, baseURL: baseURL))
        case "codeBlock":
            // Mermaid renders a diagram instead of the code.
            if node.string("language") != "mermaid" { add(node.plainText) }
        case "bulletList", "orderedList", "taskList", "columns", "footnotes":
            for item in NodeEntry.entries(node.children, parentPath: ref.path) {
                children(item.node.children, parentPath: item.ref.path)
            }
        case "table":
            for row in NodeEntry.entries(node.children, parentPath: ref.path) {
                for cell in NodeEntry.entries(row.node.children, parentPath: row.ref.path) {
                    children(cell.node.children, parentPath: cell.ref.path)
                }
            }
        case "blockquote", "callout", "detailsContent", "transclusionSource":
            children(node.children, parentPath: ref.path)
        case "details":
            // Like `ToggleNodeView`: summary at index 0, content from index 1 only while the toggle is open.
            if toggles[ref.path] ?? node.bool("open") ?? false {
                children(node.children, parentPath: ref.path)
            } else if let summary = node.children.first {
                visit(summary, ref: NodeRef(path: ref.path + [0], node: summary))
            }
        default:
            break
        }
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
