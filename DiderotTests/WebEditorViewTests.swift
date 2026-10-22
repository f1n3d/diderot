import Foundation
import Testing
import WebKit
@testable import Diderot

/// The web editor's store keeps page copies and the signed-in profile, so removing a server must reach its data.
struct WebEditorViewTests {
    /// WebKit lists no record for a host without a public suffix, which self-hosted servers often have.
    @Test func removeDataReachesHostsWithoutPublicSuffix() async throws {
        let local = URL(string: "http://docmost.local:3000")!, wiki = URL(string: "https://wiki.example.com")!
        for url in [local, wiki] {
            #expect(try await storedValue(at: url, setting: "v") == "v")
        }

        await WebEditorView.removeData(keepingHosts: ["wiki.example.com"])
        #expect(try await storedValue(at: wiki) == "v")

        await WebEditorView.removeData(keepingHosts: [])
        #expect(try await storedValue(at: local) == nil)
        #expect(try await storedValue(at: wiki) == nil)
    }

    /// Loads `url` with the editor's store and returns its `localStorage` value, set first to `value` if given.
    private func storedValue(at url: URL, setting value: String? = nil) async throws -> String? {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: WebEditorView.storeIdentifier)
        let page = WebPage(configuration: configuration)
        for try await _ in page.load(html: "<p></p>", baseURL: url) {}
        if let value {
            _ = try await page.callJavaScript("localStorage.setItem('k', value)", arguments: ["value": value])
        }
        return try await page.callJavaScript("return localStorage.getItem('k')") as? String
    }
}
