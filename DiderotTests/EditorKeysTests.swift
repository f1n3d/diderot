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
}
