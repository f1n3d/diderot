import SwiftUI
import Testing
import WebKit
@testable import Diderot

/// The formula and diagram islands (`WebIslandView`): one scrolled away while it loads, and back, gets its height (code
/// review R49), and one built anew starts at the height it last had (R48).
struct WebIslandTests {
    /// An island scrolled away while its page loads, and back (code review R49): the render back in view measures, and
    /// the one scrolled away doesn't undo that. Depending on how far the page had loaded, the next render's wait for the
    /// page's events got the replaced load's failure, or the scrolled-away render's measurement failed once the page
    /// loaded anew. Either set the minimum height, which cut the formula off while it stayed in view.
    @Test(.timeLimit(.minutes(1)), arguments: [50, 600])
    func anIslandScrolledAwayWhileLoadingKeepsTheNextRendersHeight(awayMilliseconds: Int) async throws {
        let html = IslandHTML.math(#"\sum_{k=1}^{n} k^2 = \frac{n(n+1)(2n+1)}{6}"#, displayMode: true)
        let host = UIHostingController(rootView: ScrolledIsland(html: html, away: false))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        func height() -> CGFloat {
            window.layoutIfNeeded()
            return webViews(in: window).first?.bounds.height ?? 0
        }

        try await Task.sleep(for: .milliseconds(50))
        host.rootView = ScrolledIsland(html: html, away: true)
        try await Task.sleep(for: .milliseconds(awayMilliseconds))
        host.rootView = ScrolledIsland(html: html, away: false)
        #expect(await poll { height() > 48 }, "back in view, it renders and measures")
        try await Task.sleep(for: .seconds(2))
        #expect(height() > 48, "the render scrolled away leaves that height")
    }

    /// An island built anew (scrolled back into view) starts at the height it last had, for its content, width and text
    /// size (code review R48): at its minimum height it grew while it rendered, and what was below it jumped.
    @Test func anIslandBuiltAgainKeepsItsHeight() {
        let html = IslandHTML.math("x^{4711}", displayMode: true)
        WebIslandView.remember(120, of: html, width: 390, typeSize: .large)
        #expect(WebIslandView.lastHeight(of: html, width: 390, typeSize: .large) == 120)
        #expect(WebIslandView.lastHeight(of: html, width: 600, typeSize: .large) == nil)
        #expect(WebIslandView.lastHeight(of: html, width: 390, typeSize: .xxxLarge) == nil)
    }

    /// Polls `condition` while SwiftUI lays out (20 s at most: GitHub's runners start web processes slowly).
    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        [view as? WKWebView].compactMap(\.self) + view.subviews.flatMap(webViews)
    }
}

/// An island at the top of a long lazy list, scrolled to its end (`away`) and back: the list drops the island's view
/// and cancels its render, and keeps its state.
private struct ScrolledIsland: View {
    let html: String
    let away: Bool
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView {
            LazyVStack {
                WebIslandView(html: html, minHeight: 48)
                ForEach(0..<40, id: \.self) { _ in Color.clear.frame(height: 200) }
            }
        }
        .scrollPosition($position)
        .onChange(of: away) { position.scrollTo(edge: away ? .bottom : .top) }
    }
}
