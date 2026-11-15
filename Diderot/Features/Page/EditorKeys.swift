import UIKit
import DocmostKit

/// What a hardware key does in the page's editor, as the web editor's shortcuts do (TipTap's and Docmost's), as key
/// commands on the editor's text view (`TextInputHooks`). ⌘B, ⌘I and ⌘U stay with the text view, which has them.
enum EditorKeyAction: Equatable {
    /// Tab and Shift-Tab: a list item a level in or out, a paragraph or heading a step, two spaces in code (the web's
    /// `tabSize`), the next or previous cell in a table.
    case indent, outdent
    /// Shift-Return, and ⌘Return as TipTap's hard break takes it: a line break in the block, a new line in code.
    case lineBreak
    case strikethrough, inlineCode, highlight
    /// ⌘K: the link sheet, as the web's link shortcut.
    case link
    /// ⌘⌥0 text, ⌘⌥1 to ⌘⌥3 headings, ⌘⇧7/8/9 numbered, bullet and task list, ⌘⇧B quote, ⌘⌥C code block. The same
    /// key again turns a heading or code back into text and takes a list item out a level, as on the web.
    case turnInto(BlockTemplate)

    /// The keys, as UIKit matches key commands: a letter or digit as typed without modifiers, so ⌘⇧7 is the 7 key also
    /// where Shift-7 types "/".
    static let shortcuts: [(input: String, modifiers: UIKeyModifierFlags, action: EditorKeyAction)] = [
        ("\t", [], .indent),
        ("\t", [.shift], .outdent),
        ("\r", [.shift], .lineBreak),
        ("\r", [.command], .lineBreak),
        ("k", [.command], .link),
        ("e", [.command], .inlineCode),
        ("s", [.command, .shift], .strikethrough),
        ("h", [.command, .shift], .highlight),
        ("0", [.command, .alternate], .turnInto(.paragraph)),
        ("1", [.command, .alternate], .turnInto(.heading1)),
        ("2", [.command, .alternate], .turnInto(.heading2)),
        ("3", [.command, .alternate], .turnInto(.heading3)),
        ("7", [.command, .shift], .turnInto(.orderedList)),
        ("8", [.command, .shift], .turnInto(.bulletList)),
        ("9", [.command, .shift], .turnInto(.taskList)),
        ("b", [.command, .shift], .turnInto(.quote)),
        ("c", [.command, .alternate], .turnInto(.codeBlock)),
    ]

    /// The action of a key command; nil for any other.
    init?(input: String, modifiers: UIKeyModifierFlags) {
        let modifiers = modifiers.intersection([.shift, .control, .alternate, .command])
        guard let found = Self.shortcuts.first(where: { $0.input == input.lowercased() && $0.modifiers == modifiers }) else { return nil }
        self = found.action
    }
}

extension DocumentModel {
    /// A hardware key the editor takes instead of the text view (`TextInputHooks.onKey`). Tab is taken also where it
    /// moves nothing (a list's first item, a paragraph at 8 steps): the text view would put a tab character into the line.
    func handleKey(_ action: EditorKeyAction) {
        guard isEditable, let active else { return }
        let isCode = active.type == "codeBlock"
        switch action {
        case .indent, .outdent:
            let inward = action == .indent
            if isCode {
                indentCode(inward: inward)
            } else if isInListItem, activeTablePosition == nil || itemCanMove(inward: inward) {
                // In a table only where the item can move, as the web's list keys go before its table's.
                Task { await moveActiveItemLevel(inward: inward) }
            } else if activeTablePosition != nil {
                Task { await focusNeighborCell(forward: inward) }
            } else if activeIndentSteps != nil {
                Task { await indentActive(inward: inward) }
            }
        case .lineBreak:
            if isCode {
                // A new line, as Return makes there.
                editorTextView?.insertText("\n")
            } else {
                insertLineBreak()
            }
        case .strikethrough:
            if !isCode { toggleStrikethrough() }
        case .inlineCode:
            if !isCode { toggleInlineCode() }
        case .highlight:
            if !isCode { toggleHighlight() }
        case .link:
            if !isCode { editsLink = true }
        case .turnInto(let template):
            if activeTemplate != template {
                if conversionTemplates.contains(template) { convertActive(to: template) }
            } else if [.bulletList, .orderedList, .taskList].contains(template) {
                // The same list key again takes the item out a level, as the web's list toggles lift it.
                Task { await moveActiveItemLevel(inward: false) }
            } else if [.heading1, .heading2, .heading3, .codeBlock].contains(template), conversionTemplates.contains(.paragraph) {
                // And a heading or code back into text. A quote stays: Backspace at its start takes a line out.
                convertActive(to: .paragraph)
            }
        }
    }

    /// Whether the engine says the active list item can move a level in or out (`activeItemLevels`).
    private func itemCanMove(inward: Bool) -> Bool {
        guard let levels = activeItemLevels else { return false }
        return inward ? levels.indent : levels.outdent
    }

    /// What the active block is now, as the web's toggles see it: its heading level, code, its list's kind, the quote it
    /// sits in, or text.
    var activeTemplate: BlockTemplate? {
        guard let active else { return nil }
        switch active.type {
        case "heading":
            return [1: .heading1, 2: .heading2, 3: .heading3][active.attrs?["level"]?.intValue ?? 1]
        case "codeBlock":
            return .codeBlock
        default:
            if let itemPath = active.itemPath, let list = node(at: Array(itemPath.dropLast())), let kind = BlockTemplate(rawValue: list.type) {
                return kind
            }
            return node(at: Array(active.ref.path.dropLast()))?.type == "blockquote" ? .quote : .paragraph
        }
    }

    /// Tab and Shift-Tab in a code block, as the web's (`enableTabIndentation`, `tabSize: 2`): two spaces at the cursor;
    /// with code selected, every line it touches two spaces in, and Shift-Tab up to two out (the lines stay selected).
    /// Through the text view, as typing goes.
    func indentCode(inward: Bool) {
        guard let view = editorTextView, let selected = view.selectedTextRange else { return }
        let start = view.offset(from: view.beginningOfDocument, to: selected.start)
        let end = view.offset(from: view.beginningOfDocument, to: selected.end)
        if inward, start == end {
            view.replace(selected, withText: "  ")
            return
        }
        let text = view.text as NSString
        let lines = text.lineRange(for: NSRange(location: start, length: end - start))
        let block = text.substring(with: lines)
        let endsWithNewline = block.hasSuffix("\n")
        var pieces = block.components(separatedBy: "\n")
        if endsWithNewline { pieces.removeLast() }
        let replacement = pieces.map { line in
            inward ? "  " + line : String(line.dropFirst(min(2, line.prefix { $0 == " " }.count)))
        }.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard replacement != block, let from = view.position(from: view.beginningOfDocument, offset: lines.location),
              let to = view.position(from: from, offset: lines.length), let range = view.textRange(from: from, to: to)
        else { return }
        view.replace(range, withText: replacement)
        let length = (replacement as NSString).length
        if start == end {
            // Shift-Tab at a cursor: it stays where it was in the line, the removed spaces before it gone.
            let caret = max(lines.location, start - (lines.length - length))
            view.selectedRange = NSRange(location: caret, length: 0)
        } else {
            view.selectedRange = NSRange(location: lines.location, length: length - (endsWithNewline ? 1 : 0))
        }
    }

    /// Tab and Shift-Tab in a table: to the next or previous cell that starts with text, row by row, as the web's table
    /// keys do (a cell that starts with an image or a formula is skipped). Tab in the last cell adds a row and goes to its
    /// first cell, as there; Shift-Tab in the first cell stays.
    private func focusNeighborCell(forward: Bool) async {
        guard let position = activeTablePosition, let table = node(at: position.tablePath) else { return }
        let cells = table.children.enumerated().flatMap { row, node in node.children.indices.map { (row, $0) } }
        guard let index = cells.firstIndex(where: { $0 == (position.row, position.column) }) else { return }
        var next = index + (forward ? 1 : -1)
        while cells.indices.contains(next) {
            if focusCell(of: position.tablePath, row: cells[next].0, column: cells[next].1) { return }
            next += forward ? 1 : -1
        }
        guard forward else { return }
        // The new row is the table's last: by the rows it had, not the active cell, which may not have moved (a second
        // Tab while the first one's row is still being added).
        let rows = table.children.count
        await editTable(.insertRowBelow)
        guard let grown = node(at: position.tablePath), grown.children.count > rows else { return }
        focusCell(of: position.tablePath, row: rows, column: 0)
    }

    /// Edits the cell's first text; false where the cell starts with something else.
    @discardableResult
    private func focusCell(of tablePath: [Int], row: Int, column: Int) -> Bool {
        let path = document.textPath(from: tablePath + [row, column])
        guard let node = node(at: path), PMNode.editableTextTypes.contains(node.type) || node.type == "codeBlock" else { return false }
        activate(NodeRef(path: path, node: node), node: node, cursor: .end)
        return true
    }
}
