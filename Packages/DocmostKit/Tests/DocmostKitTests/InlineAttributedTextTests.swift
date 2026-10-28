import Foundation
import Testing
@testable import DocmostKit

struct InlineAttributedTextTests {
    @Test func roundTripsMarks() {
        let inlines: [PMNode] = [
            PMNode(type: "text", text: "Plain "),
            PMNode(type: "text", marks: [PMMark(type: "bold")], text: "bold"),
            PMNode(type: "text", text: " and "),
            PMNode(type: "text", marks: [PMMark(type: "italic"), PMMark(type: "underline")], text: "italic underlined"),
            PMNode(type: "text", marks: [PMMark(type: "code")], text: " code"),
            PMNode(type: "text", marks: [PMMark(type: "link", attrs: ["href": "https://docmost.com", "target": "_blank", "internal": false])], text: "link"),
            PMNode(type: "text", marks: [PMMark(type: "highlight", attrs: ["color": "#faf594", "colorName": "yellow"])], text: "mark"),
            PMNode(type: "text", marks: [PMMark(type: "highlight", attrs: ["color": "#d7c4b7", "colorName": "brown"])], text: "brown"),
            PMNode(type: "text", marks: [PMMark(type: "textStyle", attrs: ["color": "#e03131"])], text: "red"),
            PMNode(type: "hardBreak"),
            PMNode(type: "text", marks: [PMMark(type: "strike"), PMMark(type: "superscript")], text: "x"),
        ]
        let text = InlineAttributedText.attributedString(from: inlines)
        #expect(String(text.characters) == "Plain bold and italic underlined codelinkmarkbrownred\u{2028}x")
        let back = InlineAttributedText.inlines(from: text)
        #expect(back == inlines)
    }

    /// A mailto: link has no host but must stay external, or the web opens it as a Docmost page.
    @Test func keepsInternalFlagOfLinks() {
        let inlines: [PMNode] = [
            PMNode(type: "text", marks: [PMMark(type: "link", attrs: ["href": "mailto:jane@example.com", "target": "_blank", "internal": false])], text: "mail"),
            PMNode(type: "text", text: " "),
            PMNode(type: "text", marks: [PMMark(type: "link", attrs: ["href": "/s/demo/p/x", "target": "_blank", "internal": true])], text: "page"),
        ]
        let text = InlineAttributedText.attributedString(from: inlines)
        #expect(InlineAttributedText.inlines(from: text) == inlines)
    }

    /// Writing back must not reopen resolved comment marks.
    @Test func keepsCommentResolvedState() {
        let inlines: [PMNode] = [
            PMNode(type: "text", marks: [PMMark(type: "comment", attrs: ["commentId": "c1", "resolved": false])], text: "offen"),
            PMNode(type: "text", text: " und "),
            PMNode(type: "text", marks: [PMMark(type: "comment", attrs: ["commentId": "c2", "resolved": true])], text: "erledigt"),
        ]
        let text = InlineAttributedText.attributedString(from: inlines)
        #expect(InlineAttributedText.inlines(from: text) == inlines)
    }

    @Test func preservesInlineAtomsUnlessEdited() {
        let mention = PMNode(type: "mention", attrs: ["id": "m1", "label": "Jane", "entityType": "user", "entityId": "u1"])
        let status = PMNode(type: "status", attrs: ["text": "Done", "color": "green"])
        let inlines: [PMNode] = [PMNode(type: "text", text: "Hi "), mention, PMNode(type: "text", text: " "), status]
        var text = InlineAttributedText.attributedString(from: inlines)
        #expect(String(text.characters) == "Hi @Jane Done")
        #expect(InlineAttributedText.inlines(from: text) == inlines)

        // Editing an atom's display text turns it into plain text.
        if let range = text.range(of: "@Jane") {
            text.replaceSubrange(range, with: AttributedString("@Janet"))
        }
        let edited = InlineAttributedText.inlines(from: text)
        #expect(edited.map(\.type) == ["text", "status"])
        #expect(edited.first?.text == "Hi @Janet ")
    }

    /// A line break in an atom's text (a formula written with Shift-Return) or in a text node never reaches the editor as
    /// "\n", which would count as Return: the atom shows a space and stays whole, the text gets a hardBreak.
    @Test func lineBreaksNeverReachTheEditorAsReturn() {
        let formula = PMNode(type: "mathInline", attrs: ["text": "a \\\\\nb"])
        let text = InlineAttributedText.attributedString(from: [formula])
        #expect(String(text.characters) == "a \\\\ b")
        #expect(InlineAttributedText.inlines(from: text) == [formula])

        let lines = InlineAttributedText.attributedString(from: [PMNode(type: "text", text: "a\nb")])
        #expect(!lines.characters.contains("\n"))
        #expect(InlineAttributedText.inlines(from: lines).map(\.type) == ["text", "hardBreak", "text"])
    }

    /// Formatting part of an atom (a double-tap selects "Grace" without the "@") splits its run; the atom stays and
    /// takes the formatting whole, as on the web, where a selection covers an atom whole or not at all.
    @Test func keepsPartlyFormattedAtom() throws {
        let attrs: [String: JSONValue] = ["id": "m1", "label": "Grace", "entityType": "user", "entityId": "u1"]
        let inlines: [PMNode] = [PMNode(type: "text", text: "Hi "), PMNode(type: "mention", attrs: attrs), PMNode(type: "text", text: " end")]
        var text = InlineAttributedText.attributedString(from: inlines)
        let name = try #require(text.range(of: "Grace"))
        text[name].inlinePresentationIntent = .stronglyEmphasized
        #expect(InlineAttributedText.inlines(from: text) == [
            PMNode(type: "text", text: "Hi "),
            PMNode(type: "mention", attrs: attrs, marks: [PMMark(type: "bold")]),
            PMNode(type: "text", text: " end"),
        ])

        // An edited display text still turns into plain text, with the formatting of its parts.
        text.removeSubrange(try #require(text.range(of: "ace")))
        #expect(InlineAttributedText.inlines(from: text) == [
            PMNode(type: "text", text: "Hi @"),
            PMNode(type: "text", marks: [PMMark(type: "bold")], text: "Gr"),
            PMNode(type: "text", text: " end"),
        ])
    }

    /// Two equal atoms side by side stay two atoms, also with only one of them formatted; their runs used to merge
    /// into one, whose text then no longer matched the atom.
    @Test func keepsEqualAtomsSideBySide() throws {
        let status = PMNode(type: "status", attrs: ["text": "Done", "color": "green"])
        let inlines: [PMNode] = [PMNode(type: "text", text: "A "), status, status]
        var text = InlineAttributedText.attributedString(from: inlines)
        #expect(InlineAttributedText.inlines(from: text) == inlines)

        let second = try #require(text.range(of: "Done", options: .backwards))
        text[second].inlinePresentationIntent = .stronglyEmphasized
        #expect(InlineAttributedText.inlines(from: text) == [
            PMNode(type: "text", text: "A "), status,
            PMNode(type: "status", attrs: status.attrs, marks: [PMMark(type: "bold")]),
        ])
    }

    /// Marks on atoms (an inline comment only on a mention, a bold formula) show while editing and are saved; they
    /// used to be dropped, leaving such a comment without an anchor.
    @Test func roundTripsMarksOnAtoms() throws {
        let comment = PMMark(type: "comment", attrs: ["commentId": "c1", "resolved": false])
        let inlines: [PMNode] = [
            PMNode(type: "mention", attrs: ["id": "m1", "label": "Jane", "entityType": "user", "entityId": "u1"], marks: [comment]),
            PMNode(type: "text", text: " "),
            PMNode(type: "mathInline", attrs: ["text": "x^2"], marks: [PMMark(type: "bold")]),
        ]
        var text = InlineAttributedText.attributedString(from: inlines)
        let formula = try #require(text.range(of: "x^2"))
        #expect(text[formula].inlinePresentationIntent == .stronglyEmphasized)
        #expect(InlineAttributedText.inlines(from: text) == inlines)

        // Removing the formatting from the whole atom removes it from the node.
        text[formula].inlinePresentationIntent = nil
        #expect(InlineAttributedText.inlines(from: text).last == PMNode(type: "mathInline", attrs: ["text": "x^2"]))
    }

    /// Empty status and math atoms (possible on the web) get placeholder display text and survive editing.
    @Test func keepsEmptyStatusAndFormula() {
        let inlines: [PMNode] = [
            PMNode(type: "text", text: "A "),
            PMNode(type: "status", attrs: ["text": "", "color": "blue"]),
            PMNode(type: "text", text: " B "),
            PMNode(type: "mathInline", attrs: ["text": ""]),
        ]
        let text = InlineAttributedText.attributedString(from: inlines)
        #expect(String(text.characters) == "A \u{00A0} B \u{00A0}")
        #expect(InlineAttributedText.inlines(from: text) == inlines)
    }

    @Test func mergesAdjacentRunsWithEqualMarks() {
        var text = AttributedString("ab")
        text.append(AttributedString("cd"))
        var bold = AttributedString("ef")
        bold.inlinePresentationIntent = .stronglyEmphasized
        text.append(bold)
        let inlines = InlineAttributedText.inlines(from: text)
        #expect(inlines.count == 2)
        #expect(inlines[0].text == "abcd")
        #expect(inlines[1].marks == [PMMark(type: "bold")])
    }
}
