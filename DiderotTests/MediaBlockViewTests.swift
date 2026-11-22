import AVKit
import ImageIO
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers
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

    @Test(arguments: ["pdf", "drawio", "image"])
    func showsTheSpinnerWhileLoading(type: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowURLProtocol.self]
        let server = URL(string: "https://wiki.example.com")!
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, mediaLoader: MediaLoader(client: client), token: nil, pageId: nil)
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
        let context = RenderContext(baseURL: server, client: client, mediaLoader: MediaLoader(client: client), token: nil, pageId: "p")
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

    /// Audio and video play with the Ring/Silent switch on, as in Safari (code review R53): the default category
    /// (`.soloAmbient`) muted them. The player sets `.playback`, which the switch doesn't mute, before it can start.
    /// One case after the other: they share the app's audio session, and one's reset fell between the other's player
    /// and its check (seen on November 10, 2026).
    @Test(.serialized, arguments: ["video", "audio"])
    func mediaPlaysWithTheSilentSwitchOn(type: String) async throws {
        try AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        let server = URL(string: "https://silent-switch.docmost.invalid")!
        let context = RenderContext(baseURL: server, client: nil, mediaLoader: nil, token: nil, pageId: nil)
        let file = URL.temporaryDirectory.appending(path: "silent-switch-\(type).caf")
        let block = try #require(ContentParser.parse(PMNode(type: "doc", content: [PMNode(type: type, attrs: ["src": .string(file.absoluteString)])])).blocks.first)
        let host = UIHostingController(rootView: BlockView(block: block).environment(\.renderContext, context))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(await poll { players(in: host).count == 1 })
        #expect(AVAudioSession.sharedInstance().category == .playback)
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
        let context = RenderContext(baseURL: server, client: client, mediaLoader: MediaLoader(client: client), token: nil, pageId: "p")
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

    /// A synced block that contains itself (here through columns, as one pasted into its own column) loads once and says
    /// so inside, where it loaded and nested forever and the page hung.
    @Test func syncedBlockInsideItselfLoadsOnce() async throws {
        let server = URL(string: "https://selfsynced.docmost.invalid")!
        SelfReferenceURLProtocol.requests.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelfReferenceURLProtocol.self]
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, mediaLoader: MediaLoader(client: client), token: nil, pageId: "p")
        let host = UIHostingController(rootView: TransclusionReferenceView(sourcePageId: "s", transclusionId: "t").environment(\.renderContext, context))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        #expect(await poll { labels(in: window).contains(String(localized: "This synced block contains itself.")) })
        try await Task.sleep(for: .seconds(1))
        #expect(SelfReferenceURLProtocol.requests.withLock { $0 } == 1)
    }

    /// A subpages block where no page is open, as in a template's preview, says there are none, as the web does, and
    /// asks the server nothing. It showed a spinner that never ended.
    @Test func subpagesWithoutAPageSaySo() async throws {
        let server = URL(string: "https://nopage-subpages.docmost.invalid")!
        OnceURLProtocol.requests.withLock { $0[server.host()!] = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnceURLProtocol.self]
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, mediaLoader: MediaLoader(client: client), token: nil, pageId: nil)
        let block = try #require(ContentParser.parse(PMNode(type: "doc", content: [PMNode(type: "subpages")])).blocks.first)
        let host = UIHostingController(rootView: BlockView(block: block).environment(\.renderContext, context).environment(ReaderNavigation()))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        #expect(await poll(tries: 200) { labels(in: window).contains(String(localized: "No subpages.")) }, "\(labels(in: window))")
        #expect(!spinner(in: window))
        #expect(OnceURLProtocol.requests.withLock { $0[server.host()!] } == nil)
    }

    /// A file a collaborator is still uploading (the web puts its node in without the file) says so with its name and a
    /// spinner, as the web does, and there is nothing to tap. A PDF said it could not be loaded, which a tap couldn't
    /// help, video and audio "Media unavailable.", and a tap on an attachment did nothing. Once the file has come, it
    /// shows.
    @Test(arguments: ["pdf", "video", "audio", "attachment"])
    func aCollaboratorsUploadSaysSo(type: String) async throws {
        let server = URL(string: "https://uploading-\(type).docmost.invalid")!
        OnceURLProtocol.requests.withLock { $0[server.host()!] = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnceURLProtocol.self]
        let client = APIClient(baseURL: server, configuration: configuration)
        let context = RenderContext(baseURL: server, client: client, mediaLoader: MediaLoader(client: client), token: nil, pageId: "p")
        func media(_ src: String) throws -> some View {
            let attrs: [String: JSONValue] = type == "attachment"
                ? ["url": .string(src), "name": "report.pdf", "size": 41, "placeholder": src.isEmpty ? ["id": "u"] : .null]
                : ["src": .string(src), "placeholder": src.isEmpty ? ["id": "u", "name": "report.pdf"] : .null]
            let doc = PMNode(type: "doc", content: [PMNode(type: type, attrs: attrs)])
            return BlockView(block: try #require(ContentParser.parse(doc).blocks.first)).environment(\.renderContext, context)
        }
        let host = UIHostingController(rootView: try media(""))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        let uploading = String(localized: "Uploading \("report.pdf")…", bundle: .main)
        #expect(await poll(tries: 100) { labels(in: window).contains { $0.contains(uploading) } }, "\(labels(in: window))")
        #expect(spinner(in: window))
        #expect(element(in: window) { $0.contains(uploading) }.map { !$0.accessibilityTraits.contains(.button) } == true, "nothing to tap")

        host.rootView = try media("/api/files/f/\(type)")
        #expect(await poll { !labels(in: window).contains { $0.contains(uploading) } }, "the file has come")
    }

    /// A formula is blank after its web process ended (iOS reclaimed its memory in the background, a crash). Coming
    /// back into view renders it again. GitHub's simulator sometimes doesn't let the app end the process (RunningBoard:
    /// "Client not entitled"); the test is cancelled then, as there is nothing to check.
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
        // WebKit's private test hook and process ID; only the tests use them.
        let end = NSSelectorFromString("_killWebContentProcess")
        try #require(island.responds(to: end))
        let process = try #require(island.value(forKey: "_webProcessIdentifier") as? pid_t)
        island.perform(end)
        // 20 s, as before: no web process starts here, and where this one keeps running the test ends itself.
        let blank = await poll(tries: 400) { island.url == nil }
        if !blank, process > 0, kill(process, 0) == 0 || errno == EPERM {
            try Test.cancel("The web process kept running.")
        }
        try #require(blank, "blank")

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
        let loader = MediaLoader(client: APIClient(baseURL: server, configuration: configuration))
        let context = RenderContext(baseURL: server, client: nil, mediaLoader: loader, token: nil, pageId: nil)
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
        // The messages are in what a tap on the failed file reads out, with the reason and what the tap does.
        let expected = [String(localized: "Mermaid diagram"), String(localized: "Show source"),
                        String(localized: "Diagram could not be loaded."), String(localized: "Image unavailable")]
        #expect(await poll { expected.allSatisfy { text in labels(in: window).contains { $0.contains(text) } } }, "\(labels(in: window))")
    }

    /// A tap to load a file from another server holds for that file only: another file in its place (a block above
    /// removed, a collaborator's change) asks again. It loaded by itself, and an image showed the previous picture until
    /// then (code review R14).
    @Test(arguments: ["image", "drawio", "pdf"])
    func tapToLoadFromAnotherServerHoldsForThatFile(type: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowURLProtocol.self]
        let server = URL(string: "https://wiki.example.com")!
        let loader = MediaLoader(client: APIClient(baseURL: server, configuration: configuration))
        let context = RenderContext(baseURL: server, client: nil, mediaLoader: loader, token: nil, pageId: nil)
        func media(_ src: String) throws -> some View {
            let doc = PMNode(type: "doc", content: [PMNode(type: type, attrs: ["src": .string(src)])])
            return BlockView(block: try #require(ContentParser.parse(doc).blocks.first)).environment(\.renderContext, context)
        }
        let host = UIHostingController(rootView: try media("https://one.example.net/a"))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        func asks(_ name: String) -> Bool { labels(in: window).contains { $0.contains(name) } }
        #expect(await poll { asks("one.example.net") })
        let card = try #require(element(in: window) { $0.contains("one.example.net") })
        #expect(card.accessibilityActivate())
        #expect(await poll { !asks("one.example.net") && spinner(in: window) }, "loads after the tap")

        host.rootView = try media("https://two.example.net/b")
        #expect(await poll { asks("two.example.net") }, "asks again for another file")
    }

    /// A file that failed to load says so with the reason and loads again on a tap: an image stayed "unavailable" and
    /// a PDF or diagram "could not be loaded" until the page was left and opened again (code review S3f).
    @Test(arguments: ["pdf", "drawio", "image"])
    func aTapLoadsAFailedFileAgain(type: String) async throws {
        let server = URL(string: "https://retry-\(type).docmost.invalid")!
        let host = try #require(server.host())
        OfflineURLProtocol.state.withLock { $0[host] = (isOffline: true, requests: 0) }
        let window = try show(type, src: "/api/files/a/file", server: server, protocolClass: OfflineURLProtocol.self)
        defer { window.isHidden = true }
        let again = String(localized: "Tap to try again.", bundle: .main)
        #expect(await poll { labels(in: window).contains { $0.contains(again) } }, "says what a tap does")
        #expect(labels(in: window).contains { $0.contains(URLError(.notConnectedToInternet).localizedDescription) }, "says why")

        // Back online (the file takes its time): the tap loads again.
        let failed = OfflineURLProtocol.state.withLock { state in
            state[host]?.isOffline = false
            return state[host]?.requests ?? 0
        }
        #expect(await tap(again, in: window) { OfflineURLProtocol.state.withLock { $0[host]?.requests ?? 0 } > failed }, "loads again")
        #expect(await poll { spinner(in: window) })
    }

    /// A file over 25 MB doesn't load by itself when the page shows it: the server names its size, nothing of it
    /// loads, and the card waits for a tap (decided on November 10, 2026).
    @Test(arguments: ["pdf", "drawio", "image"])
    func aLargeFileWaitsForATap(type: String) async throws {
        let server = URL(string: "https://large-\(type).docmost.invalid")!
        LargeURLProtocol.requests.withLock { $0[server.host()!] = nil }
        let window = try show(type, src: "/api/files/a/file", server: server, protocolClass: LargeURLProtocol.self)
        defer { window.isHidden = true }
        let tap = MediaStandIn.largeDetail(size: nil)
        #expect(await poll { labels(in: window).contains { $0.contains(tap) } }, "waits for a tap")
        #expect(!spinner(in: window))

        // Coming back into view (the page shown again) doesn't ask the server again.
        let asked = LargeURLProtocol.requests.withLock { $0[server.host()!] ?? 0 }
        window.isHidden = true
        window.isHidden = false
        try await Task.sleep(for: .milliseconds(500))
        #expect(LargeURLProtocol.requests.withLock { $0[server.host()!] ?? 0 } == asked)
        #expect(await self.tap(tap, in: window) { LargeURLProtocol.requests.withLock { $0[server.host()!] ?? 0 } > asked }, "loads after the tap")
        #expect(await poll { !labels(in: window).contains { $0.contains(tap) } }, "and asks no more")
    }

    /// What stands in after a failed load: a tap card for a file over the limit, the reason for a failure, nothing
    /// for a file that isn't what the view shows, and no failure at all for a cancelled load.
    @Test func standInsAfterAFailedLoad() async {
        #expect(MediaGate.standIn(after: APIError.tooLarge(limit: 25_000_000)) == .large)
        #expect(MediaGate.standIn(after: MediaUnreadable()) == .failed(reason: nil))
        let offline = APIError.network(URLError(.notConnectedToInternet))
        #expect(MediaGate.standIn(after: offline) == .failed(reason: offline.userMessage))
        #expect(MediaGate.standIn(after: CancellationError()) == nil)
        // A server's message without a period doesn't run into the next sentence.
        let again = String(localized: "Tap to try again.", bundle: .main)
        #expect(MediaStandIn.failureDetail("PDF could not be loaded.", reason: "Invalid file id") == "PDF could not be loaded. Invalid file id. \(again)")
        #expect(MediaStandIn.failureDetail("PDF could not be loaded.", reason: nil) == "PDF could not be loaded. \(again)")
        // A large file waits until its tap, and no longer after it.
        #expect(MediaGate().stillWaits(.large) && !MediaGate().stillWaits(.failed(reason: nil)))
        #expect(!MediaGate(loadsLargeFile: true).stillWaits(.large))
        // The taps are the load's id: each one loads again, and a tap for a large file lifts the limit.
        var gate = MediaGate()
        #expect(gate.maxBytes == MediaLoader.maxAutomaticBytes)
        gate.loadsLargeFile = true
        #expect(gate.maxBytes == nil && gate != MediaGate())
    }

    /// An animated GIF plays in the page (the reader, the editor, a presentation), as on the web, and VoiceOver still
    /// reads it as the image it is: SwiftUI's `Image` showed its first frame only.
    @Test func animatedImagesPlay() async throws {
        let file = URL.temporaryDirectory.appending(path: "animated-\(UUID().uuidString).gif")
        try MediaLoaderTests.animation(.gif, delays: [0.1, 0.1, 0.1], width: 40, height: 30).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = URL(string: "https://animated.docmost.invalid")!
        let context = RenderContext(baseURL: server, client: nil, mediaLoader: MediaLoader(client: APIClient(baseURL: server)), token: nil, pageId: nil)
        let doc = PMNode(type: "doc", content: [PMNode(type: "image", attrs: ["src": .string(file.absoluteString), "alt": "Screen recording"])])
        let view = BlockView(block: try #require(ContentParser.parse(doc).blocks.first)).environment(\.renderContext, context)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer { window.isHidden = true }

        #expect(await poll { imageViews(in: window).contains { $0.image?.images?.count == 3 && $0.window != nil } })
        let playing = try #require(imageViews(in: window).first { $0.image?.images != nil })
        // UIImageView plays it as an animation of its layer's contents. Both this and the label come after the image is
        // set, on a later layout pass: read once, they were sometimes not there yet within the suite.
        #expect(await poll { playing.layer.animationKeys()?.isEmpty == false })
        #expect(playing.bounds.width > 0 && abs(playing.bounds.width / playing.bounds.height - 4 / 3) < 0.01, "\(playing.bounds)")
        #expect(await poll { labels(in: window).contains("Screen recording") }, "\(labels(in: window))")
    }

    /// One that plays once or a few times, as its file says, stops on its last frame, as the web's `<img>` does, in
    /// the page and full screen. UIImageView played it on and on.
    @Test func animationsStopAfterTheirPlays() async throws {
        // A GIF that plays once: ImageIO writes it without a NETSCAPE block.
        let data = try MediaLoaderTests.animation(.gif, delays: [0.5, 0.5, 0.5], width: 40, height: 30, loops: 1)
        let image = try #require(await MediaLoader.decode(data, targetPixelWidth: 512))
        let last = try #require(image.images?.last)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ResizableImage(image: image).frame(width: 40, height: 30))
        window.isHidden = false
        defer { window.isHidden = true }
        let viewer = ImageZoomView(image: image)
        viewer.frame = CGRect(x: 0, y: 100, width: 200, height: 200)
        window.addSubview(viewer)

        // The image views with its frames (a scroll view may have image views of its own).
        func shown() -> [UIImageView] { imageViews(in: window).filter { $0.image?.images != nil || $0.animationImages != nil } }
        func playing(_ view: UIImageView) -> Bool { view.layer.animationKeys()?.isEmpty == false }
        #expect(await poll { shown().count == 2 && shown().allSatisfy(playing) })
        #expect(await poll(tries: 100) { shown().allSatisfy { !playing($0) && $0.image === last } })
    }

    private func imageViews(in view: UIView) -> [UIImageView] {
        view.layoutIfNeeded()
        return [view as? UIImageView].compactMap(\.self) + view.subviews.flatMap(imageViews)
    }

    /// Taps the element whose label holds `text` until `done`. Again where needed: SwiftUI may build the view anew
    /// while other tests' windows come and go, and a tap on an element of the view before reaches nothing.
    private func tap(_ text: String, in window: UIWindow, until done: () -> Bool) async -> Bool {
        await poll {
            if done() { return true }
            _ = element(in: window) { $0.contains(text) }?.accessibilityActivate()
            return false
        }
    }

    /// A media block of `type` in a window, its requests answered by `protocolClass`.
    private func show(_ type: String, src: String, server: URL, protocolClass: AnyClass) throws -> UIWindow {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let loader = MediaLoader(client: APIClient(baseURL: server, configuration: configuration))
        let context = RenderContext(baseURL: server, client: nil, mediaLoader: loader, token: nil, pageId: nil)
        let doc = PMNode(type: "doc", content: [PMNode(type: type, attrs: ["src": .string(src)])])
        let view = BlockView(block: try #require(ContentParser.parse(doc).blocks.first)).environment(\.renderContext, context)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    /// An image's aspect ratio from the page sizes its placeholder only where it can: 0, a negative or a tiny ratio
    /// gave it no height it could take (code review R36). Such a ratio counts as none, 16:9.
    @Test(arguments: [0, -1, 1e-300])
    func imagePlaceholderTakesASensibleHeight(ratio: Double) throws {
        let doc = PMNode(type: "doc", content: [PMNode(type: "image", attrs: ["src": "/api/files/a/b.png", "aspectRatio": .number(ratio)])])
        let block = try #require(ContentParser.parse(doc).blocks.first)
        let size = UIHostingController(rootView: BlockView(block: block)).sizeThatFits(in: CGSize(width: 300, height: CGFloat.infinity))
        #expect(size.height.isFinite && size.height > 0 && size.height <= 300, "\(size)")
    }

    /// An image keeps the picture of the width it shows when the decode for a width it left ends later. Its width went
    /// from 300 points to 100 and back (a collaborator's resizing; the cover, which loads alike, on an iPad's
    /// rotation): the way back found its picture in memory at once, and the cancelled decode for 100 points ran on and
    /// replaced it, soft until the next change. Here the file changes before that decode, a large square in place of
    /// the wide picture, so the image's height tells which picture it shows. Drawn as a gradient: one color decodes too
    /// fast for the race (about 25 ms in the simulator, against 280).
    @Test func aCancelledDecodeKeepsThePictureShown() async throws {
        let file = URL.temporaryDirectory.appending(path: "decode-\(UUID().uuidString).png")
        let square = URL.temporaryDirectory.appending(path: "decode-\(UUID().uuidString).png")
        try await GradientPNG.write(width: 900, height: 450, to: file)
        try await GradientPNG.write(width: 6000, height: 6000, to: square)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: square)
        }
        let server = URL(string: "https://wiki.example.com")!
        let context = RenderContext(baseURL: server, client: nil, mediaLoader: MediaLoader(client: APIClient(baseURL: server)), token: nil, pageId: nil)
        var height = CGFloat.zero
        func image(width: Double) throws -> some View {
            let doc = PMNode(type: "doc", content: [PMNode(type: "image", attrs: ["src": .string(file.absoluteString), "width": .number(width)])])
            return BlockView(block: try #require(ContentParser.parse(doc).blocks.first))
                .environment(\.renderContext, context)
                .frame(width: 300)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        func shows(_ expected: CGFloat) -> Bool { abs(height - expected) < 0.5 }
        let host = UIHostingController(rootView: try image(width: 300))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try #require(await poll { shows(150) }, "the wide picture at 300 points")
        _ = try FileManager.default.replaceItemAt(file, withItemAt: square)

        host.rootView = try image(width: 100)
        // Laid out for 100 points, with the wide picture or already the square: the load for 100 began. A moment for it
        // to start, then back.
        try #require(await poll(tries: 2000, every: .milliseconds(2)) {
            window.layoutIfNeeded()
            return shows(50) || shows(100)
        })
        try await Task.sleep(for: .milliseconds(10))
        host.rootView = try image(width: 300)
        #expect(await poll(tries: 100) { shows(150) }, "back at 300 points")
        #expect(await !poll(tries: 60) { !shows(150) }, "keeps the wide picture")
    }

    /// An image follows its column as it gets narrower (an iPhone turned from landscape to portrait, an iPad's window
    /// made narrower) and wider again, loaded or still loading. Its width comes from the place it is offered, which
    /// took the width of the image in it: once laid out wide, the image stayed wide and ran past the column. The full
    /// width, or 250 points (the image at 250 in the wide column, at 200 in the narrow one).
    @Test(arguments: [("left", nil), ("center", nil), ("right", nil), ("center", 250)] as [(align: String, width: Double?)], [true, false])
    func anImageFollowsItsColumnsWidth(layout: (align: String, width: Double?), loads: Bool) async throws {
        let file = URL.temporaryDirectory.appending(path: "column-\(UUID().uuidString).png")
        try await GradientPNG.write(width: 900, height: 450, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = URL(string: "https://wiki.example.com")!
        // Without a loader the placeholder stays, sized by the page's aspect ratio: the picture's own.
        let loader = loads ? MediaLoader(client: APIClient(baseURL: server)) : nil
        let context = RenderContext(baseURL: server, client: nil, mediaLoader: loader, token: nil, pageId: nil)
        var attrs: [String: JSONValue] = ["src": .string(file.absoluteString), "aspectRatio": .number(2), "align": .string(layout.align)]
        if let width = layout.width { attrs["width"] = .number(width) }
        let doc = PMNode(type: "doc", content: [PMNode(type: "image", attrs: attrs)])
        let block = try #require(ContentParser.parse(doc).blocks.first)
        let wide = min(layout.width ?? 300, 300) / 2
        var height = CGFloat.zero
        func image(in column: CGFloat) -> some View {
            BlockView(block: block)
                .environment(\.renderContext, context)
                .frame(width: column)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        func shows(_ expected: CGFloat) -> Bool { abs(height - expected) < 0.5 }
        let host = UIHostingController(rootView: image(in: 300))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try #require(await poll { shows(wide) && spinner(in: window) != loads }, "in the wide column: \(height)")

        host.rootView = image(in: 200)
        #expect(await poll(tries: 100) { shows(100) }, "narrower with its column: \(height)")
        host.rootView = image(in: 300)
        #expect(await poll(tries: 100) { shows(wide) }, "wider again: \(height)")
        #expect(spinner(in: window) != loads)
    }

    /// Polls `condition` while SwiftUI lays out (`tries` × `interval`, a minute by default; a met condition ends the
    /// wait at once). GitHub's runners start web processes far slower than a Mac: in three of about 130 runs from
    /// November 8 to 15, 2026 one took 15 to 22 s to launch, and the 20 s this waited before ended as the launch did
    /// (`keepsItsContentOnReturn`) or four seconds after it (`formulaRendersAgainAfterItsWebProcessEnded`).
    private func poll(tries: Int = 1200, every interval: Duration = .milliseconds(50), _ condition: () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if condition() { return true }
            try? await Task.sleep(for: interval)
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

    /// The first element VoiceOver can reach from `element` whose label passes `matches`.
    private func element(in element: NSObject, _ matches: (String) -> Bool) -> NSObject? {
        if let label = element.accessibilityLabel, matches(label) { return element }
        let children = element.accessibilityElements as? [NSObject] ?? (element as? UIView)?.subviews ?? []
        for child in children {
            if let found = self.element(in: child, matches) { return found }
        }
        return nil
    }
}

/// A PNG of a gradient from red to blue, written off the main actor: a large one takes a second or more, which the
/// tests waiting there would feel.
private nonisolated enum GradientPNG {
    @concurrent static func write(width: Int, height: Int, to file: URL) async throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] as CFArray
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let gradient = try #require(CGGradient(colorsSpace: space, colors: colors, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
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
/// Answers every synced block lookup with content that holds the same synced block again, in a column.
private nonisolated final class SelfReferenceURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.withLock { $0 += 1 }
        let body = #"{"data": {"items": [{"content": {"type": "doc", "content": [{"type": "columns", "content": [{"type": "column", "content": [{"type": "transclusionReference", "attrs": {"sourcePageId": "s", "transclusionId": "t"}}]}, {"type": "column", "content": [{"type": "paragraph"}]}]}]}}]}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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

/// Fails the requests to a server as a device offline does while the test says so, then never answers (the file
/// takes its time). Counts the requests per server.
private nonisolated final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex<[String: (isOffline: Bool, requests: Int)]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host() else { return }
        let isOffline = Self.state.withLock { state in
            state[host, default: (true, 0)].requests += 1
            return state[host]?.isOffline ?? true
        }
        if isOffline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }

    override func stopLoading() {}
}

/// Answers as for a file of 30 MB, of which one byte comes. (URLSession hands a stub's answer on only once the stub
/// has finished, so the stub can't leave the file loading; against a real server the refusal comes with the answer's
/// head, tried on November 10, 2026.)
private nonisolated final class LargeURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        Self.requests.withLock { $0[host, default: 0] += 1 }
        let head = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "30000000"])!
        client?.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
