import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Diderot

struct UploadFileTests {
    /// Everyone sees upload names on the web, so the stamp ignores the uploader's calendar and digits.
    @Test func cameraNameHasGregorianStamp() throws {
        let file = try UploadFile.camera(Data())
        defer { file.remove() }
        let name = file.fileName
        let year = try #require(name.wholeMatch(of: /Foto-(\d{4})\d{4}-\d{6}\.jpg/.asciiOnlyDigits())?.1)
        #expect(Int(year) == Calendar(identifier: .gregorian).component(.year, from: .now))
    }

    /// The photo picker hands photos over with their location; the upload drops it and keeps the rest (date, size,
    /// every pixel: a JPEG isn't recompressed). A photo without a location stays byte for byte.
    @Test func photosLeaveTheirLocationBehind() throws {
        for type in [UTType.jpeg, .png] {
            let photo = try Self.image(type, location: true)
            #expect(try Self.properties(photo)[kCGImagePropertyGPSDictionary] != nil, "\(type): the test photo has no location")
            let uploaded = try UploadFile.withoutLocation(image: photo)
            let properties = try Self.properties(uploaded)
            #expect(properties[kCGImagePropertyGPSDictionary] == nil, "\(type)")
            #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:23 12:00:00", "\(type)")
            #expect(try Self.pixels(uploaded) == Self.pixels(photo), "\(type)")
        }
        let plain = try Self.image(.jpeg, location: false)
        #expect(try UploadFile.withoutLocation(image: plain) == plain)
    }

    /// A library video loses its location too, without being encoded anew.
    @Test func videosLeaveTheirLocationBehind() async throws {
        let video = try await Self.movie(location: "+48.1374+011.5755/")
        #expect(try await Self.hasLocation(video), "The test video has no location")
        // Staged as the picker's copy is: in a folder of its own, which the shared file then lies in.
        let folder = FileManager.default.temporaryDirectory.appending(path: "upload-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "original.mov")
        try video.write(to: original)
        let shared = try await UploadFile.withoutLocation(videoAt: original, type: .quickTimeMovie)
        #expect(!FileManager.default.fileExists(atPath: original.path), "the original goes")
        let uploaded = try Data(contentsOf: shared)
        #expect(try await !Self.hasLocation(uploaded))
        #expect(try await Self.asset(uploaded) { try await $0.load(.duration).seconds } > 0)
    }

    private static func image(_ type: UTType, location: Bool) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:23 12:00:00"]]
        if location {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 48.1374, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 11.5755, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The decoded image, to tell a new encoding from the same one.
    private static func pixels(_ data: Data) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    private static func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// A second of video with a location, as the camera records it.
    private static func movie(location: String) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        item.value = location as NSString
        writer.metadata = [item]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let frames = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: 64, height: 64)))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            let buffer = try #require(frames.pixelBufferPool).makeMutablePixelBuffer()
            try await frames.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        frames.finish()
        await writer.finishWriting()
        return try Data(contentsOf: url)
    }

    private static func hasLocation(_ video: Data) async throws -> Bool {
        try await asset(video) { try await $0.load(.metadata).contains { $0.identifier == .quickTimeMetadataLocationISO6709 } }
    }

    private static func asset<Value>(_ video: Data, _ read: (AVURLAsset) async throws -> Value) async throws -> Value {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try video.write(to: url)
        return try await read(AVURLAsset(url: url))
    }
}
