import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// The page's one editor (`PageEditor`) lies where the active block's hidden copy of its text (`EditorSlot`) reports
/// (`editorFrame`), and the copy takes the height the editor draws the text at (`editorHeight`): the blocks below then
/// move as the text grows. A text block and a code block both report it, an empty one with a line's height; the keyboard
/// centering and the caret go by it.
@MainActor @Suite(.serialized) struct EditorSlotTests {
    @Test(arguments: [("paragraph", "Hello"), ("paragraph", ""), ("codeBlock", "let a = 1\nlet b = 2"), ("codeBlock", "")])
    func activeBlockReportsTheEditorsPlace(type: String, text: String) async throws {
        let block = PMNode(type: type, attrs: type == "paragraph" ? ["id": "a"] : [:],
                           content: text.isEmpty ? nil : [PMNode(type: "text", text: text)])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [block]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let ref = NodeRef(path: [0], node: block)
        model.activate(ref, node: block)
        try #require(model.active?.ref == ref)

        let window = UIWindow(windowScene: try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 40)
            if type == "codeBlock" {
                CodeNodeView(model: model, node: block, ref: ref)
            } else {
                TextNodeView(model: model, node: block, ref: ref, isEditing: true)
            }
            Spacer(minLength: 0)
        }.coordinateSpace(.named(DocumentModel.documentSpace)))
        window.isHidden = false
        defer { window.isHidden = true }

        /// The place reported for the block once its height is `height`, or the last one reported (up to 2 s).
        func place(height: ((CGFloat) -> Bool)? = nil) async throws -> CGRect? {
            for _ in 0..<200 {
                window.layoutIfNeeded()
                if let place = model.editorFrame, place.ref == ref, height?(place.frame.height) ?? true { return place.frame }
                try await Task.sleep(for: .milliseconds(10))
            }
            return model.editorFrame?.ref == ref ? model.editorFrame?.frame : nil
        }

        let natural = try #require(try await place(), "the block didn't report where the editor lies")
        #expect(natural.height > 10, "an empty block's place needs a line's height: \(natural)")
        #expect(natural.minY >= 40, "not in the document's space: \(natural)")
        #expect(natural.width > window.bounds.width / 2, "the editor gets the block's width: \(natural)")

        // The height the editor draws the text at, which the copy takes.
        model.editorHeight = (ref, 321)
        let drawn = try #require(try await place { $0 == 321 })
        #expect(drawn.height == 321)
        #expect(drawn.minX == natural.minX && drawn.minY == natural.minY && drawn.width == natural.width)

        // Another block's height (the block the editor lay on before) leaves this one at its own.
        let other = PMNode(type: "paragraph", attrs: ["id": "b"])
        model.editorHeight = (NodeRef(path: [1], node: other), 500)
        let own = try #require(try await place { $0 != 321 })
        #expect(own.height == natural.height)
    }
}
