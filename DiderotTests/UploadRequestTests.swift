import DocmostKit
import Foundation
import Synchronization
import Testing
@testable import Diderot

/// The upload the app sends, from the staged file on disk (code review R32): what reaches the server, the body file
/// written beside the staged one, and errors that keep their cause.
@Suite(.serialized)
struct UploadRequestTests {
    /// The body is the staged file between its multipart head and tail, sent from a file of its own beside it, which goes
    /// afterwards, also when the server refuses. A quote or a line break in the name can't end its header.
    @Test func uploadSendsTheFileAndRemovesItsBody() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appending(path: "staged")
        let content = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })  // more than one 1 MB chunk
        try content.write(to: staged)
        UploadRecorder.reset(watching: folder)
        let client = Self.client()

        let attachment = try await client.uploadAttachment(
            pageId: "p1", fileName: "a\"b\r\nX-Injected: 1.bin", mimeType: "application/octet-stream", fileURL: staged)
        #expect(attachment.id == "a1")
        let sent = try #require(UploadRecorder.bodies.withLock { $0 }.first)
        let file = try #require(sent.range(of: content), "The file isn't in the body in one piece")
        let head = String(decoding: sent[..<file.lowerBound], as: UTF8.self)
        #expect(head.contains(#"name="pageId"\#r\#n\#r\#np1\#r\#n"#))
        #expect(head.hasSuffix("filename=\"a_b__X-Injected: 1.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"), "\(head)")
        let tail = String(decoding: sent[file.upperBound...], as: UTF8.self)
        #expect(tail.hasPrefix("\r\n--") && tail.hasSuffix("--\r\n") && tail.count(where: \.isNewline) == 2, "\(tail)")
        #expect(UploadRecorder.listings.withLock { $0 }.first?.count == 2, "No body file beside the staged one")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["staged"], "The body file stayed")

        UploadRecorder.status.withLock { $0 = 500 }
        await #expect(throws: APIError.server(status: 500, message: nil)) {
            try await client.uploadAttachment(pageId: "p1", fileName: "a.bin", mimeType: "application/octet-stream", fileURL: staged)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["staged"], "A refused upload's body file stayed")
    }

    /// A staged file that's gone (signing out removes it, also mid-upload) fails with its own cause, not "Invalid response
    /// from server.": with its folder gone, the body file can't be written; with the folder there, the file can't be read.
    /// So does an upload that fails for another reason than the network.
    @Test func failuresKeepTheirCause() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        UploadRecorder.reset(watching: folder)
        let client = Self.client()
        for staged in [folder.appending(path: "gone/staged"), folder.appending(path: "staged")] {
            await #expect(throws: CocoaError.self, "\(staged.path)") {
                try await client.uploadAttachment(pageId: "p1", fileName: "a.bin", mimeType: "application/octet-stream", fileURL: staged)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "A body file stayed")
        #expect(UploadRecorder.bodies.withLock { $0 }.isEmpty, "A request went out")

        let staged = folder.appending(path: "staged")
        try Data("x".utf8).write(to: staged)
        UploadRecorder.failure.withLock { $0 = CocoaError(.fileReadNoPermission) }
        let error = await #expect(throws: CocoaError.self) {
            try await client.uploadAttachment(pageId: "p1", fileName: "a.bin", mimeType: "application/octet-stream", fileURL: staged)
        }
        #expect(error?.code == .fileReadNoPermission)
    }

    private static func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadRecorder.self]
        return APIClient(baseURL: URL(string: "https://upload.example.com")!, token: "t", configuration: configuration)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "upload-request-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Answers uploads as `files/upload` does, and keeps what each one sent and which files its folder held meanwhile.
private nonisolated final class UploadRecorder: URLProtocol, @unchecked Sendable {
    static let bodies = Mutex<[Data]>([])
    static let listings = Mutex<[[String]]>([])
    static let watched = Mutex<URL?>(nil)
    static let status = Mutex(200)
    /// Fails the next requests with this error instead of answering.
    static let failure = Mutex<(any Error)?>(nil)

    static func reset(watching folder: URL) {
        bodies.withLock { $0 = [] }
        listings.withLock { $0 = [] }
        watched.withLock { $0 = folder }
        status.withLock { $0 = 200 }
        failure.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let folder = Self.watched.withLock({ $0 }) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            Self.listings.withLock { $0.append(names.sorted()) }
        }
        if let error = Self.failure.withLock({ $0 }) {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                body.append(contentsOf: buffer[..<count])
            }
        }
        Self.bodies.withLock { $0.append(body) }
        let status = Self.status.withLock { $0 }
        let answer = status == 200 ? #"{"id": "a1", "fileName": "a.bin"}"# : #"{"statusCode": 500, "message": null}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
