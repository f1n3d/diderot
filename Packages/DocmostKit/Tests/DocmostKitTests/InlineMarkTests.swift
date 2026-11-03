import Foundation
import Testing
@testable import DocmostKit

/// The one reading of stored marks for the reader and the editor (`InlineMark`), and how the editor writes a mark it
/// made.
struct InlineMarkTests {
    @Test func readsTheMarksTheAppShows() {
        let marks: [(PMMark, InlineMark?)] = [
            (PMMark(type: "bold"), .bold),
            (PMMark(type: "subscript"), .subscript),
            (PMMark(type: "link", attrs: ["href": "https://docmost.com", "integrationProvider": "github"]),
             .link(href: "https://docmost.com", integrationProvider: "github")),
            (PMMark(type: "link", attrs: ["href": ""]), nil),
            (PMMark(type: "link"), nil),
            (PMMark(type: "highlight", attrs: ["color": "#98d8f2", "colorName": "blue"]), .highlight(color: "#98d8f2", colorName: "blue")),
            (PMMark(type: "highlight"), .highlight(color: nil, colorName: nil)),
            (PMMark(type: "textStyle", attrs: ["color": "#e03131"]), .textColor("#e03131")),
            (PMMark(type: "textStyle", attrs: ["color": ""]), nil),
            (PMMark(type: "textStyle"), nil),
            (PMMark(type: "comment", attrs: ["commentId": "c1", "resolved": .bool(true)]), .comment(id: "c1", resolved: true)),
            (PMMark(type: "comment", attrs: ["commentId": "c2"]), .comment(id: "c2", resolved: false)),
            (PMMark(type: "kbd"), nil),
        ]
        for (mark, expected) in marks {
            #expect(InlineMark(mark) == expected, "\(mark)")
        }
    }

    /// A mark the editor made reads back as itself, written as the web writes a new one.
    @Test func writesMarksAsTheWebDoes() {
        let made: [InlineMark] = [
            .bold, .italic, .strike, .underline, .code, .superscript, .subscript,
            .link(href: "https://docmost.com", integrationProvider: nil), .link(href: "/s/demo/p/x", integrationProvider: "github"),
            .highlight(color: "#faf594", colorName: "yellow"), .highlight(color: "#123456", colorName: nil),
            .textColor("#e03131"), .comment(id: "c1", resolved: false),
        ]
        for mark in made {
            #expect(InlineMark(mark.mark) == mark, "\(mark)")
        }
        #expect(InlineMark.link(href: "https://docmost.com", integrationProvider: nil).mark.attrs
            == ["href": "https://docmost.com", "target": "_blank", "internal": .bool(false)])
        #expect(InlineMark.link(href: "/s/demo/p/x", integrationProvider: nil).mark.attrs?["internal"] == .bool(true))
        #expect(InlineMark.link(href: "mailto:jane@example.com", integrationProvider: nil).mark.attrs?["internal"] == .bool(false))
        #expect(InlineMark.highlight(color: "#123456", colorName: nil).mark.attrs?["colorName"] == .null)
    }
}
