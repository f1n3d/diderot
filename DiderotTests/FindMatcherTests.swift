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
}
