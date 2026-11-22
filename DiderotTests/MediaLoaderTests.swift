import Foundation
import Synchronization
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import DocmostKit
@testable import Diderot

/// Content images fill the available width, so portrait images (phone screenshots) must decode that wide.
struct MediaLoaderTests {
    @Test func portraitImagesDecodeAtTheTargetWidth() async throws {
        // 1000×3000 upright, and 3000×1000 pixels that EXIF orientation 6 shows rotated to 1000×3000.
        for (width, height, orientation) in [(1000, 3000, 1), (3000, 1000, 6)] {
            let data = try jpeg(width: width, height: height, orientation: orientation)
            let image = try #require(await MediaLoader.decode(data, targetPixelWidth: 512))
            // The same from a file, as content images load.
            let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(await MediaLoader.decode(file: file, targetPixelWidth: 512)?.size == image.size)
            #expect(image.size.width >= 512, "orientation \(orientation)")
        }
    }

    /// Tall images decode at the full target width up to `maxPixels` (an iPhone in portrait), narrower beyond (an
    /// iPhone in landscape); wide ones at the target width.
    @Test func tallImagesKeepToThePixelBudget() {
        #expect(MediaLoader.thumbnailSize(targetPixelWidth: 1280, ratio: 4) == 5120)
        let landscape = MediaLoader.thumbnailSize(targetPixelWidth: 2560, ratio: 4)
        #expect(Double(landscape) * Double(landscape) / 4 <= MediaLoader.maxPixels * 1.001)
        #expect(landscape > 6000)
        #expect(MediaLoader.thumbnailSize(targetPixelWidth: 2560, ratio: 0.5) == 2560)
    }

    /// Media from another host loads only after a tap, unless Settings turns that on; the server's own always loads.
    /// Avatars and logos follow the setting too: a workspace or space logo loaded from anywhere (code review R14).
    @Test func otherServersLoadOnlyWhenAllowed() {
        let server = URL(string: "https://wiki.example.com")!
        let key = RenderContext.loadsOtherServersKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        func thumbnail(_ url: String) -> URL? {
            RemoteThumbnail(url: URL(string: url), server: server, size: 24, shape: Circle()) { EmptyView() }.source
        }
        UserDefaults.standard.set(false, forKey: key)
        #expect(RenderContext.loadsByItself(URL(string: "https://wiki.example.com/api/files/a/b.png")!, server: server))
        #expect(!RenderContext.loadsByItself(URL(string: "https://tracker.example.net/p.png")!, server: server))
        #expect(!RenderContext.loadsByItself(URL(string: "http://wiki.example.com/b.png")!, server: server), "another scheme is another origin")
        #expect(RenderContext.loadsByItself(URL.temporaryDirectory.appending(path: "clip.mov"), server: server), "a file on the device")
        #expect(thumbnail("https://wiki.example.com/api/attachments/img/space-logo/a.png") != nil)
        #expect(thumbnail("https://tracker.example.net/logo.png") == nil)
        UserDefaults.standard.set(true, forKey: key)
        #expect(RenderContext.loadsByItself(URL(string: "https://tracker.example.net/p.png")!, server: server))
        #expect(thumbnail("https://tracker.example.net/logo.png") != nil)
    }

    /// A width from the document such as "nan%" or a huge negative number gives a bounded pixel width: turning it into an
    /// Int trapped, for everyone who saw the image.
    @Test func pixelWidthsStayInBounds() {
        #expect(MediaLoader.pixelWidth(for: -1e20, scale: 3) == 64)
        #expect(MediaLoader.pixelWidth(for: .nan, scale: 3) == 64)
        #expect(MediaLoader.pixelWidth(for: 1e20, scale: 3) == 16_384)
        #expect(MediaLoader.pixelWidth(for: 300, scale: 3) == 900)
    }

    /// An image larger than the source limit isn't decoded at all, not even as a thumbnail: a file that is small as such
    /// but huge unpacked (a member's crafted avatar) took the app's memory wherever it showed.
    @Test func sourcesOverTheLimitAreNotDecoded() async throws {
        let data = try jpeg(width: 400, height: 300, orientation: 1)
        #expect(await MediaLoader.decode(data, targetPixelWidth: 100, maxSourcePixels: 100_000) == nil)
        #expect(await MediaLoader.decode(data, targetPixelWidth: 100, maxSourcePixels: 200_000) != nil)
    }

    /// An animated GIF or PNG plays as the web's `<img>` plays it: every frame, each as long as the file says, and one
    /// of 10 ms or less (often 0) for 100 ms, as browsers take it. It decoded to its first frame only.
    @Test(arguments: [UTType.gif, .png])
    func animatedImagesKeepTheirFramesAndTiming(type: UTType) async throws {
        let data = try Self.animation(type, delays: [0.2, 0.6, 0], width: 40, height: 30)
        let image = try #require(await MediaLoader.decode(data, targetPixelWidth: 512))
        let frames = try #require(image.images, "animated")
        // Equal steps of 100 ms: the first frame for two, the second for six, the third for one.
        var runs: [Int] = []
        for (index, frame) in frames.enumerated() {
            if index > 0, frames[index - 1] === frame { runs[runs.count - 1] += 1 } else { runs.append(1) }
        }
        #expect(runs == [2, 6, 1])
        #expect(abs(image.duration - 0.9) < 0.001)
        #expect(image.size == CGSize(width: 40, height: 30))
        // The memory cache counts each frame once, however often it repeats.
        #expect(MediaLoader.decodedBytes(image) == 3 * 40 * 30 * 4)
        // The same from a file, as the full-screen viewer decodes it.
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await MediaLoader.decode(file: file, targetPixelWidth: 16_384)?.images?.count == 9)
    }

    /// An animation's frames together take a quarter of what one still image may (`maxPixels`), about 12 MB, and each
    /// no more than the still image would: every image on a page keeps what it decoded while the page is open, and a
    /// page of screen recordings took 48 MB for each. A large one plays smaller. One of more frames than
    /// `maxAnimationFrames`, and a TIFF's pages, show the first frame, still.
    @Test func animationsKeepToTheLimits() async throws {
        let budget = MediaLoader.maxAnimationPixels
        #expect(budget == MediaLoader.maxPixels / 4)
        let large = try Self.animation(.gif, delays: Array(repeating: 0.1, count: 10), width: 1500, height: 1000)
        let image = try #require(await MediaLoader.decode(large, targetPixelWidth: 2048))
        let frame = try #require(image.images?.first)
        let pixels = 10 * frame.size.width * frame.size.height
        #expect(pixels <= budget && pixels > budget * 0.95, "\(frame.size)")
        #expect(abs(frame.size.width / frame.size.height - 1.5) < 0.01)
        // A screen recording in an iPhone's column (a 1280 px bucket): 60 frames of 800 × 450. ImageIO rounds the
        // shorter side up (298 × 168), a pixel row over.
        let recording = try Self.animation(.gif, delays: Array(repeating: 0.1, count: 60), width: 800, height: 450)
        let played = try #require(await MediaLoader.decode(recording, targetPixelWidth: 1280)?.images?.first)
        #expect(60 * played.size.width * played.size.height <= budget * 1.01, "\(played.size)")
        // Few frames: as large as the still image at that width, no larger.
        let short = try Self.animation(.gif, delays: [0.1, 0.1], width: 1500, height: 1000)
        let still = try #require(await MediaLoader.decode(Self.animation(.gif, delays: [0.1], width: 1500, height: 1000), targetPixelWidth: 512))
        #expect(try #require(await MediaLoader.decode(short, targetPixelWidth: 512)?.images?.first).size == still.size)

        let long = try Self.animation(.gif, delays: Array(repeating: 0.1, count: MediaLoader.maxAnimationFrames + 1), width: 8, height: 8)
        #expect(try #require(await MediaLoader.decode(long, targetPixelWidth: 64)).images == nil)
        let pages = try Self.animation(.tiff, delays: [0.1, 0.1], width: 8, height: 8)
        #expect(try #require(await MediaLoader.decode(pages, targetPixelWidth: 64)).images == nil)
    }

    /// APNG and WebP count a frame's delay in milliseconds or finer, GIF in 10 ms: a 33 ms frame lasts 33 ms. Rounded
    /// to 10 ms, as for a GIF, a 30 fps WebP played 10 % fast and a 60 fps APNG 20 % slow.
    @Test func delaysCountInMilliseconds() async throws {
        let delays = [33.0, 17, 50]
        for data in [try Self.animation(.png, delays: delays.map { $0 / 1000 }, width: 4, height: 4), Self.webP(delays: delays.map { Int($0) })] {
            let image = try #require(await MediaLoader.decode(data, targetPixelWidth: 64))
            let frames = try #require(image.images, "animated")
            var runs: [Int] = []
            for (index, frame) in frames.enumerated() {
                if index > 0, frames[index - 1] === frame { runs[runs.count - 1] += 1 } else { runs.append(1) }
            }
            let shown = runs.map { Double($0) * image.duration / Double(frames.count) * 1000 }
            #expect(zip(shown, delays).allSatisfy { abs($0 - $1) < 0.5 }, "\(shown)")
        }
    }

    /// An animation plays as often as its file says, as on the web: ImageIO counts a GIF's plays (none written: once),
    /// an APNG's and a WebP's; 0 is on and on. It played on and on.
    @Test func animationsPlayAsOftenAsTheFileSays() async throws {
        let files: [(data: Data, plays: Int?)] = [
            (try Self.animation(.gif, delays: [0.1, 0.1], width: 4, height: 4, loops: 1), 1),
            (try Self.animation(.gif, delays: [0.1, 0.1], width: 4, height: 4, loops: 3), 3),
            (try Self.animation(.gif, delays: [0.1, 0.1], width: 4, height: 4), nil),
            (try Self.animation(.png, delays: [0.1, 0.1], width: 4, height: 4, loops: 2), 2),
            (try Self.animation(.png, delays: [0.1, 0.1], width: 4, height: 4), nil),
            (Self.webP(delays: [100, 100], loops: 2), 2),
            (Self.webP(delays: [100, 100]), nil),
        ]
        for (index, file) in files.enumerated() {
            let image = try #require(await MediaLoader.decode(file.data, targetPixelWidth: 64))
            #expect(image.images != nil && image.plays == file.plays, "file \(index)")
        }
    }

    /// A decode whose view went away (scrolled past) stops between frames and keeps nothing: it decoded every frame
    /// for nobody, and the first frame alone mustn't stand in for the animation in the memory cache.
    @Test func cancelledAnimationsStopDecoding() async throws {
        let data = try Self.animation(.gif, delays: [0.1, 0.1, 0.1], width: 40, height: 30)
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loader = MediaLoader(client: APIClient(baseURL: URL(string: "https://cancelled.docmost.invalid")!))
        let cancelled = Task { () -> (decoded: UIImage?, loaded: UIImage?) in
            withUnsafeCurrentTask { $0?.cancel() }
            return (await MediaLoader.decode(data, targetPixelWidth: 512), try? await loader.image(for: file, targetWidth: 40, scale: 1))
        }
        let result = await cancelled.value
        #expect(result.decoded == nil && result.loaded == nil)
        #expect(try await loader.image(for: file, targetWidth: 40, scale: 1).images?.count == 3)
    }

    /// Frames of `width` × `height` pixels, each in its own color, that last `delays` seconds, as a GIF or an APNG
    /// that plays `loops` times (0: on and on); another type (TIFF) gets them as pages.
    static func animation(_ type: UTType, delays: [Double], width: Int, height: Int, loops: Int = 0) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, delays.count, nil))
        let (dictionary, loopCount, delayTime) = type == .png
            ? (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount, kCGImagePropertyAPNGDelayTime)
            : (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount, kCGImagePropertyGIFDelayTime)
        // ImageIO counts a GIF's plays as browsers do: it writes 1 as no NETSCAPE block, n as n - 1 repetitions.
        CGImageDestinationSetProperties(destination, [dictionary: [loopCount: loops]] as CFDictionary)
        for (index, delay) in delays.enumerated() {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.setFillColor(red: CGFloat(index % 2), green: CGFloat(index % 3) / 2, blue: CGFloat(index % 5) / 4, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [dictionary: [delayTime: delay]] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A WebP of 1 × 1 pixel frames that last `delays` milliseconds and play `loops` times (0: on and on). ImageIO
    /// writes no WebP, so it is put together here: a lossless frame in an ANMF chunk for each delay.
    static func webP(delays: [Int], loops: Int = 0) -> Data {
        func bytes(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * $0)) & 0xff) } }
        func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] { Array(tag.utf8) + bytes(body.count, 4) + body + (body.count % 2 == 1 ? [0] : []) }
        // The VP8L chunk of the smallest lossless WebP.
        let frame = Array(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!.dropFirst(12))
        var body = Array("WEBP".utf8) + chunk("VP8X", [0x02, 0, 0, 0] + bytes(0, 6)) + chunk("ANIM", bytes(0, 4) + bytes(loops, 2))
        for delay in delays { body += chunk("ANMF", bytes(0, 12) + bytes(delay, 3) + [0] + frame) }
        return Data(chunk("RIFF", body))
    }

    private func jpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// One download per address for all who wait, into a file; it stops when the last of them leaves. The file is the
/// offline copy, which stands in when the network fails, but not for a file the server says is gone, and not if it is
/// too large for the cache.
@Suite(.serialized) struct MediaLoaderFileTests {
    private let server = URL(string: "https://media-loader.example.com")!
    private var image: URL { server.appending(path: "api/files/abc/photo.png") }

    init() { FileServer.state.withLock { $0 = .init() } }

    private func loader(cache: DiskCache? = nil, maxCachedBytes: Int = MediaLoader.maxCachedBytes) -> MediaLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileServer.self]
        return MediaLoader(client: APIClient(baseURL: server, configuration: configuration), cache: cache, maxCachedBytes: maxCachedBytes)
    }

    private func cache() -> DiskCache {
        DiskCache(scope: "media", baseDirectory: FileManager.default.temporaryDirectory.appending(path: "media-loader-tests-\(UUID().uuidString)"))
    }

    private func poll(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private var requests: Int { FileServer.state.withLock { $0.requests } }
    private var stopped: Int { FileServer.state.withLock { $0.stopped } }

    @Test func oneDownloadForAllWhoWait() async throws {
        FileServer.state.withLock { $0.holds = true }
        let loader = loader(), image = image
        let waiting = (0..<3).map { _ in Task { try await loader.file(for: image) } }
        #expect(await poll { requests == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests == 1)

        FileServer.release()
        var files: Set<URL> = []
        for task in waiting { files.insert(try await task.value) }
        #expect(files.count == 1)
        #expect(try Data(contentsOf: #require(files.first)) == Data("file".utf8))
        // Loaded in this session: shown again, it isn't loaded again.
        FileServer.state.withLock { $0.holds = false }
        #expect(try await loader.file(for: image) == files.first)
        #expect(try await loader.data(for: image) == Data("file".utf8))
        #expect(requests == 1)
    }

    /// Scrolling past an image ends its wait, and the download once nobody waits: it went on to the end before
    /// (review R47).
    @Test func theDownloadStopsWithItsLastWaiter() async throws {
        FileServer.state.withLock { $0.holds = true }
        let loader = loader(), image = image
        let first = Task { try await loader.file(for: image) }, second = Task { try await loader.file(for: image) }
        #expect(await poll { requests == 1 })
        // Both wait before one leaves.
        try await Task.sleep(for: .milliseconds(100))

        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stopped == 0, "the other still waits")

        second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        #expect(await poll { stopped == 1 })

        // Shown again, it loads anew.
        FileServer.state.withLock { $0.holds = false }
        #expect(try Data(contentsOf: try await loader.file(for: image)) == Data("file".utf8))
        #expect(requests == 2)
    }

    @Test func theOfflineCopyStandsInButNotForAFileThatIsGone() async throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let file = try await loader(cache: cache).file(for: image)
        #expect(file.path.hasPrefix(cache.directory.path), "the download is the offline copy")

        // Another launch, and the server fails: the copy shows.
        FileServer.state.withLock { $0.answer = (500, Data()) }
        #expect(try await loader(cache: cache).file(for: image) == file)

        // The server says the file is gone (deleted, access removed): the copy goes too (review V28).
        FileServer.state.withLock { $0.answer = (404, Data(#"{"statusCode":404,"message":"Attachment not found"}"#.utf8)) }
        await #expect(throws: APIError.notFound(message: "Attachment not found")) { _ = try await loader(cache: cache).file(for: image) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        FileServer.state.withLock { $0.answer = (500, Data()) }
        await #expect(throws: APIError.server(status: 500, message: nil)) { _ = try await loader(cache: cache).file(for: image) }
    }

    /// A file larger than a view lets load by itself is refused, unless it is on the device already: loaded in this
    /// session after a tap, or saved from an earlier one.
    @Test func aFileOverTheLimitIsRefusedUnlessItIsOnTheDevice() async throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let loader = loader(cache: cache), image = image
        await #expect(throws: APIError.tooLarge(limit: 3)) { _ = try await loader.file(for: image, maxBytes: 3) }
        #expect(await cache.totalSize() == 0)

        // After a tap it loads whole, and shows again within the limit without another request.
        let file = try await loader.file(for: image)
        #expect(try await loader.file(for: image, maxBytes: 3) == file)
        #expect(requests == 2)
        // Another launch: the server refuses it again, the saved copy shows.
        #expect(try await self.loader(cache: cache).file(for: image, maxBytes: 3) == file)
    }

    /// One large PDF pushed most of the offline cache out (review R50): it stays for the session, outside the cache.
    @Test func aFileTooLargeForTheCacheStaysForTheSession() async throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        var loader: MediaLoader? = loader(cache: cache, maxCachedBytes: 3)
        let file = try await loader!.file(for: image)
        #expect(!file.path.hasPrefix(cache.directory.path))
        #expect(try Data(contentsOf: file) == Data("file".utf8))
        #expect(await cache.totalSize() == 0)
        #expect(try await loader!.file(for: image) == file)
        #expect(requests == 1)

        loader = nil
        #expect(!FileManager.default.fileExists(atPath: file.path), "gone with its loader")
    }

    /// A sign-in caps the offline cache at 300 MB, and iOS may keep the app running for days after it: the cache grew
    /// by every file opened meanwhile. Once a loader has moved as much into it as its largest file, it caps it again,
    /// the oldest first, but not what a start without network reads.
    @Test func theCacheKeepsItsCapWhileTheAppRuns() async throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        // Signed in a day ago, and photos and PDFs of 300 MB opened since (one sparse file: nothing of it is written).
        await cache.write("u1", key: CacheKey.currentUser)
        await cache.write("business", key: CacheKey.entitlements)
        await cache.write("0.98.0", key: CacheKey.serverVersion)
        for file in try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-24 * 3600)],
                                                  ofItemAtPath: file.path(percentEncoded: false))
        }
        let opened = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        #expect(FileManager.default.createFile(atPath: opened.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: opened)
        try handle.truncate(atOffset: 300 << 20)
        try handle.close()
        let stored = try await cache.storeFile(at: opened, key: "image/opened")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)],
                                              ofItemAtPath: stored.path(percentEncoded: false))

        // One more photo, as large as the largest file the cache takes here.
        _ = try await loader(cache: cache, maxCachedBytes: 4).file(for: image)
        #expect(await poll { await cache.totalSize() <= 300 << 20 })
        #expect(await cache.dataFile(key: "image/opened") == nil)
        #expect(await cache.dataFile(key: "image/\(image.absoluteString)") != nil, "the newest stays")
        #expect(await cache.read(String.self, key: CacheKey.currentUser) == "u1")
        #expect(await cache.read(String.self, key: CacheKey.entitlements) == "business")
        #expect(await cache.read(String.self, key: CacheKey.serverVersion) == "0.98.0")
    }
}

/// Answers each request with `answer`, at once or when released (`holds`); counts the requests, and those stopped
/// before they were answered.
private nonisolated final class FileServer: URLProtocol, @unchecked Sendable {
    struct State {
        var answer: (status: Int, body: Data) = (200, Data("file".utf8))
        var holds = false
        var requests = 0
        var stopped = 0
        var held: [FileServer] = []
    }

    static let state = Mutex(State())
    private let isAnswered = Mutex(false)

    static func release() {
        let (held, answer) = state.withLock { state in
            defer { state.held = [] }
            return (state.held, state.answer)
        }
        for request in held { request.respond(answer) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.state.withLock { state -> (status: Int, body: Data)? in
            state.requests += 1
            if state.holds { state.held.append(self) }
            return state.holds ? nil : state.answer
        }
        if let answer { respond(answer) }
    }

    override func stopLoading() {
        if !isAnswered.withLock({ $0 }) { Self.state.withLock { $0.stopped += 1 } }
    }

    private func respond(_ answer: (status: Int, body: Data)) {
        guard let url = request.url, !isAnswered.withLock({ answered in defer { answered = true }; return answered }) else { return }
        let headers = ["Content-Length": String(answer.body.count)]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
