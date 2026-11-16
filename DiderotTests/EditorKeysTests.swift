import SwiftUI
import Testing
import UIKit
import DocmostKit
@testable import Diderot

/// Hardware keys in the page's editor as the web editor's shortcuts (`EditorKeyAction`, `DocumentModel.handleKey`).
@MainActor
struct EditorKeysTests {
    private func action(_ input: String, _ modifiers: UIKeyModifierFlags = []) -> EditorKeyAction? {
        EditorKeyAction(input: input, modifiers: modifiers)
    }

    @Test func keysMapToTheWebsShortcuts() {
        #expect(action("\t") == .indent)
        #expect(action("\t", .shift) == .outdent)
        // Caps Lock doesn't count.
        #expect(action("\t", [.shift, .alphaShift]) == .outdent)
        #expect(action("\r", .shift) == .lineBreak)
        #expect(action("\r", .command) == .lineBreak)
        #expect(action("k", .command) == .link)
        #expect(action("e", .command) == .inlineCode)
        #expect(action("S", [.command, .shift]) == .strikethrough)
        #expect(action("h", [.command, .shift]) == .highlight)
        #expect(action("b", [.command, .shift]) == .turnInto(.quote))
        #expect(action("c", [.command, .alternate]) == .turnInto(.codeBlock))
        #expect(action("0", [.command, .alternate]) == .turnInto(.paragraph))
        #expect(action("2", [.command, .alternate]) == .turnInto(.heading2))
        #expect(action("7", [.command, .shift]) == .turnInto(.orderedList))
        #expect(action("8", [.command, .shift]) == .turnInto(.bulletList))
        #expect(action("9", [.command, .shift]) == .turnInto(.taskList))
        #expect(action("d", [.command, .alternate]) == .toggleDetails)
        // What the text view keeps: Return, its own formats and undo, typing.
        #expect(action("\r") == nil)
        #expect(action("b", .command) == nil)
        #expect(action("z", .command) == nil)
        #expect(action("a") == nil)
    }

    /// Every shortcut is a key command that goes before the text view's own behavior (Tab's character, Return's split).
    @Test func shortcutsAreKeyCommandsWithPriority() {
        #expect(TextInputHooks.keyCommands.count == EditorKeyAction.shortcuts.count)
        #expect(TextInputHooks.keyCommands.allSatisfy { $0.wantsPriorityOverSystemBehavior && $0.action == TextInputHooks.keySelector })
        #expect(TextInputHooks.keyCommands.allSatisfy { EditorKeyAction(input: $0.input ?? "", modifiers: $0.modifierFlags) != nil })
    }

    /// Tab and Shift-Tab move a list item a level in and out and a paragraph a step; Shift-Return puts a line break into
    /// the line; ⌘⌥2 turns a paragraph into a heading, and again back into text.
    @Test(.timeLimit(.minutes(1))) func keysActOnTheActiveBlock() async throws {
        let item = PMNode(type: "paragraph", attrs: ["id": "i"], content: [PMNode(type: "text", text: "Punkt")])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "p"], content: [PMNode(type: "text", text: "Hallo")])
        let heading = PMNode(type: "heading", attrs: ["id": "h", "level": 2], content: [PMNode(type: "text", text: "Kopf")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [item])]), paragraph, heading,
        ]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()

        model.activate(NodeRef(path: [0, 0, 0], node: item), node: item)
        model.handleKey(.indent)
        model.handleKey(.outdent)
        // The same list key again takes the item out a level.
        #expect(model.activeTemplate == .bulletList)
        model.handleKey(.turnInto(.bulletList))
        while engine.itemLevelMoves.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.itemLevelMoves.map(\.inward) == [true, false, false])

        model.activate(NodeRef(path: [1], node: paragraph), node: paragraph)
        model.handleKey(.indent)
        while engine.attributeValues.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.attributeValues == [["indent": .number(1)]])
        model.handleKey(.lineBreak)
        #expect(String(model.activeText.characters) == "Hallo\u{2028}")
        // Selected text: the break takes its place, as Return does.
        let lo = model.activeText.characters.index(model.activeText.startIndex, offsetBy: 2)
        model.activeSelection = AttributedTextSelection(range: lo..<model.activeText.endIndex)
        model.handleKey(.lineBreak)
        #expect(String(model.activeText.characters) == "Ha\u{2028}")
        model.handleKey(.turnInto(.heading2))
        while engine.converted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.converted.last?.kind == "heading2")

        model.activate(NodeRef(path: [2], node: heading), node: heading)
        #expect(model.activeTemplate == .heading2)
        model.handleKey(.turnInto(.heading2))
        while engine.converted.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.converted.last?.kind == "paragraph")

        // ⌘⌥D: the engine toggles around the line (active again: the refused turn ended its editing).
        model.activate(NodeRef(path: [2], node: heading), node: heading)
        engine.toggleDetailsResult = .moved(EngineCursor(path: [2, 0], offset: 0))
        model.handleKey(.toggleDetails)
        for _ in 0..<200 where engine.toggledDetails.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.toggledDetails == [NodeRef(path: [2], node: heading).target])

        // Where no toggle fits and none is around the line (an item's first line), the key does nothing, as on the web.
        engine.conversionKinds = ["bulletList", "orderedList", "taskList"]
        model.activate(NodeRef(path: [0, 0, 0], node: item), node: item)
        engine.sendDocument()
        for _ in 0..<200 where model.answers?.conversions == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.handleKey(.toggleDetails)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.toggledDetails.count == 1, "the engine was asked where no toggle fits")
        #expect(model.active?.ref.path == [0, 0, 0], "editing ended")
    }

    /// Tab and Shift-Tab in code, through the text view: two spaces at the cursor, every selected line in and out (the
    /// lines stay selected), and at a cursor up to two spaces out of its line with the cursor staying in place.
    @Test func codeIndentsAndOutdentsItsLines() throws {
        let code = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "a\nb\nc")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [code]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.activate(NodeRef(path: [0], node: code), node: code)
        let view = UITextView()
        view.text = "a\nb\nc"
        model.editorTextView = view

        view.selectedRange = NSRange(location: 0, length: 5)
        model.handleKey(.indent)
        #expect(view.text == "  a\n  b\n  c")
        #expect(view.selectedRange == NSRange(location: 0, length: 11))
        model.handleKey(.outdent)
        #expect(view.text == "a\nb\nc")

        view.text = "x\n    y"
        view.selectedRange = NSRange(location: 7, length: 0)
        model.handleKey(.outdent)
        #expect(view.text == "x\n  y")
        #expect(view.selectedRange == NSRange(location: 5, length: 0))
        model.handleKey(.indent)
        #expect(view.text == "x\n  y  ")
    }

    /// Tab in a table cell goes to the next cell, row by row, Shift-Tab to the previous one, as the web's table keys do.
    @Test(.timeLimit(.minutes(1))) func tabMovesThroughATablesCells() async throws {
        func cell(_ id: String) -> PMNode {
            PMNode(type: "tableCell", content: [PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: id)])])
        }
        let table = PMNode(type: "table", content: [
            PMNode(type: "tableRow", content: [cell("a"), cell("b")]), PMNode(type: "tableRow", content: [cell("c"), cell("d")]),
        ])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [table]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let b = try #require(model.node(at: [0, 0, 1, 0]))
        model.activate(NodeRef(path: [0, 0, 1, 0], node: b), node: b)

        model.handleKey(.indent)
        while model.active?.ref.path == [0, 0, 1, 0] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.active?.ref.path == [0, 1, 0, 0])
        model.handleKey(.outdent)
        while model.active?.ref.path == [0, 1, 0, 0] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.active?.ref.path == [0, 0, 1, 0])
    }

    /// In a list in a table cell, Tab moves the item where it can, as the web's list keys go first, and goes to the next
    /// cell where it can't.
    @Test(.timeLimit(.minutes(1))) func tabInAListInACellMovesTheItemFirst() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "i"], content: [PMNode(type: "text", text: "Punkt")])
        let table = PMNode(type: "table", content: [PMNode(type: "tableRow", content: [
            PMNode(type: "tableCell", content: [PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [line])])]),
            PMNode(type: "tableCell", content: [PMNode(type: "paragraph", attrs: ["id": "n"], content: [PMNode(type: "text", text: "Nachbar")])]),
        ])])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [table]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()

        engine.levels = ItemLevels(indent: true, outdent: false)
        model.activate(NodeRef(path: [0, 0, 0, 0, 0, 0], node: line), node: line)
        while model.activeItemLevels == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.handleKey(.indent)
        while engine.itemLevelMoves.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.itemLevelMoves.map(\.inward) == [true])

        // Can't go out a level: Shift-Tab goes to the cell before, of which there is none; Tab where it can't go in either
        // goes to the next cell.
        engine.levels = ItemLevels(indent: false, outdent: false)
        model.deactivate()
        model.activate(NodeRef(path: [0, 0, 0, 0, 0, 0], node: line), node: line)
        while model.activeItemLevels?.indent != false { try await Task.sleep(for: .milliseconds(10)) }
        model.handleKey(.indent)
        while model.active?.ref.path == [0, 0, 0, 0, 0, 0] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.active?.ref.path == [0, 0, 1, 0])
        #expect(engine.itemLevelMoves.count == 1)
    }

    /// ↓ goes to the next text block in document order, into a list's first item and past a collapsed toggle's content to
    /// the block after it; ↑ back. In a table to the cell below or above, out of it at its last or first row. Code at the
    /// page's end gets a paragraph after it.
    @Test(.timeLimit(.minutes(1))) func arrowsGoToTheBlockAboveOrBelow() async throws {
        func text(_ id: String) -> PMNode { PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: id)]) }
        func cell(_ id: String) -> PMNode { PMNode(type: "tableCell", content: [text(id)]) }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            text("a"),
            PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [text("item")])]),
            PMNode(type: "details", attrs: ["open": false], content: [
                PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")]),
                PMNode(type: "detailsContent", content: [text("hidden")]),
            ]),
            PMNode(type: "table", content: [PMNode(type: "tableRow", content: [cell("c1"), cell("c2")]),
                                            PMNode(type: "tableRow", content: [cell("c3"), cell("c4")])]),
            PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "let x = 1")]),
        ]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        func activate(_ path: [Int]) throws {
            let node = try #require(model.node(at: path))
            model.activate(NodeRef(path: path, node: node), node: node)
        }

        try activate([0])
        model.handleKey(.lineDown)
        #expect(model.active?.ref.path == [1, 0, 0])
        model.handleKey(.lineDown)
        #expect(model.active?.ref.path == [2, 0], "not the collapsed toggle's title")
        model.handleKey(.lineDown)
        #expect(model.active?.ref.path == [3, 0, 0, 0], "not the table's first cell")
        try activate([3, 0, 1, 0])
        model.handleKey(.lineDown)
        #expect(model.active?.ref.path == [3, 1, 1, 0], "not the cell below")
        model.handleKey(.lineDown)
        #expect(model.active?.ref.path == [4], "not the code after the table")
        model.handleKey(.lineUp)
        #expect(model.active?.ref.path == [3, 1, 1, 0], "not the table's last cell")
        try activate([3, 0, 0, 0])
        model.handleKey(.lineUp)
        #expect(model.active?.ref.path == [2, 0], "not the block before the table")
        model.handleKey(.lineUp)
        model.handleKey(.lineUp)
        #expect(model.active?.ref.path == [0])

        // Code at the page's end: a paragraph after it.
        try activate([4])
        model.handleKey(.lineDown)
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.inserted.first?.node.type == "paragraph")
        #expect(engine.inserted.first?.position == .after)
    }

    /// ↑ and ↓ leave the block only from its first or last line, by the caret's place.
    @Test func arrowsLeaveOnlyFromTheEdgeLines() {
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.text = "eins\nzwei\ndrei"
        view.layoutIfNeeded()
        view.selectedRange = NSRange(location: 0, length: 0)
        #expect(DocumentModel.caretOnEdgeLine(of: view, up: true))
        #expect(!DocumentModel.caretOnEdgeLine(of: view, up: false))
        view.selectedRange = NSRange(location: 6, length: 0)
        #expect(!DocumentModel.caretOnEdgeLine(of: view, up: true) && !DocumentModel.caretOnEdgeLine(of: view, up: false))
        view.selectedRange = NSRange(location: 14, length: 0)
        #expect(DocumentModel.caretOnEdgeLine(of: view, up: false))
        // A selection stays with the text view.
        view.selectedRange = NSRange(location: 0, length: 4)
        #expect(!DocumentModel.caretOnEdgeLine(of: view, up: true))
        // Code is left only from its very start or end.
        view.selectedRange = NSRange(location: 14, length: 0)
        #expect(DocumentModel.caretAtEnd(of: view, up: false) && !DocumentModel.caretAtEnd(of: view, up: true))
        view.selectedRange = NSRange(location: 12, length: 0)
        #expect(!DocumentModel.caretAtEnd(of: view, up: false))
    }

    /// Three Returns at a code block's end leave it, as on the web: the empty lines go, and a paragraph follows.
    @Test(.timeLimit(.minutes(1))) func threeReturnsLeaveCode() async throws {
        let code = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "let x = 1")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [code]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.activate(NodeRef(path: [0], node: code), node: code)

        for _ in 0..<3 {
            model.activeCode += "\n"
            model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
            model.activeCodeChanged()
        }
        #expect(model.activeCode == "let x = 1")
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.inserted.first?.node.type == "paragraph")

        while model.leavesCode { try await Task.sleep(for: .milliseconds(10)) }

        // Quick Returns as one change leave it too; a pasted block that ends with empty lines doesn't.
        let other = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "a")])
        engine.document = PMNode(type: "doc", content: [code, other])
        engine.sendDocument()
        model.activate(NodeRef(path: [1], node: other), node: other)
        model.activeCode += "\nb\n\n\n"
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeCodeChanged()
        #expect(model.activeCode == "a\nb\n\n\n")
        model.activeCode = "a"
        model.activeCodeChanged()
        model.activeCode += "\n\n\n"
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeCodeChanged()
        #expect(model.activeCode == "a")
        while engine.inserted.count < 2 || model.leavesCode { try await Task.sleep(for: .milliseconds(10)) }

        // Code that ends with empty lines already: a Return at its end leaves it, as the web's does.
        model.deactivate()
        model.activate(NodeRef(path: [1], node: other), node: other)
        model.activeCode = "a\n\n\n"
        model.activeCodeChanged()
        model.activeCode += "\n"
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeCodeChanged()
        #expect(model.activeCode == "a\n")
    }
}
