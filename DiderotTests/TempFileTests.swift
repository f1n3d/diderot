import Foundation
import Testing
@testable import Diderot

/// Attachment and file names come from page content that any editor controls, so downloads must stay in their folder.
struct TempFileTests {
    @Test func namesStayInsideTheirFolder() throws {
        let server = URL(string: "https://temp-\(UUID().uuidString).example.com")!
        defer { TempFile.removeAll(server: server, uploads: true) }
        let id = UUID().uuidString
        let folder = TempFile.directory(server: server).appending(path: "attachments/\(id)")

        let names = try ["../../x", "a/b.pdf", "..", "Report 2026.pdf"].map {
            try TempFile.write(Data("x".utf8), server: server, folder: ["attachments", id], name: $0).lastPathComponent
        }

        #expect(names == ["..-..-x", "a-b.pdf", "file", "Report 2026.pdf"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted() == names.sorted())
    }

    /// Downloads can hold a removed account's private attachments and exports. Each server's go on their own: removing
    /// one server took every server's, also a running upload's staged file. "Clear Saved Content" leaves staged uploads.
    @Test func removeAllDeletesOnlyThatServersFiles() throws {
        let server = URL(string: "https://temp-\(UUID().uuidString).example.com")!
        let other = URL(string: "https://temp-\(UUID().uuidString).example.com")!
        defer { TempFile.removeAll(server: other, uploads: true) }
        let downloads = try [
            TempFile.write(Data("x".utf8), server: server, folder: ["attachments", UUID().uuidString], name: "a.pdf"),
            TempFile.write(Data("x".utf8), server: server, folder: ["exports"], name: "b.md"),
        ]
        let upload = try UploadFile.camera(Data("x".utf8), server: server)
        let othersDownload = try TempFile.write(Data("x".utf8), server: other, folder: ["exports"], name: "c.md")
        let othersUpload = try UploadFile.camera(Data("x".utf8), server: other)
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

        TempFile.removeAll(server: server, uploads: false)
        #expect(!downloads.contains(where: exists))
        #expect(exists(upload.fileURL), "a running upload reads it")

        TempFile.removeAll(server: server, uploads: true)
        #expect(!exists(upload.fileURL))
        #expect(exists(othersDownload) && exists(othersUpload.fileURL))
    }
}
