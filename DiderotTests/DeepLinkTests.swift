import Foundation
import Testing
@testable import Diderot

struct DeepLinkTests {
    private let server = URL(string: "https://wiki.example.com")!

    @Test func unwrapsCustomScheme() {
        let url = URL(string: "diderot://open?url=https%3A%2F%2Fwiki.example.com%2Fs%2Fdemo%2Fp%2Fhandbuch-Ab12Cd34Ef")!
        #expect(DeepLink.webURL(from: url)?.absoluteString == "https://wiki.example.com/s/demo/p/handbuch-Ab12Cd34Ef")
        #expect(DeepLink.resolve(url, serverURL: server) == .page(slugId: "Ab12Cd34Ef", anchor: nil))
    }

    @Test func acceptsPlainWebURLs() {
        let url = URL(string: "https://wiki.example.com/p/Ab12Cd34Ef#top")!
        #expect(DeepLink.resolve(url, serverURL: server) == .page(slugId: "Ab12Cd34Ef", anchor: "top"))
    }

    @Test func rejectsOtherLinks() {
        #expect(DeepLink.webURL(from: URL(string: "diderot://something")!) == nil)
        #expect(DeepLink.webURL(from: URL(string: "mailto:a@b.c")!) == nil)
        let foreign = URL(string: "https://example.org/s/x/p/y-Zz99Yy88Xx")!
        #expect(DeepLink.resolve(foreign, serverURL: server) == .external(foreign))
    }

    @MainActor
    @Test func navigationStoresPendingSelection() {
        let navigation = AppNavigation()
        #expect(navigation.open(URL(string: "https://wiki.example.com/p/Ab12Cd34Ef")!, serverURL: server))
        #expect(navigation.pendingSelection?.pageId == "Ab12Cd34Ef")
        #expect(!navigation.open(URL(string: "https://example.org")!, serverURL: server))
    }
}
