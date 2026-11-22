import SwiftUI
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

/// A file that downloads to open in Quick Look (an attachment, a database file) stops with the view it is for: the
/// attachments sheet or the entry's sheet closed, the page left. It ran on to its end, of any size, for a view that was
/// gone. A second tap on the page's card while it loads doesn't download the file again.
struct AttachmentDownloadTests {
    /// SwiftUI builds its accessibility tree only while assistive technology is on (`MediaBlockViewTests`).
    private static let accessibilityOn: Void = {
        let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let symbol = dlsym(handle, name) { unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1) }
        }
    }()

    init() { _ = Self.accessibilityOn }

    /// Two taps on the card while the file loads: one download. Each tap started one, and the second replaced the
    /// file under the first one's preview.
    @Test func aSecondTapOnTheCardDoesNotDownloadAgain() async throws {
        let server = URL(string: "https://card-taps.docmost.invalid")!
        let (window, _) = try show(try page(server: server))
        defer { window.isHidden = true }
        let card = try #require(await element(in: window) { $0.hasPrefix("Film.mov") })
        #expect(card.accessibilityActivate())
        #expect(card.accessibilityActivate())
        #expect(await poll { SlowFileURLProtocol.downloads(server).started > 0 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(SlowFileURLProtocol.downloads(server).started == 1)
    }

    /// Opening a subpage, or closing the page, stops the card's download; back on the page, the card says nothing of
    /// it and loads again on a tap.
    @Test func leavingThePageStopsTheDownload() async throws {
        let server = URL(string: "https://card-leave.docmost.invalid")!
        let navigation = ReaderNavigation()
        let content = try page(server: server)
        let (window, host) = try show(NavigationStack(path: Bindable(navigation).path) {
            content.navigationDestination(for: String.self) { Text($0) }
        })
        defer { window.isHidden = true }
        #expect(try #require(await element(in: window) { $0.hasPrefix("Film.mov") }).accessibilityActivate())
        #expect(await poll { SlowFileURLProtocol.downloads(server).started == 1 })

        navigation.path.append("Subpage")
        #expect(await poll { SlowFileURLProtocol.downloads(server).stopped == 1 }, "a subpage opened")
        navigation.path.removeLast()
        let card = try #require(await element(in: window) { $0.hasPrefix("Film.mov") })
        let failure = String(localized: "Something went wrong.")
        #expect(await !poll(tries: 10) { card.accessibilityLabel?.contains(failure) == true }, "no failure")

        #expect(card.accessibilityActivate())
        #expect(await poll { SlowFileURLProtocol.downloads(server).started == 2 })
        host.rootView = AnyView(Text("Closed"))
        #expect(await poll { SlowFileURLProtocol.downloads(server).stopped == 2 }, "the page closed")
    }

    /// Closing the attachments sheet stops the download it started: there, closing it is the only way to back out.
    @Test func closingTheAttachmentsStopsTheDownload() async throws {
        let server = URL(string: "https://attachments-close.docmost.invalid")!
        let session = try await signedIn(to: server)
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let (window, host) = try show(PageAttachmentsView(page: page, canDelete: false).environment(session))
        defer { window.isHidden = true }
        #expect(try #require(await element(in: window) { $0.hasPrefix("Film.mov") }).accessibilityActivate())
        #expect(await poll { SlowFileURLProtocol.downloads(server).started == 1 })

        host.rootView = AnyView(Text("Closed"))
        #expect(await poll { SlowFileURLProtocol.downloads(server).stopped == 1 })
        await Self.remove(server)
    }

    /// Closing an entry's sheet stops its file's download; a picker opened over its fields doesn't, though the fields
    /// disappear under it, as they do when scrolled away.
    @Test func closingTheEntryStopsTheDownload() async throws {
        let server = URL(string: "https://entry-close.docmost.invalid")!
        let session = try await signedIn(to: server)
        let pageId = "base-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "base.view.\(pageId)") }
        let model = BaseModel(pageId: pageId, session: session)
        await model.load()
        try #require(model.canEdit && model.row(id: "r1") != nil)
        let (window, host) = try show(BaseRowDetailSheet(model: model, route: BaseRowRoute(rowId: "r1"))
            .environment(session)
            .environment(ReaderNavigation()))
        defer { window.isHidden = true }
        #expect(try #require(await element(in: window) { $0.hasPrefix("Film.mov") }).accessibilityActivate())
        #expect(await poll { SlowFileURLProtocol.downloads(server).started == 1 })

        #expect(try #require(await element(in: window) { $0.hasPrefix("Status") }).accessibilityActivate())
        #expect(await poll { element(in: window as NSObject) { $0.hasPrefix("Film.mov") } == nil }, "the picker covers the fields")
        try await Task.sleep(for: .milliseconds(500))
        #expect(SlowFileURLProtocol.downloads(server).stopped == 0, "a picker opened")

        host.rootView = AnyView(Text("Closed"))
        #expect(await poll { SlowFileURLProtocol.downloads(server).stopped == 1 }, "the sheet closed")
        await Self.remove(server)
    }

    /// A page with an attachment, as the editor shows it; its file never loads.
    private func page(server: URL) throws -> some View {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let attachment = PMNode(type: "attachment", attrs: ["url": "/api/files/a1/Film.mov", "name": "Film.mov", "attachmentId": "a1"])
        let model = DocumentModel(page: page, initialDocument: PMNode(type: "doc", content: [attachment]), engine: nil, readOnlyReason: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowFileURLProtocol.self]
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, mediaLoader: MediaLoader(client: client), token: nil, pageId: "p")
        return ScrollView { DocumentBody(model: model) }.environment(\.renderContext, context)
    }

    /// Signed in to `server`, which `SlowFileURLProtocol` answers.
    private func signedIn(to server: URL) async throws -> AppSession {
        let store = SessionStore(keychain: MemorySecretStore())
        try store.save(StoredSession(serverURL: server, token: "t"))
        let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [SlowFileURLProtocol.self]))
        await session.restore()
        try #require(session.ready?.server.url == server)
        return session
    }

    private static func remove(_ server: URL) async {
        await DiskCache(scope: server.absoluteString).removeAll()
        TempFile.removeAll(server: server, uploads: true)
    }

    /// `view` in a window; the test closes it by replacing the host's view.
    private func show(_ view: some View) throws -> (UIWindow, UIHostingController<AnyView>) {
        let host = UIHostingController(rootView: AnyView(view))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }

    /// Polls `condition` while SwiftUI lays out (`tries` × 50 ms).
    private func poll(tries: Int = 200, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// The first element VoiceOver can reach in `window` whose label passes `matches`, once SwiftUI shows it.
    private func element(in window: UIWindow, _ matches: (String) -> Bool) async -> NSObject? {
        var found: NSObject?
        _ = await poll {
            window.layoutIfNeeded()
            found = element(in: window as NSObject, matches)
            return found != nil
        }
        return found
    }

    private func element(in element: NSObject, _ matches: (String) -> Bool) -> NSObject? {
        if let label = element.accessibilityLabel, matches(label) { return element }
        let children = element.accessibilityElements as? [NSObject] ?? (element as? UIView)?.subviews ?? []
        for child in children {
            if let found = self.element(in: child, matches) { return found }
        }
        return nil
    }
}

/// Answers the API as a server with a page that has an attachment, "Film.mov", and a database (with the license) whose
/// entry r1 holds it beside a select field; never answers for a file (a large one on a slow connection). Counts per server the file
/// downloads that began and those that were stopped.
private nonisolated final class SlowFileURLProtocol: URLProtocol, @unchecked Sendable {
    private static let counts = Mutex<[String: (started: Int, stopped: Int)]>([:])

    static func downloads(_ server: URL) -> (started: Int, stopped: Int) {
        counts.withLock { $0[server.host() ?? "", default: (0, 0)] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let path = url.path()
        if path.hasPrefix("/api/files/") {
            Self.counts.withLock { $0[host, default: (0, 0)].started += 1 }
            return
        }
        let body = switch path {
        case "/api/pages/attachments":
            #"{"data": {"items": [{"id": "a1", "fileName": "Film.mov", "fileSize": 400000000}], "meta": {"hasNextPage": false}}}"#
        case "/api/workspace/entitlements":
            #"{"data": {"tier": "business", "features": ["bases"]}}"#
        case "/api/bases/info":
            #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "pt", "name": "Title", "type": "text", "isPrimary": true}, {"id": "pf", "name": "Files", "type": "file"}, {"id": "ps", "name": "Status", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}]}}"#
        case "/api/bases/rows":
            #"{"data": {"items": [{"id": "r1", "cells": {"pf": [{"id": "f1", "fileName": "Film.mov", "fileSize": 400000000}]}}], "meta": {"hasNextPage": false}}}"#
        default:
            #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let url = request.url, let host = url.host(), url.path().hasPrefix("/api/files/") else { return }
        Self.counts.withLock { $0[host, default: (0, 0)].stopped += 1 }
    }
}
