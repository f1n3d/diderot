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
