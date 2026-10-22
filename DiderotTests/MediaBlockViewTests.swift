import AVKit
import SwiftUI
import Synchronization
import Testing
import WebKit
import DocmostKit
@testable import Diderot

/// A PDF or diagram shows the spinner while it loads, not "could not be loaded": when it loads again after failing
/// offline, and after a cancelled download. Scrolling past it or leaving the page cancels one; here a new file does.
struct MediaBlockViewTests {
    /// SwiftUI builds its accessibility tree only while assistive technology is on, so `labels(in:)` finds nothing
    /// on a simulator that never had it. Turns it on for this process as XCUITest does (private, test target only).
    private static let accessibilityOn: Void = {
        let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let symbol = dlsym(handle, name) { unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1) }
        }
    }()

    init() { _ = Self.accessibilityOn }

    @Test(arguments: ["pdf", "drawio"])
    func showsTheSpinnerWhileLoading(type: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowURLProtocol.self]
        let server = URL(string: "https://wiki.example.com")!
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, imageLoader: ImageLoader(client: client), token: nil, pageId: nil)
        func media(_ file: String) throws -> some View {
            let doc = PMNode(type: "doc", content: [PMNode(type: type, attrs: ["src": .string("/api/files/\(file)")])])
            return BlockView(block: try #require(ContentParser.parse(doc).blocks.first)).environment(\.renderContext, context)
        }
        let host = UIHostingController(rootView: try media("offline"))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(spinner(in: window))
        #expect(await poll { !spinner(in: window) }, "offline: could not be loaded")

        host.rootView = try media("a")
        #expect(await poll { spinner(in: window) }, "loads again")

        host.rootView = try media("b")
        try await Task.sleep(for: .milliseconds(300))
        #expect(spinner(in: window), "the cancelled download of a is no failure")
    }

    /// Going back from a page opened here shows the block again, as it was: no new download (a PDF stays on its page),
    /// no spinner (a formula doesn't flash), the same player (a paused video keeps its place). Lists refresh without
    /// the spinner; here the server answers only once. Only a player that failed to load (offline) is replaced, to
    /// retry: here the audio's file is missing, the video's exists. The video's readiness isn't awaited: on the
    /// simulator it waits for the Mac's audio output, which sometimes stalls.
    @Test(arguments: [("pdf", 1), ("drawio", 1), ("mathBlock", 0), ("video", 0), ("audio", 0), ("subpages", 2), ("transclusionReference", 2)])
    func keepsItsContentOnReturn(type: String, requests: Int) async throws {
        let server = URL(string: "https://\(type).docmost.invalid")!
        OnceURLProtocol.requests.withLock { $0[server.host()!] = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnceURLProtocol.self]
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, imageLoader: ImageLoader(client: client), token: nil, pageId: "p")
        let file = URL.temporaryDirectory.appending(path: "\(type).caf")
        if type == "video" {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
            let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
            silence.frameLength = 800
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: silence)
        }
        let media = type == "video" || type == "audio"
        let node = PMNode(type: type, attrs: ["src": .string(media ? file.absoluteString : "/api/files/f/\(type)"), "text": .string("x^2"),
                                              "sourcePageId": .string("s"), "transclusionId": .string("t")])
        let block = try #require(ContentParser.parse(PMNode(type: "doc", content: [node])).blocks.first)
        let navigation = ReaderNavigation()
        var appearances = 0
        var disappearances = 0
        let host = UIHostingController(rootView: NavigationStack(path: Bindable(navigation).path) {
            BlockView(block: block)
                .onAppear { appearances += 1 }
                .onDisappear { disappearances += 1 }
                .navigationDestination(for: String.self) { Text($0) }
        }
        .environment(\.renderContext, context)
        .environment(navigation))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(await poll {
            appearances == 1 && !spinner(in: window) && players(in: host).count == (media ? 1 : 0)
                && players(in: host).allSatisfy { ($0.currentItem?.status == .failed) == (type == "audio") }
        })
        let before = players(in: host)
        // A re-rendered formula or diagram loads a new page without this mark; its spinner can flash between polls.
        let islands = webViews(in: window)
        for island in islands { _ = try await island.evaluateJavaScript("window.kept = true") }

        navigation.path.append("Subpage")
        #expect(await poll { disappearances == 1 })
        navigation.path.removeLast()
        #expect(await poll { appearances == 2 })
        #expect(await !poll(tries: 20) { spinner(in: window) }, "no spinner")
        for island in islands { #expect(try await island.evaluateJavaScript("window.kept === true") as? Bool == true, "not rendered again") }
        #expect((players(in: host) == before) == (type != "audio"), "same player, unless it failed to load")
        #expect(OnceURLProtocol.requests.withLock { $0[server.host()!, default: 0] } == requests)
    }

    /// When an edit above shifts the blocks, another synced block takes this one's place: it shows the spinner while
    /// loading, not the previous one's content. One without an id says so at once, without a spinner.
    @Test(arguments: ["b", nil])
    func syncedBlockInAnotherPlaceStartsOver(id: String?) async throws {
        let server = URL(string: "https://synced\(id ?? "").docmost.invalid")!
        OnceURLProtocol.requests.withLock { $0[server.host()!] = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnceURLProtocol.self]
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, imageLoader: ImageLoader(client: client), token: nil, pageId: "p")
        func reference(_ id: String?) -> some View {
            TransclusionReferenceView(sourcePageId: "s", transclusionId: id).environment(\.renderContext, context)
        }
        let host = UIHostingController(rootView: reference("a"))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(spinner(in: window))
        #expect(await poll { !spinner(in: window) }, "a loaded")

        host.rootView = reference(id)
        #expect(await poll(tries: 20) { spinner(in: window) } == (id != nil), "b loads, an incomplete one doesn't")
        #expect(labels(in: window).contains(String(localized: "Synced block reference is incomplete.")) == (id == nil))
    }

    /// A formula is blank after its web process ended (iOS reclaimed its memory in the background, a crash). Coming
    /// back into view renders it again.
    @Test func formulaRendersAgainAfterItsWebProcessEnded() async throws {
        let navigation = ReaderNavigation()
        var appearances = 0
        var disappearances = 0
        let host = UIHostingController(rootView: NavigationStack(path: Bindable(navigation).path) {
            MathBlockView(latex: "x^2")
                .onAppear { appearances += 1 }
                .onDisappear { disappearances += 1 }
                .navigationDestination(for: String.self) { Text($0) }
        })
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(await poll { appearances == 1 && !spinner(in: window) })
        let island = try #require(webViews(in: window).first)
        // WebKit's private test hook; only the tests call it.
        let kill = NSSelectorFromString("_killWebContentProcess")
        try #require(island.responds(to: kill))
        island.perform(kill)
        try #require(await poll { island.url == nil }, "blank")

        navigation.path.append("Subpage")
        #expect(await poll { disappearances == 1 })
        navigation.path.removeLast()
        #expect(await poll { appearances == 2 })
        #expect(await poll { island.url != nil && !spinner(in: window) }, "rendered again")
        #expect(try await island.evaluateJavaScript("document.querySelector('.katex') !== null") as? Bool == true)
    }

    /// VoiceOver reads a Mermaid diagram's "Show source" button and the message of a diagram or image that could not
    /// be loaded, not the block's name: that names only the diagram or image itself.
    @Test func blockNameLabelsOnlyTheDiagramOrImage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowURLProtocol.self]
        let server = URL(string: "https://wiki.example.com")!
        // The diagram's and the image's files fail offline.
        let loader = ImageLoader(client: APIClient(baseURL: server, configuration: configuration))
        let context = RenderContext(baseURL: server, client: nil, imageLoader: loader, token: nil, pageId: nil)
        let doc = PMNode(type: "doc", content: [
            PMNode(type: "codeBlock", attrs: ["language": .string("mermaid")], content: [PMNode(type: "text", text: "graph TD; A-->B")]),
            PMNode(type: "drawio", attrs: ["src": .string("/api/files/offline"), "title": .string("Architecture")]),
            PMNode(type: "image", attrs: ["src": .string("/api/files/offline"), "alt": .string("Photo")]),
        ])
        let host = UIHostingController(rootView: ContentDocumentView(document: ContentParser.parse(doc)).environment(\.renderContext, context))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let expected = [String(localized: "Mermaid diagram"), String(localized: "Show source"),
                        String(localized: "Diagram could not be loaded."), String(localized: "Image unavailable")]
        #expect(await poll { Set(labels(in: window)).isSuperset(of: expected) }, "\(labels(in: window))")
    }

    /// Polls `condition` while SwiftUI lays out (`tries` × 50 ms, 5 s by default).
    private func poll(tries: Int = 100, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func spinner(in view: UIView) -> Bool {
        view.layoutIfNeeded()
        return view is UIActivityIndicatorView || view.subviews.contains { spinner(in: $0) }
    }

    private func players(in controller: UIViewController) -> [AVPlayer] {
        [(controller as? AVPlayerViewController)?.player].compactMap(\.self) + controller.children.flatMap(players)
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        [view as? WKWebView].compactMap(\.self) + view.subviews.flatMap(webViews)
    }

    /// The accessibility labels VoiceOver can reach from `element`.
    private func labels(in element: NSObject) -> [String] {
        let children = element.accessibilityElements as? [NSObject] ?? (element as? UIView)?.subviews ?? []
        return [element.accessibilityLabel].compactMap(\.self) + children.flatMap(labels)
    }
}

/// Fails the file `offline`, never answers for others (a large file on a slow connection).
private nonisolated final class SlowURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.lastPathComponent == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}
}

/// Answers the first request to each server (a PDF, an SVG, subpages or a synced block), then never again, like a
/// connection that dropped. Counts the requests per server.
private nonisolated final class OnceURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              Self.requests.withLock({ $0[host, default: 0] += 1; return $0[host] == 1 }) else { return }
        let body = switch url.lastPathComponent {
        case "pdf": "%PDF-1.4\n1 0 obj <</Type /Catalog /Pages 2 0 R>> endobj\n2 0 obj <</Type /Pages /Kids [3 0 R] /Count 1>> endobj\n3 0 obj <</Type /Page /Parent 2 0 R /MediaBox [0 0 100 100]>> endobj\ntrailer <</Root 1 0 R>>"
        case "drawio": #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#
        case "sidebar-pages": #"{"data": {"items": [{"id": "c", "title": "Child"}], "meta": {"hasNextPage": false}}}"#
        default: #"{"data": {"items": [{"content": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Synced"}]}]}}]}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
