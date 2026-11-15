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
    /// key again turns the block back into text, as on the web.
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
            } else if activeTablePosition != nil {
                Task { await focusNeighborCell(forward: inward) }
            } else if isInListItem {
                Task { await moveActiveItemLevel(inward: inward) }
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
        case .strikethrough, .inlineCode, .highlight:
            if !isCode { toggleFormat(action) }
        case .link:
            if !isCode { editsLink = true }
        case .turnInto(let template):
            // The same key again turns the block back into text, as the web's toggles do.
            let target = activeTemplate == template && template != .paragraph ? .paragraph : template
            if conversionTemplates.contains(target) { convertActive(to: target) }
        }
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

    /// Tab and Shift-Tab in a code block, as the web's (`enableTabIndentation`, `tabSize: 2`): two spaces at the cursor,
    /// or up to two fewer at the start of its line. Through the text view, as typing goes.
    private func indentCode(inward: Bool) {
        guard let view = editorTextView, let selected = view.selectedTextRange else { return }
        if inward {
            view.replace(selected, withText: "  ")
            return
        }
        let text = view.text as NSString
        let caret = view.offset(from: view.beginningOfDocument, to: selected.start)
        let newline = text.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: 0, length: caret))
        let lineStart = newline.location == NSNotFound ? 0 : newline.location + 1
        var spaces = 0
        while spaces < 2, lineStart + spaces < text.length, text.character(at: lineStart + spaces) == 32 { spaces += 1 }
        if spaces > 0, let start = view.position(from: view.beginningOfDocument, offset: lineStart),
           let end = view.position(from: start, offset: spaces), let range = view.textRange(from: start, to: end) {
            view.replace(range, withText: "")
        }
    }

    /// Tab and Shift-Tab in a table: to the next or previous cell, row by row, as the web's table keys do. Tab in the last
    /// cell adds a row and goes to its first cell, as there; Shift-Tab in the first cell stays.
    private func focusNeighborCell(forward: Bool) async {
        guard let position = activeTablePosition, let table = node(at: position.tablePath) else { return }
        let cells = table.children.enumerated().flatMap { row, node in node.children.indices.map { (row, $0) } }
        guard let index = cells.firstIndex(where: { $0 == (position.row, position.column) }) else { return }
        let next = index + (forward ? 1 : -1)
        if cells.indices.contains(next) {
            focusCell(of: position.tablePath, row: cells[next].0, column: cells[next].1)
        } else if forward {
            await editTable(.insertRowBelow)
            guard let added = activeTablePosition else { return }
            focusCell(of: added.tablePath, row: added.row, column: 0)
        }
    }

    private func focusCell(of tablePath: [Int], row: Int, column: Int) {
        let path = document.textPath(from: tablePath + [row, column])
        guard let node = node(at: path) else { return }
        activate(NodeRef(path: path, node: node), node: node, cursor: .end)
    }
}
