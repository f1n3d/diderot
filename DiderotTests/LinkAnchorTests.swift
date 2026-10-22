import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// A link to `#anchor` scrolls to a view that exists: the footnote itself, else the top-level block around the target.
struct LinkAnchorTests {
    @Test func nestedTargetsScrollToTheirTopLevelBlock() {
        func heading(_ id: String) -> PMNode { PMNode(type: "heading", attrs: ["id": .string(id), "level": 2]) }
        let columns = PMNode(type: "columns", content: [
            PMNode(type: "column", content: [PMNode(type: "paragraph")]),
            PMNode(type: "column", content: [heading("incolumns")]),
        ])
        let reference = PMNode(type: "paragraph", content: [PMNode(type: "footnoteReference", attrs: ["data-id": "fnone"])])
        let footnotes = PMNode(type: "footnotes", content: [
            PMNode(type: "footnote", attrs: ["id": "fn:1", "data-id": "fnone"], content: [PMNode(type: "paragraph")]),
        ])
        let document = PMNode(type: "doc", content: [heading("top"), reference, columns, footnotes])

        #expect(PageView.scrollTarget(for: "top", in: document) == "top")
        #expect(PageView.scrollTarget(for: "incolumns", in: document) == "2")
        #expect(PageView.scrollTarget(for: "fnone", in: document) == "fn:1", "the footnote, not the paragraph that references it")
        #expect(PageView.scrollTarget(for: "missing", in: document) == nil)
    }

    /// An editable page (engine: drag and drop around every block) also reaches a block the lazy list hasn't built yet.
    @Test func reachesABlockNotBuiltYet() async throws {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let blocks = (0..<300).map { PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Block \($0)")]) }
        let model = DocumentModel(page: page, initialDocument: PMNode(type: "doc", content: blocks),
                                  engine: WebDocumentEngine(session: AppSession()), readOnlyReason: nil)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ScrollingDocument(model: model, target: "250"))
        window.isHidden = false
        defer { window.isHidden = true }

        func offset(_ view: UIView) -> CGFloat? { (view as? UIScrollView)?.contentOffset.y ?? view.subviews.lazy.compactMap(offset).first }
        func scrolled() -> Bool { (offset(window) ?? 0) > 2000 }
        for _ in 0..<100 where !scrolled() { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(scrolled())
    }
}

private struct ScrollingDocument: View {
    let model: DocumentModel
    let target: String
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView { DocumentBody(model: model) }
            .scrollPosition($position)
            .onAppear { position.scrollTo(id: target, anchor: .top) }
    }
}
