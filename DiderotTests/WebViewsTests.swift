import Foundation
import Testing
import WebKit
@testable import Diderot

/// The app's web views by role (`WebViews`): the data they keep, the scripts they run and where they may go.
struct WebViewsTests {
    private let server = URL(string: "https://wiki.example.com")!

    /// The islands and the diagram viewer keep no website data, and the viewer's page runs no scripts.
    @Test func islandsKeepNothing() {
        #expect(!WebViews.islandStore.isPersistent)
        let viewer = WebViews.diagramViewer()
        #expect(!viewer.view.configuration.websiteDataStore.isPersistent)
        #expect(!viewer.view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    /// The diagram viewer stays on its page: a navigation away doesn't happen. It had no limit, and its web view
    /// went wherever its page led.
    @Test(.timeLimit(.minutes(1))) func diagramViewerStaysOnItsPage() async throws {
        let viewer = WebViews.diagramViewer()
        viewer.view.loadHTMLString(IslandHTML.svg("<svg xmlns='http://www.w3.org/2000/svg'/>", zoomable: true), baseURL: IslandHTML.baseURL)
        for _ in 0..<200 where viewer.view.url == nil || viewer.view.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        #expect(viewer.view.url?.isFileURL == true)
        _ = try await viewer.view.evaluateJavaScript("location.href = 'about:blank'; true")
        try await Task.sleep(for: .seconds(1))
        #expect(viewer.view.url?.isFileURL == true)
    }

    /// Signed-in views keep nothing but the web editor's IndexedDB; connecting an integration passes other services'
    /// sign-in pages with their frames, the web layout stays on the page's.
    @Test func rolesSetTheirLimits() {
        let connect = WebViews.integrationConnect(server: server)
        #expect(connect.limit.reach == .web && connect.limit.frames)
        #expect(!connect.dataStore.isPersistent)
        let layout = WebViews.webLayout(server: server)
        #expect(layout.limit.reach == .page && layout.limit.frames)
        #expect(!layout.dataStore.isPersistent)
        #expect(!WebViews.browserSignIn().dataStore.isPersistent)
    }
}
