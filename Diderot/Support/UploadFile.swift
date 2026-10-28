import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file to upload from Photos, the camera or Files (editor and database file properties), staged on disk: held in
/// memory, a large video (or many photos) took the app's memory, twice while its location was removed. `remove` deletes
/// it once uploaded.
nonisolated struct UploadFile: Sendable {
    let fileURL: URL
    let fileName: String
    let mimeType: String

    /// One folder per upload under tmp/uploads (`TempFile.removeAll` clears what a crash left).
    static let folder = FileManager.default.temporaryDirectory.appending(path: "uploads", directoryHint: .isDirectory)

    private static func stagingFolder() throws -> URL {
        let folder = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func staged(_ data: Data, fileName: String, mimeType: String) throws -> UploadFile {
        let url = try stagingFolder().appending(path: "file")
        try data.write(to: url, options: .completeFileProtection)
        return UploadFile(fileURL: url, fileName: fileName, mimeType: mimeType)
    }

    /// Deletes the staged copy.
    func remove() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// A library video as a file, not as data: `Data.self` read it whole into memory.
    private struct VideoFile: Transferable {
        let url: URL
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .movie) { received in
                let copy = try UploadFile.stagingFolder().appending(path: "original.\(received.file.pathExtension)")
                try FileManager.default.copyItem(at: received.file, to: copy)
                return VideoFile(url: copy)
            }
        }
    }

    /// Library photo or video, without its location: the photo picker hands it over "with location" unless that is
    /// switched off, and everyone who can read the page could download it. Images other than JPEG, PNG and GIF upload
    /// as JPEG: the web client can't show HEIC/HEIF.
    @concurrent static func photo(_ item: PhotosPickerItem) async throws -> UploadFile? {
        let type = item.supportedContentTypes.first
        if let type, type.conforms(to: .movie) {
            guard let video = try await item.loadTransferable(type: VideoFile.self) else { return nil }
            let shared = try await withoutLocation(videoAt: video.url, type: type)
            return UploadFile(fileURL: shared, fileName: "Video-\(stamp()).\(shared.pathExtension)",
                              mimeType: type.preferredMIMEType ?? "video/quicktime")
        }
        guard var data = try await item.loadTransferable(type: Data.self) else { return nil }
        var ext = type?.preferredFilenameExtension ?? "jpg"
        var mime = type?.preferredMIMEType ?? "image/jpeg"
        if let type, type.conforms(to: .image), !type.conforms(to: .jpeg), !type.conforms(to: .png), !type.conforms(to: .gif),
           let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9)
        {
            // Encoded anew, it keeps no metadata, the location included.
            data = jpeg
            ext = "jpg"
            mime = "image/jpeg"
        } else {
            data = try withoutLocation(image: data)
        }
        return try staged(data, fileName: "Bild-\(stamp()).\(ext)", mimeType: mime)
    }

    /// The image without its location; one without a location stays as it is. A JPEG keeps its encoding (only its
    /// metadata is written anew), other formats are encoded anew with the rest of their metadata (PNG losslessly).
    /// ImageIO's own "exclude GPS" option misses PNG's and drops a JPEG's other metadata.
    static func withoutLocation(image data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              hasLocation(source)
        else { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, CGImageSourceGetCount(source), nil) else {
            throw LocationNotRemoved()
        }
        if (type as String) == UTType.jpeg.identifier, let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let kept = CGImageMetadataCreateMutableCopy(metadata)
        {
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                if (CGImageMetadataTagCopyName(tag) as String?)?.hasPrefix("GPS") == true { CGImageMetadataRemoveTagWithPath(kept, nil, path) }
                return true
            }
            let options = [kCGImageDestinationMetadata: kept, kCGImageDestinationMergeMetadata: false] as CFDictionary
            guard CGImageDestinationCopyImageSource(destination, source, options, nil) else { throw LocationNotRemoved() }
        } else {
            for index in 0..<CGImageSourceGetCount(source) {
                CGImageDestinationAddImageFromSource(destination, source, index, [kCGImagePropertyGPSDictionary: kCFNull] as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw LocationNotRemoved() }
        }
        // Checked, not trusted: rather no upload than one with the location.
        guard let result = CGImageSourceCreateWithData(output, nil), !hasLocation(result) else { throw LocationNotRemoved() }
        return output as Data
    }

    private static func hasLocation(_ source: CGImageSource) -> Bool {
        (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary] != nil
    }

    /// The video at `input` (staged, in its own folder) without its location and other personal metadata (what sharing
    /// keeps), not encoded anew: the exported file beside it, file to file; the original goes. If that fails, it
    /// doesn't upload rather than with the location, and its folder goes.
    @concurrent static func withoutLocation(videoAt input: URL, type: UTType) async throws -> URL {
        let fileType: AVFileType = type.conforms(to: .mpeg4Movie) ? .mp4 : .mov
        let output = input.deletingLastPathComponent().appending(path: "shared.\(fileType == .mp4 ? "mp4" : "mov")")
        do {
            guard let export = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetPassthrough) else {
                throw LocationNotRemoved()
            }
            export.metadataItemFilter = .forSharing()
            try await export.export(to: output, as: fileType)
            try? FileManager.default.removeItem(at: input)
            // Best effort, as the export picks its own: the simulator refuses to set it.
            try? (output as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
            return output
        } catch {
            AppLog.ui.error("Video location not removed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: input.deletingLastPathComponent())
            throw LocationNotRemoved()
        }
    }

    struct LocationNotRemoved: LocalizedError {
        var errorDescription: String? { String(localized: "The location couldn't be removed from the photo or video, so it wasn't uploaded.") }
    }

    /// JPEG from the camera.
    static func camera(_ data: Data) throws -> UploadFile {
        try staged(data, fileName: "Foto-\(stamp()).jpg", mimeType: "image/jpeg")
    }

    /// File from the file importer (security-scoped URL), copied file to file.
    @concurrent static func file(at url: URL) async throws -> UploadFile {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let copy = try stagingFolder().appending(path: "file")
        try FileManager.default.copyItem(at: url, to: copy)
        try? (copy as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return UploadFile(fileURL: copy, fileName: url.lastPathComponent, mimeType: mime)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}
