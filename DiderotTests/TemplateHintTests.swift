import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Template hints (Docmost 0.98) in the line being edited go when typing reaches them, as on the web: typed into, part
/// of one deleted, or typed beside one that holds its line's start or end. Their text stayed on the page as text.
struct TemplateHintTests {
    private let hint = PMNode(type: "templatePlaceholder", attrs: ["hint": "Name eingeben"])

    @Test func typingIntoAHintTakesIt() throws {
        var text = line(hint)
        let typedBefore = String(text.characters)
        text.insert(AttributedString("X"), at: text.characters.index(text.startIndex, offsetBy: 4))
        #expect(TemplateHints.reached(in: text, typedBefore: typedBefore, cursor: 5).count == 1)
    }

    @Test func backspaceTakesTheWholeHint() throws {
        var text = line(PMNode(type: "text", text: "Kunde: "), hint)
        let typedBefore = String(text.characters)
        text.removeSubrange(text.characters.index(before: text.endIndex)..<text.endIndex)
        #expect(TemplateHints.reached(in: text, typedBefore: typedBefore, cursor: text.characters.count).count == 1)
    }

    /// Right before a hint at a line's start, or right after one at its end, typing replaces it; between other text on
    /// its line it stays, as on the web where only a hint the caret was put at goes then.
    @Test func typingBesideALineHintTakesIt() throws {
        let alone = line(hint)
        #expect(reached(typing: "A", at: 0, in: alone))
        #expect(reached(typing: "A", at: alone.characters.count, in: alone))
        let afterBreak = line(PMNode(type: "text", text: "Kunde"), PMNode(type: "hardBreak"), hint)
        #expect(reached(typing: "A", at: 6, in: afterBreak))
        let between = line(PMNode(type: "text", text: "Kunde: "), hint, PMNode(type: "text", text: " GmbH"))
        #expect(!reached(typing: "A", at: 7, in: between))
        #expect(!reached(typing: "A", at: 7 + 13, in: between))
        // Shift-Return keeps it.
        #expect(!reached(typing: String(InlineAttributedText.lineBreak), at: 0, in: alone))
        // Typing elsewhere leaves it.
        let later = line(hint, PMNode(type: "hardBreak"), PMNode(type: "text", text: "Rest"))
        #expect(!reached(typing: "A", at: later.characters.count, in: later))
    }

    private func line(_ nodes: PMNode...) -> AttributedString {
        InlineAttributedText.attributedString(from: nodes)
    }

    private func reached(typing typed: String, at offset: Int, in original: AttributedString) -> Bool {
        var text = original
        text.insert(AttributedString(typed), at: text.characters.index(text.startIndex, offsetBy: offset))
        return !TemplateHints.reached(in: text, typedBefore: String(original.characters), cursor: offset + typed.count).isEmpty
    }
}
