import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Attachment and file names come from page content that any editor controls, so downloads must stay in their folder.
struct TempFileTests {
    /// A downloaded file, as the client hands it over.
    private func download() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        return file
    }

    @Test func namesStayInsideTheirFolder() throws {
        let server = URL(string: "https://temp-\(UUID().uuidString).example.com")!
        defer { TempFile.removeAll(server: server, uploads: true) }
        let id = UUID().uuidString
        let folder = TempFile.directory(server: server).appending(path: "attachments/\(id)")

        let names = try ["../../x", "a/b.pdf", "..", "Report 2026.pdf"].map {
            try TempFile.take(download(), server: server, folder: ["attachments", id], name: $0).lastPathComponent
        }

        #expect(names == ["..-..-x", "a-b.pdf", "file", "Report 2026.pdf"])
        // A download is moved, not copied, and one taken again under the same name replaces the first.
        let again = try download()
        #expect(try TempFile.take(again, server: server, folder: ["attachments", id], name: "a/b.pdf").lastPathComponent == "a-b.pdf")
        #expect(!FileManager.default.fileExists(atPath: again.path(percentEncoded: false)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count == names.count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted() == names.sorted())
    }

    /// An attachment goes from the network straight to its file for Quick Look, under its name: nothing of it is
    /// held in memory, as a large one took the app's (review M9).
    @Test func aDownloadGoesStraightToItsPlace() async throws {
        let server = URL(string: "https://temp-\(UUID().uuidString).example.com")!
        defer { TempFile.removeAll(server: server, uploads: true) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttachmentServer.self]
        let client = APIClient(baseURL: server, configuration: configuration)
        let url = server.appending(path: "api/files/abc/report.pdf")

        let file = try await TempFile.download(url, with: client, server: server, folder: ["attachments", "abc"], name: "../Report 2026.pdf")
        #expect(file.lastPathComponent == "..-Report 2026.pdf")
        #expect(file.deletingLastPathComponent() == TempFile.directory(server: server).appending(path: "attachments/abc", directoryHint: .isDirectory))
        #expect(try Data(contentsOf: file) == Data("attachment".utf8))

        // A file the server doesn't have leaves nothing behind.
        await #expect(throws: APIError.notFound(message: "Attachment not found")) {
            _ = try await TempFile.download(server.appending(path: "api/files/gone/x.pdf"), with: client, server: server, folder: ["attachments", "gone"], name: "x.pdf")
        }
        #expect(!FileManager.default.fileExists(atPath: TempFile.directory(server: server).appending(path: "attachments/gone/x.pdf").path(percentEncoded: false)))
    }

    /// Downloads can hold a removed account's private attachments and exports. Each server's go on their own: removing
    /// one server took every server's, also a running upload's staged file. "Clear Saved Content" leaves staged uploads.
    @Test func removeAllDeletesOnlyThatServersFiles() throws {
        let server = URL(string: "https://temp-\(UUID().uuidString).example.com")!
        let other = URL(string: "https://temp-\(UUID().uuidString).example.com")!
        defer { TempFile.removeAll(server: other, uploads: true) }
        let downloads = try [
            TempFile.take(download(), server: server, folder: ["attachments", UUID().uuidString], name: "a.pdf"),
            TempFile.take(download(), server: server, folder: ["exports"], name: "b.md"),
            // A file too large for the offline cache, in a media loader's folder; its copy for sharing.
            TempFile.move(TempFile.take(download(), server: server, folder: ["attachments"], name: "c.pdf"), into: TempFile.sessionMedia(server: server)),
        ]
        let shared = try TempFile.copy(downloads[2], server: server, folder: ["attachments", "shared"], name: "c/../d.pdf")
        #expect(shared.lastPathComponent == "c-..-d.pdf")
        #expect(try Data(contentsOf: shared) == Data("x".utf8))
        let upload = try UploadFile.camera(Data("x".utf8), server: server)
        let othersDownload = try TempFile.take(download(), server: other, folder: ["exports"], name: "c.md")
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

/// Answers with a file, or as Docmost does for one it doesn't have (a path with "gone").
private nonisolated final class AttachmentServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let isGone = url.path.contains("gone")
        let body = Data((isGone ? #"{"statusCode":404,"message":"Attachment not found"}"# : "attachment").utf8)
        let response = HTTPURLResponse(url: url, statusCode: isGone ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
