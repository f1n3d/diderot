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

    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
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
