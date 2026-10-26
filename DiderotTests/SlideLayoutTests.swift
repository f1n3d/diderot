import CoreGraphics
import Testing
import DocmostKit
@testable import Diderot

/// The presentation mode's slides follow the web's rules (Docmost 0.97): as many blocks as fit, a heading 1 begins a
/// slide, a divider ends one, a table or database is the last block of its slide, empty lines and page breaks are left
/// out, and a block taller than the slide scrolls on a slide of its own.
struct SlideLayoutTests {
    private func slides(_ roles: [SlideLayout.Role], _ heights: [CGFloat], height: CGFloat = 100) -> [[Int]] {
        SlideLayout.slides(roles: roles, heights: heights, height: height, spacing: 10).map(\.blocks)
    }

    @Test func blocksShareASlideWhileTheyFit() {
        // 40 + 10 + 40 = 90 fits 100; another 10 + 40 doesn't.
        #expect(slides([.content, .content, .content, .content], [40, 40, 40, 40]) == [[0, 1], [2, 3]])
        // Exactly the slide's height still fits.
        #expect(slides([.content, .content], [45, 45]) == [[0, 1]])
    }

    @Test func headingOneBeginsASlide() {
        #expect(slides([.section, .content, .section, .content], [20, 20, 20, 20]) == [[0, 1], [2, 3]])
        #expect(slides([.content, .section], [20, 20]) == [[0], [1]])
    }

    @Test func dividerEndsASlideWithoutShowing() {
        #expect(slides([.content, .divider, .content], [20, 1, 20]) == [[0], [2]])
        // Dividers in a row or at the ends make no empty slides.
        #expect(slides([.divider, .content, .divider, .divider, .content, .divider], [1, 20, 1, 1, 20, 1]) == [[1], [4]])
    }

    @Test func tableOrDatabaseIsTheLastBlockOfItsSlide() {
        #expect(slides([.content, .closing, .content, .closing], [20, 20, 20, 20]) == [[0, 1], [2, 3]])
        #expect(slides([.closing, .content], [20, 20]) == [[0], [1]])
    }

    @Test func emptyLinesAndPageBreaksAreLeftOut() {
        #expect(slides([.content, .hidden, .hidden, .content], [20, 20, 0, 20]) == [[0, 3]])
        #expect(slides([.hidden], [20]).isEmpty)
    }

    @Test func blockTallerThanTheSlideScrollsAlone() {
        let layout = SlideLayout.slides(roles: [.content, .content, .content], heights: [20, 250, 20], height: 100, spacing: 10)
        #expect(layout == [
            SlideLayout.Slide(blocks: [0], scrolls: false),
            SlideLayout.Slide(blocks: [1], scrolls: true),
            SlideLayout.Slide(blocks: [2], scrolls: false),
        ])
    }

    @Test func rolesFromPageContent() {
        func text(_ text: String) -> [PMNode] { text.isEmpty ? [] : [PMNode(type: "text", text: text)] }
        let doc = PMNode(type: "doc", content: [
            PMNode(type: "heading", attrs: ["level": 1], content: text("Title")),
            PMNode(type: "heading", attrs: ["level": 2], content: text("Section")),
            PMNode(type: "paragraph", content: text("Text")),
            PMNode(type: "paragraph", content: text("  ")),
            PMNode(type: "paragraph", content: [PMNode(type: "hardBreak")]),
            PMNode(type: "heading", attrs: ["level": 1]),
            PMNode(type: "codeBlock", content: text("\n")),
            PMNode(type: "codeBlock", content: text("let x = 1")),
            PMNode(type: "horizontalRule"),
            PMNode(type: "pageBreak"),
            PMNode(type: "table", content: [PMNode(type: "tableRow", content: [PMNode(type: "tableCell", content: [PMNode(type: "paragraph")])])]),
            PMNode(type: "image", attrs: ["src": "/api/files/a.png"]),
        ])
        let roles = ContentParser.parse(doc).blocks.map { SlideLayout.Role($0.kind) }
        #expect(roles == [.section, .content, .content, .hidden, .hidden, .hidden, .hidden, .content, .divider, .hidden, .closing, .content])
    }

    /// After the slides change (rotation, an image loaded), the presentation stays at the block it showed first.
    @Test func slideShowingABlock() {
        let layout = SlideLayout.slides(roles: [.content, .hidden, .content, .content], heights: [40, 0, 40, 40], height: 100, spacing: 10)
        #expect(layout.map(\.blocks) == [[0, 2], [3]])
        #expect(SlideLayout.slide(showing: 2, in: layout) == 0)
        #expect(SlideLayout.slide(showing: 3, in: layout) == 1)
        // A left-out block: the slide after it.
        #expect(SlideLayout.slide(showing: 1, in: layout) == 0)
        #expect(SlideLayout.slide(showing: 9, in: layout) == 1)
        #expect(SlideLayout.slide(showing: 0, in: []) == 0)
    }
}
