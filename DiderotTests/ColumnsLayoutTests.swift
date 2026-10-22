import SwiftUI
import Testing
import WebKit
import DocmostKit
@testable import Diderot

/// Rotating a large iPhone or resizing an iPad window flips columns between side by side and stacked; their content
/// (loaded media, web islands, open toggles, the cursor) must stay, not be rebuilt.
struct ColumnsLayoutTests {
    private let columns = PMNode(type: "columns", content: [
        PMNode(type: "column", content: [PMNode(type: "mathBlock", attrs: ["text": "x^2"])]),
        PMNode(type: "column"),
    ])

    @Test func readerKeepsColumnContent() async throws {
        let block = try #require(ContentParser.parse(PMNode(type: "doc", content: [columns])).blocks.first)
        try await expectSameIsland(in: BlockView(block: block))
    }

    @Test func editorKeepsColumnContent() async throws {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: nil, readOnlyReason: .noPermission)
        try await expectSameIsland(in: ColumnsNodeView(model: model, node: columns, ref: NodeRef(path: [0], node: columns)))
    }

    /// Shows `content` at regular, then compact width; the math island must keep its web view.
    private func expectSameIsland(in content: some View) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content)
        host.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let half = window.bounds.width / 2

        let sideBySide = try #require(await webView(in: window) { $0.bounds.width < half })
        host.traitOverrides.horizontalSizeClass = .compact
        let stacked = try #require(await webView(in: window) { $0.bounds.width > half })
        #expect(stacked === sideBySide)
    }

    /// The first web view in `view` that matches, polled while SwiftUI lays out (up to 5 s).
    private func webView(in view: UIView, where matches: (WKWebView) -> Bool) async -> WKWebView? {
        for _ in 0..<100 {
            view.layoutIfNeeded()
            if let match = webViews(in: view).first(where: matches) { return match }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap(webViews)
    }
}
