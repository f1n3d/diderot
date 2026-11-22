import Foundation
import SwiftUI
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
            FindMatcher.matches(of: query, options: [.caseInsensitive], in: document, baseURL: nil, previewTitle: { _ in nil }).map(\.ref.path)
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
        find.update(document: document, baseURL: nil, previewTitles: [:], restart: true)
        #expect(find.matches.map(\.ref.path) == [[1, 0], [1, 1, 0]])
        #expect(find.holdsMatch(inside: [1, 1]))
        #expect(!find.holdsMatch(inside: [1, 0]), "a block counted as holding its own match")
        find.query = "davor"
        find.update(document: document, baseURL: nil, previewTitles: [:], restart: true)
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
        let matches = FindMatcher.matches(of: "treffer", options: [.caseInsensitive], in: document, baseURL: nil, previewTitle: { _ in nil })
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
        find.update(document: document, baseURL: nil, previewTitles: [:], restart: true)
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

    /// An integration mention whose preview loaded shows the service's title, not the one its address makes: find
    /// searches that title, so the bar counts what the page highlights, and the current match is the one highlighted
    /// as current.
    @Test func mentionIsFoundByTheTitleThePageShows() throws {
        let url = "https://github.com/acme/app/issues/12"
        let paragraph = PMNode(type: "paragraph", content: [
            PMNode(type: "text", text: "Ein crash vor "),
            NodeFactory.integrationMention(url: url, provider: "github"),
            PMNode(type: "text", text: " und ein crash danach"),
        ])
        let document = PMNode(type: "doc", content: [paragraph])
        let titles = [url: "Crash when opening settings"]
        let title = { (link: String) in titles[link] }
        let find = PageFind()
        find.query = "crash"
        find.update(document: document, baseURL: nil, previewTitles: titles, restart: true)
        #expect(find.matches.map(\.occurrence) == [0, 1, 2], "the mention's title wasn't searched")
        #expect(FindMatcher.matches(of: "acme", options: [.caseInsensitive], in: document, baseURL: nil, previewTitle: title).isEmpty,
                "the address's title was searched, which the page doesn't show")

        // The page's text as `TextNodeView` highlights it, with the last match current.
        find.previous()
        var text = InlineTextBuilder(baseURL: nil, previewTitle: title).attributedString(for: ContentParser.inlines(of: paragraph))
        FindMatcher.highlight(&text, find: find, ref: try #require(find.currentMatch).ref)
        let current = text.runs.filter { $0.backgroundColor == Color.orange.opacity(0.65) }
            .map { String(text[$0.range].characters) + String(text[$0.range.upperBound...].characters) }
        #expect(current == ["crash danach"], "another occurrence is highlighted as the current match")
    }

    /// Find searches a text it builds without the page's fonts, colors and links: the same characters as the page's,
    /// for every kind of run, also an atom with marks, a mention's title from its preview and one from its address.
    @Test func searchedTextIsTheShownText() {
        let url = "https://github.com/acme/app/issues/12"
        let paragraph = PMNode(type: "paragraph", content: [
            PMNode(type: "text", text: "Über "),
            PMNode(type: "text", marks: [PMMark(type: "link", attrs: ["href": .string("https://example.com")])], text: "Link"),
            PMNode(type: "hardBreak"),
            PMNode(type: "mention", attrs: ["entityType": .string("page"), "label": .string("Seite"), "slugId": .string("s1")]),
            PMNode(type: "mention", attrs: ["entityType": .string("user"), "label": .string("Ada"), "entityId": .string("u1")]),
            PMNode(type: "mention", attrs: ["entityType": .string("user")]),
            PMNode(type: "mathInline", attrs: ["text": .string("x^2")]),
            PMNode(type: "status", attrs: ["text": .string("Offen"), "color": .string("green")], marks: [PMMark(type: "bold")]),
            PMNode(type: "footnoteReference", attrs: ["referenceNumber": .string("3"), "data-id": .string("f3")]),
            PMNode(type: "footnoteReference"),
            NodeFactory.integrationMention(url: url, provider: "github"),
            NodeFactory.integrationMention(url: "https://github.com/acme/app/pull/7", provider: "github"),
            PMNode(type: "date", attrs: ["date": .string("2026-11-22")]),
            PMNode(type: "date"),
            PMNode(type: "templateVariable", attrs: ["name": .string("Kunde")]),
            PMNode(type: "templatePlaceholder", attrs: ["hint": .string("Hier tippen")]),
            PMNode(type: "unbekannt"),
            PMNode(type: "text", text: " Ende"),
        ])
        let inlines = ContentParser.inlines(of: paragraph)
        var builder = InlineTextBuilder(baseURL: URL(string: "https://docs.example.com"), previewTitle: { $0 == url ? "Crash" : nil })
        builder.atomLinkBlock = "block"
        let shown = String(builder.attributedString(for: inlines).characters)
        #expect(builder.plainText(for: inlines) == shown)
        #expect(shown.contains(" Crash ") && shown.contains("📄 Seite") && shown.contains(" Offen "), "the paragraph lacks runs: \(shown)")
    }

    /// Find keeps the blocks' texts between searches; another query, "Aa", a changed document or a mention's title
    /// that arrived searches as a search from scratch does, also after find closed while the page changed.
    @Test func eachSearchFindsWhatAFreshOneFinds() {
        let url = "https://github.com/acme/app/issues/12"
        func paragraph(_ text: String) -> PMNode { PMNode(type: "paragraph", content: [PMNode(type: "text", text: text)]) }
        let first = PMNode(type: "doc", content: [
            paragraph("Erster Treffer"),
            PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Vor "), NodeFactory.integrationMention(url: url, provider: "github")]),
            paragraph("treffer klein"),
        ])
        let second = PMNode(type: "doc", content: [paragraph("Neu davor"), paragraph("Noch ein Treffer")] + first.children)
        let find = PageFind()
        // "Aa" is kept in the defaults.
        let matchCase = find.matchCase
        defer { find.matchCase = matchCase }
        find.matchCase = false
        /// Searches `document` as the page does and checks the matches against a search from scratch.
        func expectFresh(_ document: PMNode, titles: [String: String], restart: Bool = false, _ comment: Comment) {
            find.update(document: document, baseURL: nil, previewTitles: titles, restart: restart)
            let fresh = FindMatcher.matches(of: find.query, options: find.options, in: document, baseURL: nil, previewTitle: { titles[$0] })
            #expect(find.matches == fresh, comment)
            #expect(!fresh.isEmpty, "nothing was checked: \(comment)")
        }
        find.show()
        find.query = "treffer"
        expectFresh(first, titles: [:], restart: true, "first search")
        find.query = "treff"
        expectFresh(first, titles: [:], restart: true, "another query")
        find.matchCase = true
        find.query = "Treffer"
        expectFresh(first, titles: [:], restart: true, "match case")
        find.matchCase = false
        expectFresh(second, titles: [:], "changed document")
        find.query = "crash"
        expectFresh(second, titles: [url: "Crash when opening settings"], restart: true, "a mention's title arrived")
        find.close()
        find.show()
        find.query = "treffer"
        expectFresh(first, titles: [:], restart: true, "after closing with another document")
    }

    /// A block holds a match when one lies anywhere below it, also deep in nested toggles, lists and tables, and not
    /// when the match is the block itself or beside it.
    @Test func holdsMatchGoesByEveryBlockAbove() {
        func paragraph(_ text: String) -> PMNode { PMNode(type: "paragraph", content: [PMNode(type: "text", text: text)]) }
        func toggle(_ title: String, _ content: [PMNode]) -> PMNode {
            PMNode(type: "details", content: [
                PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: title)]),
                PMNode(type: "detailsContent", content: content),
            ])
        }
        let list = PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [paragraph("Treffer in der Liste")])])
        let table = PMNode(type: "table", content: [PMNode(type: "tableRow", content: [PMNode(type: "tableCell", content: [paragraph("Treffer")])])])
        let document = PMNode(type: "doc", content: [
            paragraph("Davor"),
            toggle("Außen", [paragraph("Nichts"), toggle("Treffer innen", [paragraph("Treffer"), list]), table]),
            toggle("Leer", [paragraph("Nichts")]),
        ])
        let find = PageFind()
        find.query = "treffer"
        find.update(document: document, baseURL: nil, previewTitles: [:], restart: true)
        #expect(find.matches.map(\.ref.path) == [[1, 1, 1, 0], [1, 1, 1, 1, 0], [1, 1, 1, 1, 1, 0, 0], [1, 1, 2, 0, 0, 0]])
        var paths: Set<[Int]> = [[], [0], [2], [2, 1], [2, 1, 0], [1, 1, 0], [9, 9]]
        for match in find.matches { for count in 0...match.ref.path.count { paths.insert(Array(match.ref.path.prefix(count))) } }
        for path in paths {
            let below = find.matches.contains { $0.ref.path.count > path.count && $0.ref.path.starts(with: path) }
            #expect(find.holdsMatch(inside: path) == below, "\(path)")
        }
        #expect(find.holdsMatch(inside: [1, 1]) && find.holdsMatch(inside: [1, 1, 1, 1]))
        #expect(!find.holdsMatch(inside: [2, 1]))
        find.close()
        #expect(!find.holdsMatch(inside: [1, 1]), "a closed find still holds matches")
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
