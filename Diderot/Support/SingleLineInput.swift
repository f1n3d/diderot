import Foundation

/// Line breaks in a single-line input (a page's or database entry's title, a text field), which wraps but ends with
/// Return. Only what the user just put in counts, so the input takes changes only while it has focus: the stored value
/// keeps its line breaks (written through the API or an import). Removed from it, the input differed from what was
/// stored and saved that when it went, without anyone typing.
enum SingleLineInput {
    /// The change from `old` to `new` as the input takes it, or nil when it brought no line break. Return ends the input:
    /// alone it changes nothing, also over a selection, which it would have replaced; at the end of keys typed so fast
    /// that they come as one change, it goes and the keys stay. Line breaks within the change (a pasted text's) become
    /// spaces.
    static func taking(_ new: String, after old: String) -> (text: String, endsInput: Bool)? {
        let before = Array(old), after = Array(new)
        var start = 0
        while start < before.count, start < after.count, before[start] == after[start] { start += 1 }
        var end = 0
        while end < before.count - start, end < after.count - start, before[before.count - 1 - end] == after[after.count - 1 - end] {
            end += 1
        }
        var inserted = Array(after[start..<(after.count - end)])
        guard inserted.contains(where: \.isNewline) else { return nil }
        if inserted.allSatisfy(\.isNewline) { return (old, true) }
        let endsInput = inserted.last?.isNewline == true
        while inserted.last?.isNewline == true { inserted.removeLast() }
        let kept = String(inserted.map { $0.isNewline ? " " : $0 })
        return (String(after[..<start]) + kept + String(after[(after.count - end)...]), endsInput)
    }
}
