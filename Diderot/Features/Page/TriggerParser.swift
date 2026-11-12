import Foundation

/// The "/" and "@" a line's menus open on: the mark before the cursor, at the line's start or after whitespace (incl.
/// the line break U+2028), and the query typed after it, as on the web. And the Markdown marks that turn a line into a
/// block when typed at its start, as the web's input rules do.
enum TriggerParser {
    /// What a Markdown mark at a line's start turns the line into.
    enum Shortcut: Equatable {
        case block(BlockTemplate)
        /// "---": a divider takes the line's place.
        case divider
    }

    /// The Markdown mark the text from the line's start to `cursor` consists of, and its length in characters: "# " to
    /// "### ", "- ", "* " or "+ ", a number with ". ", "[] " or "[ ] ", "> ", "``` ", and "---" without a space (also
    /// "—-", which the keyboard's smart dashes make of it, as the web takes it too).
    static func shortcut(in text: AttributedString, cursor: AttributedString.Index) -> (shortcut: Shortcut, length: Int)? {
        let before = text[text.startIndex..<cursor]
        // Typed text only, and nothing longer than a number of nine digits with its ". ".
        guard before.characters.count <= 11, !before.runs.contains(where: { $0.docmost.inlineNode != nil }) else { return nil }
        let mark = String(before.characters)
        let found: Shortcut? = switch mark {
        case "# ": .block(.heading1)
        case "## ": .block(.heading2)
        case "### ": .block(.heading3)
        case "- ", "* ", "+ ": .block(.bulletList)
        case "[] ", "[ ] ": .block(.taskList)
        case "> ": .block(.quote)
        case "``` ": .block(.codeBlock)
        case "---", "—-": .divider
        default: mark.count > 2 && mark.hasSuffix(". ") && mark.dropLast(2).allSatisfy { ("0"..."9").contains($0) } ? .block(.orderedList) : nil
        }
        return found.map { ($0, mark.count) }
    }

    /// The Markdown mark at the line's start that a change's typing completed (it typed from offset `typedFrom` to
    /// `cursor`), and its length: right before the cursor, or followed by letters typed in the same change, as when keys
    /// come faster than the page's updates, which then see them as one change (XCUITest's come about 6 ms apart, a few
    /// per update). Not followed by more than `typedAfterMark` characters: a longer insertion is a paste or the app's own
    /// text, such as the date from "+", whose "12. November 2026" turned its line into a numbered list without its day. A
    /// mark that was there before the change, left behind by deleting what followed it, turns nothing.
    static func typedShortcut(in text: AttributedString, typedFrom: Int, cursor: AttributedString.Index) -> (shortcut: Shortcut, length: Int)? {
        let typedTo = text.characters.distance(from: text.startIndex, to: cursor)
        let longest = min(typedTo, 11)
        guard typedFrom < longest else { return nil }
        for length in (typedFrom + 1)...longest {
            if let found = shortcut(in: text, cursor: text.characters.index(text.startIndex, offsetBy: length)) {
                return typedTo - length <= typedAfterMark ? found : nil
            }
        }
        return nil
    }

    /// The most letters typed after a mark in the change that completed it (`typedShortcut`).
    static let typedAfterMark = 5

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
