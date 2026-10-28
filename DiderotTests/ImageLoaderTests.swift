import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Diderot

/// Content images fill the available width, so portrait images (phone screenshots) must decode that wide.
struct ImageLoaderTests {
    @Test func portraitImagesDecodeAtTheTargetWidth() async throws {
        // 1000×3000 upright, and 3000×1000 pixels that EXIF orientation 6 shows rotated to 1000×3000.
        for (width, height, orientation) in [(1000, 3000, 1), (3000, 1000, 6)] {
            let data = try jpeg(width: width, height: height, orientation: orientation)
            let image = try #require(await ImageLoader.decode(data, targetPixelWidth: 512))
            #expect(image.size.width >= 512, "orientation \(orientation)")
        }
    }

    /// Tall images decode at the full target width up to `maxPixels` (an iPhone in portrait), narrower beyond (an
    /// iPhone in landscape); wide ones at the target width.
    @Test func tallImagesKeepToThePixelBudget() {
        #expect(ImageLoader.thumbnailSize(targetPixelWidth: 1280, ratio: 4) == 5120)
        let landscape = ImageLoader.thumbnailSize(targetPixelWidth: 2560, ratio: 4)
        #expect(Double(landscape) * Double(landscape) / 4 <= ImageLoader.maxPixels * 1.001)
        #expect(landscape > 6000)
        #expect(ImageLoader.thumbnailSize(targetPixelWidth: 2560, ratio: 0.5) == 2560)
    }

    /// Media from another host loads only after a tap, unless Settings turns that on; the server's own always loads.
    @Test func otherServersLoadOnlyWhenAllowed() {
        let server = URL(string: "https://wiki.example.com")!
        let key = RenderContext.loadsOtherServersKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        #expect(RenderContext.loadsByItself(URL(string: "https://wiki.example.com/api/files/a/b.png")!, server: server))
        #expect(!RenderContext.loadsByItself(URL(string: "https://tracker.example.net/p.png")!, server: server))
        #expect(!RenderContext.loadsByItself(URL(string: "http://wiki.example.com/b.png")!, server: server), "another scheme is another origin")
        #expect(RenderContext.loadsByItself(URL.temporaryDirectory.appending(path: "clip.mov"), server: server), "a file on the device")
        UserDefaults.standard.set(true, forKey: key)
        #expect(RenderContext.loadsByItself(URL(string: "https://tracker.example.net/p.png")!, server: server))
    }

    /// A width from the document such as "nan%" or a huge negative number gives a bounded pixel width: turning it into an
    /// Int trapped, for everyone who saw the image.
    @Test func pixelWidthsStayInBounds() {
        #expect(ImageLoader.pixelWidth(for: -1e20, scale: 3) == 64)
        #expect(ImageLoader.pixelWidth(for: .nan, scale: 3) == 64)
        #expect(ImageLoader.pixelWidth(for: 1e20, scale: 3) == 16_384)
        #expect(ImageLoader.pixelWidth(for: 300, scale: 3) == 900)
    }

    /// An image larger than the source limit isn't decoded at all, not even as a thumbnail: a file that is small as such
    /// but huge unpacked (a member's crafted avatar) took the app's memory wherever it showed.
    @Test func sourcesOverTheLimitAreNotDecoded() async throws {
        let data = try jpeg(width: 400, height: 300, orientation: 1)
        #expect(await ImageLoader.decode(data, targetPixelWidth: 100, maxSourcePixels: 100_000) == nil)
        #expect(await ImageLoader.decode(data, targetPixelWidth: 100, maxSourcePixels: 200_000) != nil)
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
