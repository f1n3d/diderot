import Foundation
import Synchronization
import Testing
@testable import DocmostKit

extension MockedNetworkingTests {
/// Files go from the network into a file, not through memory, by the rules of every request: the token only to the
/// server, no redirects there, the server's own errors. A download that is refused, or larger than asked for, leaves
/// no file behind.
struct DownloadTests {
    private let report = URL(string: "http://localhost:3000/api/files/abc/report.pdf")!

    private func content(_ count: Int = 64) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// The files in the client's downloads folder: what a download that failed must not leave. Only this suite
    /// downloads, and it runs one test at a time.
    private func downloads() -> Set<String> {
        let files = FileManager.default.enumerator(at: APIClient.downloadsDirectory, includingPropertiesForKeys: [.isRegularFileKey])
        return Set((files?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.path))
    }

    @Test func aFileGoesToAFileByTheRulesOfARequest() async throws {
        let content = content()
        MockURLProtocol.respond(with: .init(headers: ["Content-Type": "application/pdf"], body: content))
        let paths = Mutex<[String]>([])
        let client = TestSupport.mockClient(token: "abc", logger: { entry in paths.withLock { $0.append(entry.path) } })
        let (file, response) = try await client.downloadFile(at: report)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == content)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/pdf")
        #expect(MockURLProtocol.recordedRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        // File names are user content: only the folder is logged.
        #expect(paths.withLock { $0 } == ["/api/files/abc"])

        // Another host, which page content may link, gets no token.
        MockURLProtocol.respond(with: .init(body: content))
        let (other, _) = try await client.downloadFile(at: URL(string: "https://elsewhere.example/a.pdf")!)
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(try Data(contentsOf: other) == content)
        #expect(MockURLProtocol.recordedRequests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// URLSession downloads an error's body like any other: the client reads the server's message from it and removes it.
    @Test func aRefusedDownloadLeavesNoFile() async throws {
        let before = downloads()
        let notFound = try TestSupport.fixture("error-404")
        MockURLProtocol.respond(with: .init(status: 404, body: notFound))
        await #expect(throws: APIError.notFound(message: "Space not found")) {
            _ = try await TestSupport.mockClient().downloadFile(at: report)
        }
        #expect(downloads() == before)

        // Another host's answer isn't Docmost's, whatever its body says (review V20), and its file goes too.
        let unauthorized = Data(#"{"statusCode":401,"message":"Unauthorized"}"#.utf8)
        MockURLProtocol.respond(with: .init(status: 401, body: unauthorized))
        await #expect(throws: APIError.server(status: 401, message: nil)) {
            _ = try await TestSupport.mockClient().downloadFile(at: URL(string: "https://elsewhere.example/a.pdf")!)
        }
        #expect(downloads() == before)
    }

    @Test func aDownloadFromTheServerDoesntFollowRedirects() async throws {
        let before = downloads()
        let elsewhere = URL(string: "http://elsewhere.example/report.pdf")!
        let content = content()
        MockURLProtocol.respond(with: .init(status: 307, body: content, redirect: elsewhere))
        await #expect(throws: APIError.server(status: 307, message: "The server redirects to \(elsewhere.absoluteString).")) {
            _ = try await TestSupport.mockClient().downloadFile(at: report)
        }
        #expect(MockURLProtocol.recordedRequests.map(\.url) == [report])
        #expect(downloads() == before)
    }

    /// A file larger than asked for is refused, whether the answer names its size or not, and nothing of it stays.
    @Test(arguments: [true, false])
    func aFileOverTheLimitIsRefused(namesItsSize: Bool) async throws {
        let before = downloads()
        let content = content(2000)
        let headers = namesItsSize ? ["Content-Length": "2000"] : [:]
        MockURLProtocol.respond(with: .init(headers: headers, body: content))
        await #expect(throws: APIError.tooLarge(limit: 1000)) {
            _ = try await TestSupport.mockClient().downloadFile(at: report, maxBytes: 1000)
        }
        #expect(downloads() == before)

        // The limit itself is still within it. (The client stays: its downloads go with it.)
        MockURLProtocol.respond(with: .init(headers: headers, body: content))
        let client = TestSupport.mockClient()
        let (file, _) = try await client.downloadFile(at: report, maxBytes: 2000)
        #expect(try Data(contentsOf: file) == content)
        withExtendedLifetime(client) { try? FileManager.default.removeItem(at: file) }
    }

    /// Scrolling past an image cancels its download. A task cancelled before its request ran used to be the hard case:
    /// its end can come before anyone waits for it.
    @Test func aCancelledDownloadLeavesNoFile() async throws {
        let before = downloads()
        MockURLProtocol.respond(with: .init(body: content()))
        let client = TestSupport.mockClient()
        let report = report
        let download = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.downloadFile(at: report)
        }
        await #expect(throws: CancellationError.self) { _ = try await download.value }
        #expect(downloads() == before)
    }

    /// An error's long answer (a proxy's page) is kept up to its first 64 KB, in order, whatever pieces it comes in;
    /// the server's message is at its start.
    @Test func aLongErrorAnswerStillGivesTheMessage() async throws {
        let before = downloads()
        let page = Data(#"{"statusCode":404,"message":"Attachment not found","padding":""#.utf8) + Data(repeating: 0x78, count: 200_000) + Data(#""}"#.utf8)
        MockURLProtocol.respond(with: .init(status: 404, body: page))
        // Cut off, the body is no JSON any more: the status alone speaks.
        await #expect(throws: APIError.server(status: 404, message: nil)) {
            _ = try await TestSupport.mockClient().downloadFile(at: report)
        }
        #expect(downloads() == before)
    }

    /// A download nobody took goes with its client, and the app's start clears what an ended app left.
    @Test func downloadsGoWithTheirClient() async throws {
        MockURLProtocol.respond(with: .init(body: content()))
        var client: APIClient? = TestSupport.mockClient()
        let (file, _) = try await client!.downloadFile(at: report)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        client = nil
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        MockURLProtocol.respond(with: .init(body: content()))
        let other = TestSupport.mockClient()
        let (left, _) = try await other.downloadFile(at: report)
        APIClient.removeAbandonedDownloads()
        #expect(!FileManager.default.fileExists(atPath: left.path(percentEncoded: false)))
        #expect(downloads().isEmpty)
    }

    /// A page export is an endpoint whose answer is the file, named in `Content-Disposition`.
    @Test func anEndpointsFileIsDownloaded() async throws {
        let content = content()
        MockURLProtocol.respond(with: .init(headers: ["Content-Disposition": #"attachment; filename="Page.md""#], body: content))
        let client = TestSupport.mockClient(token: "abc")
        let (file, response) = try await client.download(Endpoints.Pages.export(pageId: "p1", format: .markdown))
        #expect(try Data(contentsOf: file) == content)
        withExtendedLifetime(client) { try? FileManager.default.removeItem(at: file) }
        #expect(response.value(forHTTPHeaderField: "Content-Disposition") == #"attachment; filename="Page.md""#)
        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.url?.absoluteString == "http://localhost:3000/api/pages/export")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody ?? Data())
        #expect(body["pageId"] == .string("p1"))
        #expect(body["format"] == .string("markdown"))
    }

    @Test func tooLargeNamesTheLimit() {
        // In the units sizes show in (`ByteCountFormatter`'s file style: 25 MB are 25,000,000 bytes).
        #expect(APIError.tooLarge(limit: 25_000_000).userMessage.contains("25"))
    }
}

}
