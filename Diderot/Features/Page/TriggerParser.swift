import Foundation

/// The "/" and "@" a line's menus open on: the mark before the cursor, at the line's start or after whitespace (incl.
/// the line break U+2028), and the query typed after it, as on the web.
enum TriggerParser {
    /// The "/" menu's query and the mark's offset; 24 characters is above every command keyword.
    static func slash(in text: AttributedString, cursor: AttributedString.Index) -> (query: String, offset: Int)? {
        trigger("/", maxLength: 24, in: text, cursor: cursor)
    }

    /// The "@" menu's query and the mark's offset; 30 characters is above most names.
    static func mention(in text: AttributedString, cursor: AttributedString.Index) -> (query: String, offset: Int)? {
        trigger("@", maxLength: 30, in: text, cursor: cursor)
    }

    /// `mark` before `cursor`, followed by at most `maxLength` non-whitespace characters. The limits only end a menu
    /// once a longer word is typed.
    private static func trigger(_ mark: Character, maxLength: Int, in text: AttributedString,
                                cursor: AttributedString.Index) -> (query: String, offset: Int)? {
        let before = Array(text[text.startIndex..<cursor].characters)
        guard let offset = before.lastIndex(of: mark) else { return nil }
        let query = before[(offset + 1)...]
        guard query.count <= maxLength, !query.contains(where: \.isWhitespace) else { return nil }
        guard offset == 0 || before[offset - 1].isWhitespace else { return nil }
        // Mark and query are typed text, never an atom's: a user mention shows as "@label", a status or math may
        // contain either, and an atom between mark and cursor would be lost with the pick.
        let index = text.characters.index(text.startIndex, offsetBy: offset)
        if text[index..<cursor].runs.contains(where: { $0.docmost.inlineNode != nil }) { return nil }
        return (String(query), offset)
    }
}
