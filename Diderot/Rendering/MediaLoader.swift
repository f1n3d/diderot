import Foundation
import ImageIO
import PDFKit
import UIKit
import DocmostKit

/// Loads the files a page shows from behind the API (images, diagrams, PDFs): one download per address, however many
/// views wait for it, straight into a file. Nothing of a file is held in memory but what is decoded from it. The file
/// is the offline copy too, unless it is too large for the cache; then it stays for this session only.
actor MediaLoader {
    private let client: APIClient
    private let cache: DiskCache?
    private let maxCachedBytes: Int
    private let memory = NSCache<NSString, UIImage>()
    /// Loaded from the network in this session, and where: the copy is current, so showing it again (another width
    /// after a rotation, the viewer, the page once more) reads it instead of loading again.
    private var loaded: [URL: URL] = [:]
    private var downloads: [Request: Download] = [:]
    /// The files too large for the offline cache, which go with the loader.
    private let sessionFolder: URL

    /// What a download is for: a file, and whether it may be of any size. A view that waits for a file within the
    /// limit must not get the answer of one that may be larger, nor the other way round.
    private struct Request: Hashable {
        let url: URL
        let maxBytes: Int64?
    }

    /// A download and the views waiting for it. It stops when the last of them leaves.
    private struct Download {
        let id = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<URL, any Error>] = [:]
    }

    /// Largest file the offline cache keeps: a larger one would push most of the rest out of its 300 MB
    /// (`DiskCache.prune` removes the oldest first).
    static let maxCachedBytes = 50_000_000

    /// Largest file that loads by itself when a page shows it; a larger one waits for a tap (`MediaStandIn.large`):
    /// scrolling past a PDF of some hundred MB shouldn't download it.
    nonisolated static let maxAutomaticBytes: Int64 = 25_000_000

    init(client: APIClient, cache: DiskCache? = nil, maxCachedBytes: Int = MediaLoader.maxCachedBytes) {
        self.client = client
        self.cache = cache
        self.maxCachedBytes = maxCachedBytes
        sessionFolder = TempFile.sessionMedia(server: client.baseURL)
        memory.totalCostLimit = 150 << 20
    }

    deinit {
        try? FileManager.default.removeItem(at: sessionFolder)
    }

    // MARK: - Files

    /// The file at `url`, on this device: from the network once per session, and the offline copy when that fails,
    /// unless the server says the file is gone. Whoever waits can stop waiting (its task is cancelled); the download
    /// goes on for the others and stops with the last. With `maxBytes`, a larger file that isn't on the device yet is
    /// refused with `APIError.tooLarge`, before any of it loads if the server names its size.
    func file(for url: URL, maxBytes: Int64? = nil) async throws -> URL {
        // A file on the device is where it is.
        if url.isFileURL { return url }
        if let file = loaded[url], FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        let waiter = UUID(), request = Request(url: url, maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait(continuation, as: waiter, for: request)
            }
        } onCancel: {
            Task { await self.leave(waiter, for: request) }
        }
    }

    /// The file's content, for what is read whole (a diagram's SVG).
    func data(for url: URL, maxBytes: Int64? = nil) async throws -> Data {
        try await Self.read(try await file(for: url, maxBytes: maxBytes))
    }

    /// Reads a file whole, off the main thread. Not mapped: the files are readable only while the device is
    /// unlocked, and a mapping touched after it locked would end the app.
    @concurrent static func read(_ file: URL) async throws -> Data {
        try Data(contentsOf: file)
    }

    private func wait(_ continuation: CheckedContinuation<URL, any Error>, as waiter: UUID, for request: Request) {
        // Cancelled before it began to wait: `leave` found nobody.
        if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
        if downloads[request] == nil {
            var download = Download()
            let id = download.id
            download.task = Task {
                let result: Result<URL, any Error>
                do {
                    result = .success(try await self.load(request))
                } catch {
                    result = .failure(error)
                }
                self.finish(id, for: request, with: result)
            }
            downloads[request] = download
        }
        downloads[request]?.waiters[waiter] = continuation
    }

    private func leave(_ waiter: UUID, for request: Request) {
        guard let continuation = downloads[request]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if downloads[request]?.waiters.isEmpty == true {
            downloads.removeValue(forKey: request)?.task?.cancel()
        }
    }

    /// `id`: a download that was stopped ends later, when another for the same file may wait already.
    private func finish(_ id: UUID, for request: Request, with result: Result<URL, any Error>) {
        guard downloads[request]?.id == id, let download = downloads.removeValue(forKey: request) else { return }
        for continuation in download.waiters.values { continuation.resume(with: result) }
    }

    private func load(_ request: Request) async throws -> URL {
        let url = request.url
        let key = "image/\(url.absoluteString)"
        do {
            let (download, _) = try await client.downloadFile(at: url, maxBytes: request.maxBytes)
            let file = try await keep(download, key: key)
            loaded[url] = file
            return file
        } catch {
            // Nobody waits any more.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Deleted on the server, or access to it removed: a saved copy must not stand in for it (review V28).
            if (error as? APIError)?.isGone == true {
                await cache?.remove(key: key)
                throw error
            }
            // Also for a file over the limit: one that is on the device already shows.
            if let saved = await cache?.dataFile(key: key) { return saved }
            throw error
        }
    }

    /// Moves a download to where it stays: the offline cache, or this session's folder if it is too large for that.
    private func keep(_ download: URL, key: String) async throws -> URL {
        do {
            let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if let cache, size <= maxCachedBytes {
                return try await cache.storeFile(at: download, key: key)
            }
            // The copy saved of an earlier, smaller version would stand in for this one offline.
            await cache?.remove(key: key)
            return try TempFile.move(download, into: sessionFolder)
        } catch {
            try? FileManager.default.removeItem(at: download)
            throw error
        }
    }

    // MARK: - Images

    /// The image at `url`, decoded for a width of `targetWidth` points.
    func image(for url: URL, targetWidth: CGFloat, scale: CGFloat, maxBytes: Int64? = nil) async throws -> UIImage {
        let pixelWidth = Self.pixelWidth(for: targetWidth, scale: scale)
        // 256 px buckets, so slightly different layout widths share a cache entry.
        let bucket = ((pixelWidth + 255) / 256) * 256
        let key = "\(url.absoluteString)@\(bucket)" as NSString
        if let cached = memory.object(forKey: key) {
            return cached
        }
        let file = try await file(for: url, maxBytes: maxBytes)
        guard let image = await Self.decode(file: file, targetPixelWidth: bucket) else {
            throw MediaUnreadable()
        }
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    /// Most pixels an image decodes to (about 48 MB): tall screenshots stay sharp in portrait on the iPhone; on wider
    /// screens (iPhone in landscape, iPad) they get slightly softer instead of taking up to 85 MB each.
    nonisolated static let maxPixels = 12_000_000.0
    /// Largest image decoded at all, about twice a 48 MP photo.
    nonisolated static let maxSourcePixels = 100_000_000.0

    /// The thumbnail size caps the longer side, so portrait images scale it by their height-to-width `ratio`, at most
    /// 4× (even taller images decode narrower), and the width shrinks to keep within `maxPixels`.
    nonisolated static func thumbnailSize(targetPixelWidth: Int, ratio: Double) -> Int {
        let tall = min(max(ratio, 1), 4)
        let target = Double(targetPixelWidth)
        let width = target * min(1, (maxPixels / (target * target * tall)).squareRoot())
        return Int((width * tall).rounded(.up))
    }

    /// Pixels for a width in points, bounded: a width from the document ("nan%", a huge negative number) can't be turned
    /// into an Int.
    nonisolated static func pixelWidth(for targetWidth: CGFloat, scale: CGFloat) -> Int {
        let pixels = (targetWidth * scale).rounded(.up)
        return pixels.isFinite ? Int(min(max(pixels, 64), 16_384)) : 64
    }

    /// Decodes an image file at the size it shows in, read from the file as the decoder needs it.
    @concurrent static func decode(file: URL, targetPixelWidth: Int, maxSourcePixels: Double = maxSourcePixels) async -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { return nil }
        return decode(source, targetPixelWidth: targetPixelWidth, maxSourcePixels: maxSourcePixels) {
            UIImage(contentsOfFile: file.path(percentEncoded: false))
        }
    }

    /// The same for an image in memory (an avatar).
    @concurrent static func decode(_ data: Data, targetPixelWidth: Int, maxSourcePixels: Double = maxSourcePixels) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return decode(source, targetPixelWidth: targetPixelWidth, maxSourcePixels: maxSourcePixels) { UIImage(data: data) }
    }

    private nonisolated static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    /// `whole`: the image as it is, for a format no thumbnail can be made of.
    private nonisolated static func decode(_ source: CGImageSource, targetPixelWidth: Int, maxSourcePixels: Double, whole: () -> UIImage?) -> UIImage? {
        var maxPixelSize = targetPixelWidth
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Double,
           let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 {
            // A small file that unpacks huge (a crafted avatar) would take the app's memory, also as a thumbnail.
            guard width * height <= maxSourcePixels else { return nil }
            // Orientations 5–8 turn the image 90°.
            let ratio = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 ? width / height : height / width
            maxPixelSize = thumbnailSize(targetPixelWidth: targetPixelWidth, ratio: ratio)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
            return UIImage(cgImage: cgImage)
        }
        return whole()
    }

    // MARK: - PDFs

    /// Opens a PDF file off the main thread. PDFKit reads its pages from the file as they show.
    @concurrent static func pdf(at file: URL) async -> PDFDocument? {
        struct Opened: @unchecked Sendable { let document: PDFDocument? }
        return Opened(document: PDFDocument(url: file)).document
    }
}
