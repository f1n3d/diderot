import Foundation
import Synchronization
import Testing
import WebKit
@testable import Diderot

/// Web views stay on the pages the app loads into them: a tapped link goes outside, frames load only where allowed,
/// and formula and diagram islands reach nothing beyond their bundled files.
struct WebNavigationLimitTests {
    private let server = URL(string: "https://wiki.example.com")!

    @Test func decidesWhereAWebViewMayGo() {
        func decide(_ url: String, acrossOrigin: Bool = false, frames: Bool = false, mainFrame: Bool? = true,
                    linkTap: Bool = false) -> WebNavigationLimit.Decision {
            WebNavigationLimit.decision(for: URL(string: url)!, home: server, acrossOrigin: acrossOrigin, frames: frames,
                                        mainFrame: mainFrame, linkTap: linkTap)
        }
        // Its own page, also at an anchor; nowhere else, and a tapped link goes outside.
        #expect(decide("https://wiki.example.com/") == .allow)
        #expect(decide("https://wiki.example.com#top") == .allow)
        #expect(decide("https://wiki.example.com/p/abc") == .cancel)
        #expect(decide("https://evil.example.com/") == .cancel)
        #expect(decide("https://evil.example.com/", linkTap: true) == .openOutside)
        // The web editor: the server's pages, not another scheme or port.
        #expect(decide("https://wiki.example.com/p/abc", acrossOrigin: true) == .allow)
        #expect(decide("https://WIKI.example.com:443/p/abc", acrossOrigin: true) == .allow)
        #expect(decide("http://wiki.example.com/p/abc", acrossOrigin: true) == .cancel)
        #expect(decide("https://wiki.example.com:8443/", acrossOrigin: true, linkTap: true) == .openOutside)
        // Frames only where allowed; a new window goes outside.
        #expect(decide("https://www.youtube-nocookie.com/embed/x", mainFrame: false) == .cancel)
        #expect(decide("https://www.youtube-nocookie.com/embed/x", frames: true, mainFrame: false) == .allow)
        #expect(decide("https://example.com/", mainFrame: nil) == .openOutside)
    }

    /// WebKit asks before it loads: a frame, or a script leaving the page, never sends a request.
    @Test func framesAndNavigationsAwayDontLoad() async throws {
        let home = URL(string: "diderot-test://home/")!
        func requests(frames: Bool) async throws -> [String] {
            let log = RequestLog()
            var configuration = WebPage.Configuration()
            configuration.urlSchemeHandlers[URLScheme("diderot-test")!] = log
            let page = WebPage(configuration: configuration, navigationDecider: WebNavigationLimit(home: home, frames: frames))
            for try await _ in page.load(html: "<iframe src='diderot-test://frame/'></iframe>", baseURL: home) {}
            _ = try await page.callJavaScript("location.href = 'diderot-test://away/'; return true")
            try await Task.sleep(for: .seconds(1))
            return log.urls.withLock { $0.map(\.absoluteString) }
        }
        #expect(try await requests(frames: false).isEmpty)
        #expect(try await requests(frames: true) == ["diderot-test://frame/"])
    }

    /// The web client opens links with `window.open`, which WebKit drops in these web views: the limit hands them
    /// outside instead, resolved against the page.
    @Test func windowOpenGoesOutside() async throws {
        let limit = WebNavigationLimit(home: server, acrossOrigin: true, frames: true)
        var opened: [URL] = []
        limit.openOutside = { opened.append($0) }
        var configuration = WebPage.Configuration()
        limit.catchesWindowOpen(in: &configuration)
        let page = WebPage(configuration: configuration, navigationDecider: limit)
        for try await _ in page.load(html: "<p></p>", baseURL: server) {}
        _ = try await page.callJavaScript("window.open('/p/abc', '_blank', 'noopener,noreferrer'); return true")
        for _ in 0..<20 where opened.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(opened == [URL(string: "https://wiki.example.com/p/abc")!])
    }

    /// Under their content security policy, the islands still render (bundled script, styles and fonts), but
    /// neither a request nor an image reaches anywhere else; without it, the same script would.
    @Test func islandsReachNothingBeyondTheBundle() async throws {
        let reachOut = "fetch('diderot-test://fetch/').catch(() => {}); new Image().src = 'diderot-test://image/'; return true"
        func requests(_ html: String, until rendered: String) async throws -> [String] {
            let log = RequestLog()
            var configuration = WebPage.Configuration()
            configuration.urlSchemeHandlers[URLScheme("diderot-test")!] = log
            let page = WebPage(configuration: configuration)
            for try await _ in page.load(html: html, baseURL: IslandHTML.baseURL) {}
            var done = false
            for _ in 0..<50 where !done {
                done = try await page.callJavaScript("return \(rendered)") as? Bool == true
                if !done { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(done, "Not rendered: \(rendered)")
            _ = try await page.callJavaScript(reachOut)
            try await Task.sleep(for: .seconds(1))
            return log.urls.withLock { $0.map(\.absoluteString).sorted() }
        }
        #expect(try await requests("<p></p>", until: "true") == ["diderot-test://fetch/", "diderot-test://image/"])
        #expect(try await requests(IslandHTML.math("x^2", displayMode: true), until: "document.querySelector('.katex') !== null").isEmpty)
        #expect(try await requests(IslandHTML.mermaid("graph TD; A-->B"), until: "document.querySelector('#d svg') !== null").isEmpty)
    }
}

/// Answers every request with an empty page and remembers its URL.
private nonisolated final class RequestLog: URLSchemeHandler, Sendable {
    let urls = Mutex<[URL]>([])

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        let url = request.url ?? URL(string: "diderot-test://unknown/")!
        urls.withLock { $0.append(url) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(URLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: "utf-8")))
            continuation.finish()
        }
    }
}
