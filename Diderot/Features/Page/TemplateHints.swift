import Foundation
import DocmostKit

/// Template hints (`templatePlaceholder`, Docmost 0.98) in the line being edited, which typing replaces, as on the web
/// (`template-placeholder.ts`): a hint is an atom whose text is its hint, so text typed into it, or Backspace taking a
/// letter of it, left the rest of the hint on the page as text.
nonisolated enum TemplateHints {
    /// The hints (their `inlineNode` values) the change from `typedBefore` reached, the caret at `cursor` (characters)
    /// after it. One whose text changed: text typed into it, or part of it deleted. One beside which text was typed
    /// where it holds its line's start or end (the block's, or a line break's), the web's line hint: right before it at
    /// a line's start, right after it at a line's end. A line break alone (Shift-Return) keeps it, as on the web.
    static func reached(in text: AttributedString, typedBefore: String, cursor: Int) -> Set<String> {
        let hints = runs(in: text)
        guard !hints.isEmpty else { return [] }
        let characters = Array(text.characters)
        let added = characters.count - typedBefore.count
        let typed = added > 0 && cursor >= added ? (cursor - added)..<cursor : nil
        var reached: Set<String> = []
        for (value, ranges) in hints {
            guard let node = InlineAttributedText.atom(of: value) else { continue }
            let shown = ranges.map { String(characters[$0]) }.joined()
            if ranges.count > 1 || shown != InlineAttributedText.displayText(for: node) {
                reached.insert(value)
                continue
            }
            guard let typed, let range = ranges.first,
                  characters[typed].contains(where: { $0 != InlineAttributedText.lineBreak && !$0.isNewline })
            else { continue }
            func breaksLine(_ index: Int) -> Bool { index < 0 || index >= characters.count || characters[index] == InlineAttributedText.lineBreak }
            let atLineStart = typed.upperBound == range.lowerBound && breaksLine(typed.lowerBound - 1)
            let atLineEnd = typed.lowerBound == range.upperBound && breaksLine(typed.upperBound)
            if atLineStart || atLineEnd { reached.insert(value) }
        }
        return reached
    }

    /// The characters of each hint in `text`, in order: a hint typed into has several ranges.
    static func runs(in text: AttributedString) -> [(value: String, ranges: [Range<Int>])] {
        var found: [(value: String, ranges: [Range<Int>])] = []
        var offset = 0
        for run in text.runs {
            let length = text[run.range].characters.count
            defer { offset += length }
            // The string first: decoding every atom of the line on every key would cost more.
            guard let value = run.docmost.inlineNode, value.contains("\"templatePlaceholder\""),
                  InlineAttributedText.atom(of: value)?.type == "templatePlaceholder" else { continue }
            let range = offset..<(offset + length)
            if let index = found.firstIndex(where: { $0.value == value }) {
                if let last = found[index].ranges.last, last.upperBound == range.lowerBound {
                    found[index].ranges[found[index].ranges.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    found[index].ranges.append(range)
                }
            } else {
                found.append((value, [range]))
            }
        }
        return found
    }
}
