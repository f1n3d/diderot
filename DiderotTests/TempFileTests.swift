import Foundation
import Testing
@testable import Diderot

/// Attachment and file names come from page content that any editor controls, so downloads must stay in their folder.
/// Serialized because `removeAll` deletes the folders the other test writes to.
@Suite(.serialized)
struct TempFileTests {
    @Test func namesStayInsideTheirFolder() throws {
        let id = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appending(path: "attachments/\(id)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let names = try ["../../x", "a/b.pdf", "..", "Report 2026.pdf"].map {
            try TempFile.write(Data("x".utf8), folder: ["attachments", id], name: $0).lastPathComponent
        }

        #expect(names == ["..-..-x", "a-b.pdf", "file", "Report 2026.pdf"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted() == names.sorted())
    }

    /// Downloads can hold a removed account's private attachments and exports.
    @Test func removeAllDeletesTheDownloads() throws {
        let files = try [
            TempFile.write(Data("x".utf8), folder: ["attachments", UUID().uuidString], name: "a.pdf"),
            TempFile.write(Data("x".utf8), folder: ["exports"], name: "b.md"),
        ]

        TempFile.removeAll()

        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
    }
}
