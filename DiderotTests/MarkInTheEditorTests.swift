import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// A Markdown mark typed in the editor itself (`ActiveTextEditor` in a window), with keys coming faster than SwiftUI's
/// updates, as XCUITest's do in test94 (about 6 ms apart). One test at a time: each focuses its own editor, and the first
/// responder is the app's.
@MainActor @Suite(.serialized) struct MarkInTheEditorTests {
    /// Keys right after the mark, before SwiftUI's next update, also when the first of them came with the mark. The page
    /// used to take the mark away on its own text and set the caret to the line's start there, which reached the text
    /// view only with that update: a key before it brought the mark back ("- Mdliste…" in test94), or stood behind the
    /// caret, so the next one went in before it ("dliste…M"). Taken away in the text view, the caret went where the mark
    /// had been, before letters typed with it.
    @Test(.timeLimit(.minutes(1)), arguments: [("- ", ["M", "d"]), ("- M", ["d"]), ("``` Md", ["c"])])
    func lettersTypedRightAfterAMarkStayInOrder(typed: String, next: [String]) async throws {
        let editor = try await Editor()
        defer { editor.close() }
        let view = editor.view

        view.insertText(typed)
        // What the editor's `onChange` does with the mark, and the next key right after it, before SwiftUI's next update:
        // in the app SwiftUI brought the page's change to the text view about 30 ms later.
        editor.model.activeTextChanged()
        view.insertText(next[0])
        try await Task.sleep(for: .milliseconds(200))
        for key in next.dropFirst() { view.insertText(key) }
        try await Task.sleep(for: .milliseconds(200))
        let expected = String(typed.drop { $0 == "-" || $0 == "`" || $0 == " " }) + next.joined()
        #expect(view.text == expected)
        #expect(String(editor.model.activeText.characters) == expected)
        #expect(view.selectedRange == NSRange(location: expected.utf16.count, length: 0), "the caret isn't after the letters")
        await editor.turn()
    }

    /// The mark taken away in the editor's `onChange`, where the text view's report of it comes with SwiftUI's next
    /// update: the engine still gets the line without it, before it turns the line.
    @Test(.timeLimit(.minutes(1))) func theLineTurnsWithoutTheMark() async throws {
        let editor = try await Editor()
        defer { editor.close() }

        editor.view.insertText("- M")
        for _ in 0..<100 where editor.engine.converted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!editor.engine.converted.isEmpty, "the mark stays in the line")
        #expect(editor.engine.saved.map(\.plainText) == ["M"], "the line went to the engine with its mark")
        #expect(editor.view.text == "M")
        #expect(editor.view.selectedRange == NSRange(location: 1, length: 0))
        await editor.turn()
    }

    /// An empty paragraph being edited in `ActiveTextEditor`, focused in a window of its own. The engine turns the line
    /// only at `turn()`: until then the editor edits it where it is.
    @MainActor private final class Editor {
        let engine: FakeDocumentEngine
        let model: DocumentModel
        let view: UITextView
        private let window: UIWindow
        private var turns = false

        init() async throws {
            let line = PMNode(type: "paragraph", attrs: ["id": "a"])
            engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [line]))
            let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
            model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
            engine.sendDocument()
            let ref = NodeRef(path: [0], node: line)
            model.activate(ref, node: line)
            window = UIWindow(windowScene: try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene))
            window.rootViewController = UIHostingController(rootView: ActiveTextEditor(model: model, ref: ref, font: .body))
            window.makeKeyAndVisible()
            while model.editorTextView == nil { try await Task.sleep(for: .milliseconds(10)) }
            view = try #require(model.editorTextView)
            try #require(view.window === window, "another test's editor has the focus")
            // Weak: a test that ends early leaves the engine waiting, which then ends with the editor.
            engine.convertWaits = { [weak self] in
                while let self, !self.turns { try? await Task.sleep(for: .milliseconds(10)) }
            }
        }

        /// Lets the engine turn the line, and waits until the page is done with it.
        func turn() async {
            turns = true
            while model.isSwitchingByTyping { try? await Task.sleep(for: .milliseconds(10)) }
        }

        func close() {
            window.isHidden = true
        }
    }
}
