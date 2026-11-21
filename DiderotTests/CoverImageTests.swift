import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Diderot

/// A picked image made into a cover the server takes (`CoverImage`): JPG, PNG or WebP of at most 5 MB.
struct CoverImageTests {
    /// A large photo (noise, which compresses worst) is scaled to 2560 pixels and loses quality, then pixels, until it
    /// is within the server's 5 MB; it goes as a JPEG.
    @Test func aLargePhotoFitsTheServersLimit() throws {
        let photo = try Self.encoded(Self.noise(width: 4000, height: 3000), as: .tiff)
        #expect(photo.count > CoverImage.maxBytes)
        let file = try CoverImage.prepare(photo, name: nil)
        #expect(file.data.count <= CoverImage.maxBytes)
        #expect(file.data.count <= 5 * 1024 * 1024)
        #expect(file.mimeType == "image/jpeg" && file.fileName.hasPrefix("Cover-") && file.fileName.hasSuffix(".jpg"))
        let (type, width, height) = try Self.read(file.data)
        #expect(type == UTType.jpeg.identifier)
        #expect(max(width, height) <= CoverImage.maxDimension)
    }

    /// The steps end where the file fits, however small the limit, and say so where nothing does.
    @Test func smallerStepsUntilItFits() throws {
        let photo = try Self.encoded(Self.noise(width: 800, height: 600), as: .png)
        let file = try CoverImage.prepare(photo, name: "Noise.png", maxBytes: 300_000)
        #expect(file.data.count <= 300_000)
        #expect(file.fileName == "Noise.jpg" && file.mimeType == "image/jpeg")
        #expect(throws: CoverImage.Unusable.tooLarge) { try CoverImage.prepare(photo, name: nil, maxBytes: 2_000) }
    }

    /// A small JPEG goes as it is, as the web keeps one, but without its location; its name keeps an extension the server
    /// knows for it and gets one where it hasn't.
    @Test func aSmallJPEGGoesAsItIs() throws {
        let photo = try Self.encoded(Self.noise(width: 400, height: 300), as: .jpeg, location: true)
        let file = try CoverImage.prepare(photo, name: "Holiday.JPG")
        #expect(file.fileName == "Holiday.JPG" && file.mimeType == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(file.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(try Self.read(file.data).width == 400)
        #expect(try CoverImage.prepare(photo, name: "photo.jfif").fileName == "photo.jpg")
    }

    /// Other formats (a TIFF here, HEIC from the camera) go as JPEG; a transparent image as PNG, which iOS writes where
    /// the web writes WebP.
    @Test func otherFormatsAreEncodedAnew() throws {
        let tiff = try CoverImage.prepare(try Self.encoded(Self.noise(width: 300, height: 200), as: .tiff), name: "Scan.tiff")
        #expect(tiff.fileName == "Scan.jpg" && tiff.mimeType == "image/jpeg")
        #expect(try Self.read(tiff.data).type == UTType.jpeg.identifier)

        let transparent = try CoverImage.prepare(try Self.encoded(Self.fade(width: 3000, height: 1000), as: .png), name: "Logo.png")
        #expect(transparent.fileName == "Logo.png" && transparent.mimeType == "image/png")
        let (type, width, _) = try Self.read(transparent.data)
        #expect(type == UTType.png.identifier && width == CoverImage.maxDimension)
    }

    /// What isn't an image says which ones are.
    @Test func whatIsntAnImageSaysWhichAre() {
        #expect(throws: CoverImage.Unusable.unreadable) { try CoverImage.prepare(Data("not an image".utf8), name: "notes.txt") }
        #expect(CoverImage.Unusable.unreadable.localizedDescription == String(localized: "Use a JPG, PNG or WebP image."))
    }

    // MARK: - Images

    /// Random opaque pixels from a fixed start: they compress worst, so every step of the conversion counts.
    private static func noise(width: Int, height: Int) throws -> CGImage {
        var random = SeededRandom(seed: 42)
        var pixels = [UInt64](repeating: 0, count: width * height / 2 + 1)
        for index in pixels.indices {
            pixels[index] = random.next()
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Orange fading out to the right: transparent.
    private static func fade(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 0)] as CFArray
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        return try #require(context.makeImage())
    }

    private static func encoded(_ image: CGImage, as type: UTType, location: Bool = false) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if location {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 48.1374, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 11.5755, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func read(_ data: Data) throws -> (type: String, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try #require(CGImageSourceGetType(source)) as String, try #require(properties[kCGImagePropertyPixelWidth] as? Int),
                try #require(properties[kCGImagePropertyPixelHeight] as? Int))
    }
}
