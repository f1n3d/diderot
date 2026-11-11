import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// "/" and "@" open their menus where the web's do: at a line's start or after whitespace, with a short query of typed
/// text up to the cursor.
struct TriggerParserTests {
    private func slash(_ text: String) -> String? {
        let text = AttributedString(text)
        return TriggerParser.slash(in: text, cursor: text.endIndex)?.query
    }

    @Test func slashOpensAtTheStartOrAfterWhitespace() {
        #expect(slash("/head") == "head")
        #expect(slash("Text /hea") == "hea")
        #expect(slash("Zeile\u{2028}/") == "")
        #expect(slash("a/b") == nil)
        #expect(slash("/head ing") == nil)
        #expect(slash("/" + String(repeating: "x", count: 24)) == String(repeating: "x", count: 24))
        #expect(slash("/" + String(repeating: "x", count: 25)) == nil)
    }

    @Test func mentionTakesLongerQueriesAndSaysWhereItsMarkIs() {
        let text = AttributedString("Hallo @" + String(repeating: "n", count: 30))
        let found = TriggerParser.mention(in: text, cursor: text.endIndex)
        #expect(found?.offset == 6 && found?.query.count == 30)
        let longer = AttributedString("@" + String(repeating: "n", count: 31))
        #expect(TriggerParser.mention(in: longer, cursor: longer.endIndex) == nil)
    }

    /// The Markdown marks of the web's input rules, at a line's start and up to the cursor only.
    @Test func markdownMarksAtALinesStart() {
        func shortcut(_ text: String, cursor: Int? = nil) -> TriggerParser.Shortcut? {
            let text = AttributedString(text)
            let index = cursor.map { text.characters.index(text.startIndex, offsetBy: $0) } ?? text.endIndex
            return TriggerParser.shortcut(in: text, cursor: index)?.shortcut
        }
        #expect(shortcut("# ") == .block(.heading1) && shortcut("## ") == .block(.heading2) && shortcut("### ") == .block(.heading3))
        #expect(shortcut("- ") == .block(.bulletList) && shortcut("* ") == .block(.bulletList) && shortcut("+ ") == .block(.bulletList))
        #expect(shortcut("1. ") == .block(.orderedList) && shortcut("12. ") == .block(.orderedList))
        #expect(shortcut("[] ") == .block(.taskList) && shortcut("[ ] ") == .block(.taskList))
        #expect(shortcut("> ") == .block(.quote) && shortcut("``` ") == .block(.codeBlock))
        #expect(shortcut("---") == .divider && shortcut("—-") == .divider)
        // With text after the cursor the mark still counts; with text before it, or without its space, it doesn't.
        #expect(shortcut("- Rest", cursor: 2) == .block(.bulletList))
        #expect(shortcut("a - ") == nil && shortcut("-") == nil && shortcut("#### ") == nil && shortcut(". ") == nil && shortcut("1.") == nil)
        #expect(TriggerParser.shortcut(in: AttributedString("12. "), cursor: AttributedString("12. ").endIndex)?.length == 4)
    }

    /// Mark and query are typed text: an atom between them and the cursor would be lost with the pick, and a user
    /// mention shows as "@label".
    @Test func onlyTypedTextCounts() {
        var text = AttributedString("/")
        text.append(DocumentModel.editorText(from: [PMNode(type: "status", attrs: ["text": "x", "color": "gray"])]))
        text.append(AttributedString("a"))
        #expect(TriggerParser.slash(in: text, cursor: text.endIndex) == nil)

        let mention = DocumentModel.editorText(from: [PMNode(type: "mention", attrs: ["label": "Ana", "entityType": "user"])])
        #expect(TriggerParser.mention(in: mention, cursor: mention.endIndex) == nil)

        let typed = AttributedString("/head und mehr")
        #expect(TriggerParser.slash(in: typed, cursor: typed.characters.index(typed.startIndex, offsetBy: 5))?.query == "head")
    }
}
