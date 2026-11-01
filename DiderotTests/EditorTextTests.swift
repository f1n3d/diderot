import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// Typed text that continues a highlight carries only its background color; saving maps it back to the color name.
struct EditorTextTests {
    /// Showing a block in the editor and saving it keeps its marks as the server stores them: a link's `rel`, `class` and
    /// `title` and 0.97's `integrationProvider: null`, a highlight's own color, empty attributes, a line break's marks and
    /// direction (code review R3).
    @Test func savingKeepsStoredMarks() {
        let link = PMMark(type: "link", attrs: ["href": "https://docmost.com", "target": "_blank", "rel": "noopener noreferrer nofollow",
                                                "class": .null, "title": .null, "internal": false, "integrationProvider": .null])
        let inlines: [PMNode] = [
            PMNode(type: "text", marks: [PMMark(type: "bold", attrs: [:])], text: "Fett "),
            PMNode(type: "text", marks: [link], text: "Docmost"),
            PMNode(type: "hardBreak", attrs: ["dir": "rtl"], marks: [link]),
            PMNode(type: "text", marks: [link], text: "Wiki"),
            PMNode(type: "text", text: " "),
            PMNode(type: "text", marks: [PMMark(type: "highlight", attrs: ["color": "#f9e79f", "colorName": "yellow"])], text: "gelb"),
        ]
        #expect(DocumentModel.inlines(from: DocumentModel.editorText(from: inlines), base: .body) == inlines)
    }

    @Test func typedTextKeepsItsHighlightColor() {
        for name in ["red", "pink", "brown"] {
            var typed = AttributedString("x")
            typed.backgroundColor = EditorText.highlightColor(name)
            #expect(EditorText.normalized(typed).runs.first?.docmost.highlight == name)
        }
    }

    /// "Select All" in a fully bold paragraph also selects its mentions: it still reads as bold, and as not bold once a
    /// plain word is selected too. A mention alone reads as bold once it is.
    @Test func selectAllInBoldParagraphReadsBold() {
        var bold = AttributedString("Fett")
        bold.inlinePresentationIntent = .stronglyEmphasized
        var mention = AttributedString("@Ann")
        mention.docmost.inlineNode = #"{"type":"mention"}"#
        let text = bold + mention + bold
        let isBold: (AttributeContainer) -> Bool = { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }

        #expect(EditorText.allFormatted(text, in: RangeSet(text.startIndex..<text.endIndex), isBold))
        let plain = text + AttributedString(" normal")
        #expect(!EditorText.allFormatted(plain, in: RangeSet(plain.startIndex..<plain.endIndex), isBold))

        var alone = mention
        #expect(!EditorText.allFormatted(alone, in: RangeSet(alone.startIndex..<alone.endIndex), isBold))
        alone.inlinePresentationIntent = .stronglyEmphasized
        #expect(EditorText.allFormatted(alone, in: RangeSet(alone.startIndex..<alone.endIndex), isBold))
    }

    /// Code and highlight share the editor's background color: after either button, the text looks as after "Done",
    /// which renders the saved marks. Code replaces a highlight, as on the web.
    @Test func codeAndHighlightLookTheSameAfterDone() {
        let yellow = EditorText.highlightColor("yellow"), gray = EditorText.codeBackground
        let code = PMMark(type: "code"), highlight = PMMark(type: "highlight", attrs: ["colorName": "yellow"])
        func opened(_ marks: [PMMark]) -> AttributedString {
            DocumentModel.editorText(from: [PMNode(type: "text", marks: marks, text: "x")])
        }
        var typed = AttributedString("x")
        typed.backgroundColor = yellow
        let cases: [(String, AttributedString, (inout AttributeContainer) -> Void, Color)] = [
            ("code on saved highlight", opened([highlight]), { EditorText.setCode(true, in: &$0) }, gray),
            ("code on typed highlight", typed, { EditorText.setCode(true, in: &$0) }, gray),
            ("code off code+highlight", opened([code, highlight]), { EditorText.setCode(false, in: &$0) }, yellow),
            ("highlight off code+highlight", opened([code, highlight]), { EditorText.setHighlight(false, in: &$0) }, gray),
        ]
        for (name, start, toggle, background) in cases {
            var text = start
            var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
            text.transformAttributes(in: &selection, body: toggle)
            let saved = PMNode(type: "paragraph", content: InlineAttributedText.inlines(from: EditorText.normalized(text)))
            let afterDone = InlineTextBuilder().attributedString(for: ContentParser.inlines(of: saved))
            #expect(text.runs.first?.backgroundColor == background, "\(name): editor")
            #expect(afterDone.runs.first?.backgroundColor == background, "\(name): after Done")
        }
    }

    /// Superscript and subscript keep italic in the reader; the smaller font used to replace it.
    @Test(arguments: ["superscript", "subscript"]) func raisedTextKeepsItalic(mark: String) {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", marks: [PMMark(type: mark), PMMark(type: "italic")], text: "x")])
        let text = InlineTextBuilder().attributedString(for: ContentParser.inlines(of: paragraph))
        let font = text.runs.first?.font?.resolve(in: EnvironmentValues().fontResolutionContext)
        #expect(font?.isItalic == true)
    }

    /// System formatting (Cmd-U, the format panel) changes only the visible attribute: saving follows it both ways, so
    /// a removed underline or strikethrough doesn't come back after a reload.
    @Test func underlineAndStrikethroughFollowTheVisibleStyle() {
        var removed = AttributedString("x")
        removed.docmost.underline = true
        removed.inlinePresentationIntent = [.stronglyEmphasized, .strikethrough]
        let cleared = EditorText.normalized(removed).runs.first
        #expect(cleared?.docmost.underline == nil)
        #expect(cleared?.inlinePresentationIntent == .stronglyEmphasized)

        var typed = AttributedString("x")
        typed.underlineStyle = .single
        typed.strikethroughStyle = .single
        let added = EditorText.normalized(typed).runs.first
        #expect(added?.docmost.underline == true)
        #expect(added?.inlinePresentationIntent == .strikethrough)
    }

    /// System bold and italic (Cmd-B, Cmd-I, the format menu) set only these fonts (probed in the editor), on inline
    /// code also replacing the code intent: saving follows the font. A pasted font isn't saved.
    @Test func systemBoldAndItalicAreSaved() {
        func saved(_ font: Font, _ intents: InlinePresentationIntent? = nil) -> InlinePresentationIntent? {
            var typed = AttributedString("x")
            typed.font = font
            typed.inlinePresentationIntent = intents
            return EditorText.normalized(typed).runs.first?.inlinePresentationIntent
        }
        #expect(saved(.body.bold()) == .stronglyEmphasized)
        #expect(saved(.body.italic()) == .emphasized)
        #expect(saved(.body.italic().bold()) == [.emphasized, .stronglyEmphasized])
        #expect(saved(EditorText.codeFont) == .code)
        #expect(saved(EditorText.codeFont.bold(), .stronglyEmphasized) == [.code, .stronglyEmphasized])
        // Fixed size, as pasted rich text; with Bold Text, regular pasted system text resolves bold like this one.
        #expect(saved(Font(UIFont.systemFont(ofSize: 17, weight: .semibold))) == nil)
    }

    /// In a bold block font, system italic keeps the bold in the font and Cmd-B only removes or restores it (fonts
    /// probed in the editor): no bold mark, which would show once a heading becomes a paragraph. Bold on a regular
    /// block font is still saved. Holds with Bold Text on too.
    @Test func blockFontBoldIsNotSaved() {
        func saved(_ font: Font, in base: Font) -> InlinePresentationIntent? {
            var typed = AttributedString("x")
            typed.font = font
            return EditorText.normalized(typed, base: base).runs.first?.inlinePresentationIntent
        }
        // Headings 1–3, 5 and 6, and bold body text.
        for style in [Font.title, .title2, .title3, .subheadline, .footnote, .body] {
            #expect(saved(style.bold().italic(), in: style.bold()) == .emphasized)
            #expect(saved(style.bold().bold(false).bold(), in: style.bold()) == nil)
        }
        // Heading 4 is semibold, which Cmd-B can't take away.
        #expect(saved(.headline.italic(), in: .headline) == .emphasized)
        #expect(saved(.headline.bold(false), in: .headline) == nil)
        let toggleTitle = Font.body.weight(.medium)
        #expect(saved(toggleTitle.italic(), in: toggleTitle) == .emphasized)
        #expect(saved(toggleTitle.bold(), in: toggleTitle) == .stronglyEmphasized)
        #expect(saved(.body.bold(), in: .body) == .stronglyEmphasized)
        #expect(saved(.footnote.bold(), in: .footnote) == .stronglyEmphasized)
    }

    /// Cmd-B and Cmd-I set only the font: the Bold button sees that bold and takes it away, keeping the italic.
    @Test func boldButtonRemovesSystemBold() {
        var attributes = AttributeContainer()
        attributes.font = Font.body.italic().bold()
        #expect(EditorText.fontIntents(attributes.font, base: .body) == [.emphasized, .stronglyEmphasized])
        EditorText.setIntent(.stronglyEmphasized, false, in: &attributes, base: .body)
        #expect(attributes.font == nil && attributes.inlinePresentationIntent == .emphasized)
        // On inline code, Cmd-B also drops the code intent; the code font stays.
        attributes = AttributeContainer()
        attributes.font = EditorText.codeFont.bold()
        EditorText.setIntent(.stronglyEmphasized, false, in: &attributes, base: .body)
        #expect(attributes.font == EditorText.codeFont && attributes.inlinePresentationIntent == .code)
    }

    /// The comment sheet marks the selected occurrence of its quote, not the first one.
    @Test func commentMarksTheSelectedOccurrence() {
        let text = AttributedString("ab ab ab")
        let offset = { (range: Range<AttributedString.Index>?) in range.map { text.characters.distance(from: text.startIndex, to: $0.lowerBound) } }
        #expect(offset(InlineCommentSheet.passage("ab", near: 3, in: text)) == 3)
        #expect(offset(InlineCommentSheet.passage("ab", near: 7, in: text)) == 6)
        #expect(InlineCommentSheet.passage("cd", near: 3, in: text) == nil)
    }

    /// The link sheet changes or removes the whole link under the cursor, also when part of its text is bold.
    @Test func linkSheetTargetsTheWholeLink() {
        let link = PMMark(type: "link", attrs: ["href": "https://example.com"])
        let text = InlineAttributedText.attributedString(from: [
            PMNode(type: "text", text: "see "),
            PMNode(type: "text", marks: [link, PMMark(type: "bold")], text: "bold"),
            PMNode(type: "text", marks: [link], text: " plain"),
            PMNode(type: "text", text: " end"),
        ])
        // In the bold part, and right after the link.
        for offset in [5, 14] {
            let cursor = AttributedTextSelection(insertionPoint: text.characters.index(text.startIndex, offsetBy: offset))
            let target = LinkSheet.target(in: text, selection: cursor).range
            #expect(target.map { String(text[$0].characters) } == "bold plain", "cursor at \(offset)")
        }
    }

    /// A toolbar format changes each part of the selection on its own, as on the web: a link and other formats in it
    /// stay, a mention takes the format too, when turning the format on and off.
    @Test func toolbarFormatKeepsTheOtherMarks() {
        let mention = PMNode(type: "mention", attrs: ["id": "m1", "label": "Grace", "entityType": "user", "entityId": "u1"])
        let plain = [
            PMNode(type: "text", text: "Hi "), mention,
            PMNode(type: "text", marks: [PMMark(type: "link", attrs: ["href": "https://example.com"])], text: " site"),
            PMNode(type: "text", marks: [PMMark(type: "italic")], text: " it"),
            PMNode(type: "text", marks: [PMMark(type: "highlight", attrs: ["colorName": "green"])], text: " mark"),
        ]
        let allBold = plain.map { node in
            PMNode(type: node.type, attrs: node.attrs, marks: [PMMark(type: "bold")] + (node.marks ?? []), text: node.text)
        }
        // Opens the inlines in the editor, selects all, applies the Bold button's change (if any) and saves.
        func saved(_ inlines: [PMNode], bold: Bool? = nil) -> [PMNode] {
            var text = DocumentModel.editorText(from: inlines)
            var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
            if let bold {
                EditorText.transformRuns(of: &text, in: &selection) { EditorText.setIntent(.stronglyEmphasized, bold, in: &$0, base: .body) }
                #expect(selection.indices(in: text) == .ranges(RangeSet(text.startIndex..<text.endIndex)), "selection kept")
            }
            return DocumentModel.inlines(from: text, base: .body)
        }
        // Marks in any order: kept ones go back in their stored order and a new one after them; the engine orders them
        // by its schema.
        func unordered(_ inlines: [PMNode]) -> [PMNode] {
            inlines.map { PMNode(type: $0.type, attrs: $0.attrs, content: $0.content, marks: $0.marks?.sorted { $0.type < $1.type }, text: $0.text) }
        }
        #expect(unordered(saved(plain, bold: true)) == unordered(saved(allBold)))
        #expect(unordered(saved(allBold, bold: false)) == unordered(saved(plain)))
    }
}
