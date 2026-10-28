import Foundation
import ImageIO
import UIKit
import DocmostKit

/// Loads content images behind the API (bearer token), dedupes in-flight requests and downscales large images to
/// the target width while decoding. Raw data goes to the offline cache.
actor ImageLoader {
    private let client: APIClient
    private let cache: DiskCache?
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    /// Fetched from the network in this session: their offline copy is current, so decoding them at another width
    /// (rotation, columns) reads it instead of loading again.
    private var fetched: Set<URL> = []

    init(client: APIClient, cache: DiskCache? = nil) {
        self.client = client
        self.cache = cache
        memory.totalCostLimit = 150 << 20
    }

    func image(for url: URL, targetWidth: CGFloat, scale: CGFloat) async throws -> UIImage {
        let pixelWidth = Self.pixelWidth(for: targetWidth, scale: scale)
        // 256 px buckets, so slightly different layout widths share a cache entry.
        let bucket = ((pixelWidth + 255) / 256) * 256
        let key = "\(url.absoluteString)@\(bucket)" as NSString
        if let cached = memory.object(forKey: key) {
            return cached
        }
        if let task = inFlight[key as String] {
            return try await task.value
        }
        let task = Task<UIImage, Error> {
            let data = try await self.data(for: url)
            guard let image = await Self.decode(data, targetPixelWidth: bucket) else {
                throw APIError.decoding("image")
            }
            return image
        }
        inFlight[key as String] = task
        defer { inFlight[key as String] = nil }
        let image = try await task.value
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    /// Network first (once per session), offline cache on errors; successful responses are stored there. Also for
    /// PDFs and diagrams, so they show offline too.
    func data(for url: URL) async throws -> Data {
        let cacheKey = "image/\(url.absoluteString)"
        if fetched.contains(url), let cached = await cache?.readData(key: cacheKey) {
            return cached
        }
        do {
            let (data, _) = try await client.fetchFile(at: url)
            await cache?.writeData(data, key: cacheKey)
            fetched.insert(url)
            return data
        } catch {
            if let cached = await cache?.readData(key: cacheKey) {
                return cached
            }
            throw error
        }
    }

    /// Most pixels an image decodes to (about 48 MB): tall screenshots stay sharp in portrait on the iPhone; on wider
    /// screens (iPhone in landscape, iPad) they get slightly softer instead of taking up to 85 MB each.
    nonisolated static let maxPixels = 12_000_000.0

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

    @concurrent static func decode(_ data: Data, targetPixelWidth: Int) async -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        var maxPixelSize = targetPixelWidth
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Double,
           let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 {
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
        return UIImage(data: data)
    }
}
