import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A picked image made into a file the server takes as a page's cover (Docmost 0.98: JPG, PNG or WebP by the name's
/// extension, at most 5 MB), as the web's `compressCoverImage` does: a JPEG, PNG or WebP of up to 1.5 MB and 2560 pixels
/// goes as it is (without its location); anything else (a photo in HEIC, a larger file) is encoded anew at up to 2560
/// pixels, with less quality and then fewer pixels until it fits. The web writes a transparent image as WebP, which iOS
/// can't write: it goes as PNG. Encoded anew, it keeps no metadata, the location included.
nonisolated enum CoverImage {
    struct File: Sendable {
        let data: Data
        let fileName: String
        let mimeType: String
    }

    enum Unusable: LocalizedError {
        /// Not an image ImageIO reads.
        case unreadable
        /// Over `maxBytes` even at the smallest step.
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "Use a JPG, PNG or WebP image.")
            case .tooLarge: String(localized: "Failed to upload image")
            }
        }
    }

    /// The server's limit.
    static let maxBytes = 5 * 1024 * 1024
    static let maxDimension = 2560
    /// Up to this size an image that needs no scaling goes as it is (`COVER_COMPRESS_THRESHOLD`).
    static let keepsBytes = 1_572_864
    /// Quality goes down before size, so the cover stays as sharp as it can (`encodeWithinLimit`).
    static let qualitySteps: [Double] = [0.85, 0.7, 0.55, 0.4]
    static let scaleSteps: [Double] = [1, 0.75, 0.5625, 0.421875]

    /// The types the server takes, with the extensions it knows them by (the first is written for a converted file).
    private static let extensions: [(type: UTType, mimeType: String, extensions: [String])] = [
        (.jpeg, "image/jpeg", ["jpg", "jpeg"]), (.png, "image/png", ["png"]), (.webP, "image/webp", ["webp"]),
    ]

    /// Off the main thread, as the others: decoding and encoding a large photo takes a moment.
    @concurrent static func file(from data: Data, name: String?) async throws -> File {
        try prepare(data, name: name)
    }

    /// A photo from the library, as it is stored there (HEIC from the camera); nil if it doesn't come.
    @concurrent static func file(from item: PhotosPickerItem) async throws -> File? {
        guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
        return try prepare(data, name: nil)
    }

    /// An image from Files, read in its security scope.
    @concurrent static func file(at url: URL) async throws -> File {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try prepare(Data(contentsOf: url), name: url.lastPathComponent)
    }

    /// `name`: the picked file's, whose base the upload keeps; a photo from the library has none.
    static func prepare(_ data: Data, name: String?, maxBytes: Int = maxBytes) throws -> File {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw Unusable.unreadable }
        let base = baseName(name)
        let longer = max(width, height)
        let downscaled = longer > maxDimension
        let original = CGImageSourceGetType(source).flatMap { type in extensions.first { $0.type.identifier == type as String } }
        // As it is: a JPEG, PNG or WebP that needs no scaling and is small already.
        if let original, !downscaled, data.count <= min(keepsBytes, maxBytes), let kept = try? UploadFile.withoutLocation(image: data) {
            return File(data: kept, fileName: fileName(base, name: name, extensions: original.extensions), mimeType: original.mimeType)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longer, maxDimension),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw Unusable.unreadable }
        let transparent = isTransparent(image)
        let type = transparent ? extensions[1] : extensions[0]
        for scale in scaleSteps {
            guard let scaled = scale == 1 ? image : resized(image, by: scale, transparent: transparent) else { continue }
            for quality in transparent ? [1] : qualitySteps {
                guard let encoded = encode(scaled, as: type.type, quality: quality), encoded.count <= maxBytes else { continue }
                // An image that needed no scaling stays as it was where encoding it anew made it larger.
                if let original, !downscaled, data.count < encoded.count, let kept = try? UploadFile.withoutLocation(image: data) {
                    return File(data: kept, fileName: fileName(base, name: name, extensions: original.extensions), mimeType: original.mimeType)
                }
                return File(data: encoded, fileName: base + "." + type.extensions[0], mimeType: type.mimeType)
            }
        }
        throw Unusable.tooLarge
    }

    /// The picked file's name without its extension, or a dated one for a photo, as the app names uploads from Photos.
    private static func baseName(_ name: String?) -> String {
        let base = name.map { ($0 as NSString).deletingPathExtension } ?? ""
        if !base.isEmpty { return base }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Cover-" + formatter.string(from: .now)
    }

    /// The server takes the type from the extension (`withCoverExtension`): one it knows for the type stays.
    private static func fileName(_ base: String, name: String?, extensions: [String]) -> String {
        if let name, extensions.contains((name as NSString).pathExtension.lowercased()) { return name }
        return base + "." + extensions[0]
    }

    /// Whether any pixel lets the background through (`canvasHasAlpha`); an image without an alpha channel doesn't.
    private static func isTransparent(_ image: CGImage) -> Bool {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return false }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return stride(from: 3, to: width * height * 4, by: 4).contains { bytes[$0] < 255 }
    }

    /// In the image's own colors where they are RGB (a photo's Display P3 stays), else in sRGB.
    private static func resized(_ image: CGImage, by scale: Double, transparent: Bool) -> CGImage? {
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: alpha.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
