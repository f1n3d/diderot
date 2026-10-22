import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file to upload from Photos, the camera or Files (editor and database file properties).
nonisolated struct UploadFile: Sendable {
    let data: Data
    let fileName: String
    let mimeType: String

    /// Library photo or video. Images other than JPEG, PNG and GIF upload as JPEG: the web client can't show HEIC/HEIF.
    @concurrent static func photo(_ item: PhotosPickerItem) async throws -> UploadFile? {
        guard var data = try await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        var ext = type?.preferredFilenameExtension ?? "jpg"
        var mime = type?.preferredMIMEType ?? "image/jpeg"
        if let type, type.conforms(to: .image), !type.conforms(to: .jpeg), !type.conforms(to: .png), !type.conforms(to: .gif),
           let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9)
        {
            data = jpeg
            ext = "jpg"
            mime = "image/jpeg"
        }
        let name = type?.conforms(to: .movie) == true ? "Video" : "Bild"
        return UploadFile(data: data, fileName: "\(name)-\(stamp()).\(ext)", mimeType: mime)
    }

    /// JPEG from the camera.
    static func camera(_ data: Data) -> UploadFile {
        UploadFile(data: data, fileName: "Foto-\(stamp()).jpg", mimeType: "image/jpeg")
    }

    /// File from the file importer (security-scoped URL).
    @concurrent static func file(at url: URL) async throws -> UploadFile {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return UploadFile(data: data, fileName: url.lastPathComponent, mimeType: mime)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}
