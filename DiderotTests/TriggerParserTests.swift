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
