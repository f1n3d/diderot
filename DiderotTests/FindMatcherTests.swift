import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Find on page uses the views' block refs, which are the blocks' real paths in the document.
@MainActor
struct FindMatcherTests {
    /// Matches are highlighted at their own characters, also after accents and emoji before them (the offsets go by
    /// UTF-8 now, which made long code blocks fast).
    @Test func highlightsTheMatchesThemselves() {
        var text = AttributedString("Über 🇩🇪 und über, ÜBER")
        let find = PageFind()
        find.query = "über"
        FindMatcher.highlight(&text, find: find, ref: NodeRef(path: [0], id: "a"))
        let marked = text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(marked == ["Über", "über", "ÜBER"])
    }

    @Test func toggleContentHasItsRealPath() {
        func paragraph(_ text: String) -> PMNode { PMNode(type: "paragraph", content: [PMNode(type: "text", text: text)]) }
        let toggle = PMNode(type: "details", attrs: ["open": true], content: [
            PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")]),
            PMNode(type: "detailsContent", content: [paragraph("Inhalt")]),
        ])
        let document = PMNode(type: "doc", content: [paragraph("Davor"), toggle])
        let paths = { (query: String) in
            FindMatcher.matches(of: query, options: [.caseInsensitive], in: document, baseURL: nil).map(\.ref.path)
        }
        // Index 0 of a toggle is its title, its content starts at index 1.
        #expect(paths("Titel") == [[1, 0]])
        #expect(paths("Inhalt") == [[1, 1, 0]])
    }

    /// A collapsed toggle's content is searched too, as on the web, and the toggle shows it while it holds a match. Its
    /// own `open`, or a reader's closing it on a read-only page, doesn't matter.
    @Test func collapsedToggleContentIsFound() {
        let toggle = PMNode(type: "details", content: [
            PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Treffer")]),
            PMNode(type: "detailsContent", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Treffer")])]),
        ])
        let document = PMNode(type: "doc", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Davor")]), toggle])
        let find = PageFind()
        find.query = "treffer"
        find.update(document: document, baseURL: nil, restart: true)
        #expect(find.matches.map(\.ref.path) == [[1, 0], [1, 1, 0]])
        #expect(find.holdsMatch(inside: [1, 1]))
        #expect(!find.holdsMatch(inside: [1, 0]), "a block counted as holding its own match")
        find.query = "davor"
        find.update(document: document, baseURL: nil, restart: true)
        #expect(!find.holdsMatch(inside: [1, 1]))
    }

    @Test func columnsSyncedBlocksAndFootnotesAreSearched() {
        func paragraph(_ text: String) -> PMNode { PMNode(type: "paragraph", content: [PMNode(type: "text", text: text)]) }
        let document = PMNode(type: "doc", content: [
            PMNode(type: "columns", content: [
                PMNode(type: "column", content: [paragraph("Links ein Treffer")]),
                PMNode(type: "column", content: [paragraph("Rechts Treffer und Treffer")]),
            ]),
            PMNode(type: "transclusionSource", content: [paragraph("Synchronisierter Treffer")]),
            PMNode(type: "footnotes", content: [PMNode(type: "footnote", content: [paragraph("Fußnote mit Treffer")])]),
        ])
        let matches = FindMatcher.matches(of: "treffer", options: [.caseInsensitive], in: document, baseURL: nil)
        // Reading order: left column, right column (two occurrences), synced block, footnote.
        #expect(matches.map(\.ref.path) == [[0, 0, 0], [0, 1, 0], [0, 1, 0], [1, 0], [2, 0, 0]])
        #expect(matches.map(\.occurrence) == [0, 0, 1, 0, 0])
        #expect(matches.map(\.topLevel.path) == [[0], [0], [0], [1], [2]])
    }

    /// "Show on Page" goes to the first text block holding the comment's mark, by the refs the views give it, as find
    /// goes to a match: an item's second paragraph, a table cell's. Where find doesn't look (tabs), nothing: the page
    /// falls back to the top-level block there.
    @Test func commentPassageIsItsFirstTextBlock() {
        func text(_ text: String, comment: String? = nil) -> PMNode {
            PMNode(type: "text", marks: comment.map { [PMMark(type: "comment", attrs: ["commentId": .string($0)])] }, text: text)
        }
        func paragraph(_ content: PMNode...) -> PMNode { PMNode(type: "paragraph", content: content) }
        let list = PMNode(type: "bulletList", content: [
            PMNode(type: "listItem", content: [paragraph(text("Eins"))]),
            PMNode(type: "listItem", content: [paragraph(text("Zwei")), paragraph(text("vor "), text("markiert", comment: "c1"))]),
        ])
        let table = PMNode(type: "table", content: [PMNode(type: "tableRow", content: [
            PMNode(type: "tableCell", content: [paragraph(text("A"))]),
            PMNode(type: "tableCell", content: [paragraph(text("B", comment: "c2"))]),
        ])])
        let tabs = PMNode(type: "tabs", content: [NodeFactory.tab(label: "Reiter", panel: [paragraph(text("C", comment: "c3"))])])
        let document = PMNode(type: "doc", content: [paragraph(text("Davor")), list, table, tabs, paragraph(text("später", comment: "c1"))])

        let first = FindMatcher.passage(ofComment: "c1", in: document)
        #expect(first?.ref.path == [1, 1, 1])
        #expect(first?.topLevel.path == [1])
        #expect(FindMatcher.passage(ofComment: "c2", in: document)?.ref.path == [2, 0, 1, 0])
        #expect(FindMatcher.passage(ofComment: "c3", in: document) == nil)
        #expect(document.children[3].holdsComment("c3"), "the fallback finds the tabs by their mark")
        #expect(FindMatcher.passage(ofComment: "c4", in: document) == nil)
    }

    /// A comment's passage goes before find's current match, with a request of its own, until find moves on.
    @Test func passageGoesBeforeTheMatchUntilFindMovesOn() {
        func paragraph(_ text: String) -> PMNode { PMNode(type: "paragraph", content: [PMNode(type: "text", text: text)]) }
        let document = PMNode(type: "doc", content: [paragraph("Treffer"), paragraph("Treffer"), paragraph("Stelle")])
        let find = PageFind()
        find.query = "treffer"
        find.update(document: document, baseURL: nil, restart: true)
        let requests = find.revealRequest
        let passage = FindMatch(ref: NodeRef(path: [2], id: nil), occurrence: 0, topLevel: NodeRef(path: [2], id: nil))
        find.reveal(passage: passage)
        #expect(find.revealTarget == passage)
        #expect(find.revealRequest == requests + 1)
        find.next()
        #expect(find.passage == nil)
        #expect(find.revealTarget == find.currentMatch)
        #expect(find.currentMatch?.ref.path == [1])
        // The user's scrolling ends it too.
        find.reveal(passage: passage)
        find.endPassage()
        #expect(find.revealTarget == find.currentMatch)
    }

    /// A passage is shown for a moment only: afterwards find's match is the target again, and no block keeps reporting
    /// for it.
    @Test func passageEndsByItself() async throws {
        let find = PageFind()
        let passage = FindMatch(ref: NodeRef(path: [0], id: nil), occurrence: 0, topLevel: NodeRef(path: [0], id: nil))
        find.reveal(passage: passage)
        #expect(find.passage == passage)
        try await Task.sleep(for: PageFind.passageDuration + .milliseconds(300))
        #expect(find.passage == nil)
    }
}
