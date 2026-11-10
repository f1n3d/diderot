import Foundation
import Synchronization
import Testing
import WebKit
@testable import Diderot

/// The web editor keeps page copies and the signed-in profile in a store per server, so signing out of one removes
/// exactly its data, also for a host without a public suffix (WebKit lists no records for those). A load that fails
/// says why instead of leaving the sheet empty.
struct WebEditorViewTests {
    private static let home = URL(string: "diderot-test://wiki/")!
    private static let pageURL = URL(string: "diderot-test://wiki/p/abc")!

    /// Offline, WebKit draws nothing: the load throws the reason for the sheet, and the page isn't asked for.
    @Test(.timeLimit(.minutes(1))) func aLoadThatFailsSaysWhy() async throws {
        let server = EditorServer()
        server.isOffline.withLock { $0 = true }
        let page = Self.editorPage(server)
        let error = await #expect(throws: (any Error).self) {
            try await WebEditorView.open(Self.pageURL, home: Self.home, in: page)
        }
        #expect((error as NSError?)?.domain == NSURLErrorDomain)
        #expect((error as NSError?)?.code == NSURLErrorNotConnectedToInternet)
        #expect(error?.userMessage == URLError(.notConnectedToInternet).localizedDescription)
        #expect(server.urls.withLock { $0 } == [Self.home])
    }

    /// "Try Again" in the same sheet: once the server answers, the editor opens on the page, its shell trimmed.
    @Test(.timeLimit(.minutes(1))) func theEditorOpensAfterAFailedLoad() async throws {
        let server = EditorServer()
        server.isOffline.withLock { $0 = true }
        let page = Self.editorPage(server)
        await #expect(throws: (any Error).self) { try await WebEditorView.open(Self.pageURL, home: Self.home, in: page) }

        server.isOffline.withLock { $0 = false }
        try await WebEditorView.open(Self.pageURL, home: Self.home, in: page)
        #expect(page.url == Self.pageURL)
        #expect(try await page.callJavaScript("return document.getElementById('docmost-ios-style') !== null") as? Bool == true)
    }

    private static func editorPage(_ server: EditorServer) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.urlSchemeHandlers[URLScheme("diderot-test")!] = server
        return WebPage(configuration: configuration)
    }

    /// A server that sends the editor elsewhere (a sign-in in front of it): the editor's limit stops that load, which
    /// WebKit calls "Frame load interrupted". The sheet names the address and the way out instead.
    @Test func aRedirectElsewhereIsNamed() {
        let elsewhere = URL(string: "https://auth.example.com/login?next=%2F")!
        let stopped = NSError(domain: "WebKitErrorDomain", code: 102, userInfo: [
            NSURLErrorFailingURLErrorKey: elsewhere, NSLocalizedDescriptionKey: "Frame load interrupted",
        ])
        #expect(WebEditorView.reason(stopped) as? WebEditorView.RedirectedAway == .init(address: "https://auth.example.com"))
        #expect(WebEditorView.reason(stopped).userMessage.contains("https://auth.example.com"))
        // The server's own host on another port is another address: the port tells them apart.
        let otherPort = NSError(domain: "WebKitErrorDomain", code: 102, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://wiki.local:9000/login")!])
        #expect(WebEditorView.reason(otherPort) as? WebEditorView.RedirectedAway == .init(address: "http://wiki.local:9000"))
        // Any other failure keeps its own words.
        let offline = URLError(.notConnectedToInternet)
        #expect(WebEditorView.reason(offline) as? URLError == offline)
        let other = NSError(domain: "WebKitErrorDomain", code: 101, userInfo: [NSURLErrorFailingURLErrorKey: elsewhere])
        #expect(WebEditorView.reason(other) as NSError == other)
    }

    @Test func signingOutRemovesExactlyThatServersData() async throws {
        let defaults = Self.defaults("removal")
        let local = URL(string: "http://docmost.local:3000")!, wiki = URL(string: "https://wiki.example.com")!
        for url in [local, wiki] {
            #expect(try await storedValue(at: url, defaults: defaults, setting: "v") == "v")
        }

        await WebEditorStores.remove(for: local, defaults: defaults)
        #expect(try await storedValue(at: local, defaults: defaults) == nil)
        #expect(try await storedValue(at: wiki, defaults: defaults) == "v")

        await WebEditorStores.remove(for: wiki, defaults: defaults)
        #expect(try await storedValue(at: wiki, defaults: defaults) == nil)
    }

    /// Each server keeps its store across launches; the address is compared as the sign-ins compare it.
    /// iPad windows share a server's store: its auth cookie goes with the last editor closed there, not with the first,
    /// while another window still saves a drawing with it.
    @Test func cookieGoesWithTheLastEditorOfAStore() {
        let store = UUID()
        WebEditorStores.editorOpened(store)
        WebEditorStores.editorOpened(store)
        #expect(!WebEditorStores.editorClosed(store))
        #expect(WebEditorStores.editorClosed(store))
        #expect(WebEditorStores.editorClosed(UUID()), "one never counted")
    }

    @Test func eachServerKeepsItsOwnStore() {
        let defaults = Self.defaults("identifiers")
        let a = WebEditorStores.identifier(for: URL(string: "https://a.example.com")!, defaults: defaults)
        let b = WebEditorStores.identifier(for: URL(string: "https://b.example.com")!, defaults: defaults)
        #expect(a != b)
        #expect(WebEditorStores.identifier(for: URL(string: "https://A.example.com/")!, defaults: defaults) == a)
    }

    private static func defaults(_ name: String) -> UserDefaults {
        let suite = "WebEditorViewTests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    /// Loads `url` with the server's store and returns its `localStorage` value, set first to `value` if given.
    private func storedValue(at url: URL, defaults: UserDefaults, setting value: String? = nil) async throws -> String? {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: WebEditorStores.identifier(for: url, defaults: defaults))
        let page = WebPage(configuration: configuration)
        for try await _ in page.load(html: "<p></p>", baseURL: url) {}
        if let value {
            _ = try await page.callJavaScript("localStorage.setItem('k', value)", arguments: ["value": value])
        }
        return try await page.callJavaScript("return localStorage.getItem('k')") as? String
    }
}

/// Stands in for a Docmost server: the home page caches the signed-in user and a page has the web client's shell, or
/// every request fails as on a device that is offline. Remembers what was asked for.
private nonisolated final class EditorServer: URLSchemeHandler, Sendable {
    let isOffline = Mutex(false)
    let urls = Mutex<[URL]>([])

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        let url = request.url ?? URL(string: "diderot-test://unknown/")!
        urls.withLock { $0.append(url) }
        let isOffline = isOffline.withLock { $0 }
        return AsyncThrowingStream { continuation in
            guard !isOffline else { return continuation.finish(throwing: URLError(.notConnectedToInternet)) }
            let html = url.path.hasPrefix("/p/")
                ? "<div class='mantine-AppShell-main'></div>"
                : "<script>localStorage.setItem('currentUser', '{}')</script>"
            let data = Data(html.utf8)
            continuation.yield(.response(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }
}
