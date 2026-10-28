import Foundation
import Testing
import WebKit
@testable import Diderot

/// The web editor keeps page copies and the signed-in profile in a store per server, so signing out of one removes
/// exactly its data, also for a host without a public suffix (WebKit lists no records for those).
struct WebEditorViewTests {
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
