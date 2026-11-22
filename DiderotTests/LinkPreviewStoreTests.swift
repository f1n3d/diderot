import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Previews of links to other services, which integration mentions and cards show.
@MainActor
struct LinkPreviewStoreTests {
    /// The titles mentions show (`titles`) change only with a preview that loaded. While find shows, the page searches
    /// the whole document again for each change of them; a link being asked about, one no integration previews, one
    /// that needs the user's account first (its answer has a title too) or one whose answer failed changes no title,
    /// and the page needn't search again for it.
    @Test func titlesChangeOnlyWithALoadedPreview() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnfurlServer.self]
        let client = APIClient(baseURL: URL(string: "https://link-previews.example.com")!, configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appending(path: "link-preview-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LinkPreviewStore(client: client, cache: DiskCache(scope: "previews", baseDirectory: directory))

        await store.load([Link.unpreviewed, Link.needsConnection, Link.failing])
        #expect(store.states[Link.unpreviewed] == .loaded(nil))
        #expect(store.states[Link.failing] == .failed)
        #expect(store.states.count == 3)
        #expect(store.titles.isEmpty, "a title that the page doesn't show")

        await store.load([Link.previewed])
        #expect(store.titles == [Link.previewed: "Crash when opening settings"])
        #expect(store.titles[Link.previewed] == store.preview(for: Link.previewed)?.title, "not the title the page shows")
    }
}

private nonisolated enum Link {
    static let previewed = "https://github.com/acme/app/issues/12"
    static let unpreviewed = "https://github.com/acme/app/issues/13"
    static let needsConnection = "https://github.com/acme/app/issues/14"
    static let failing = "https://github.com/acme/app/issues/15"
}

/// Answers as Docmost does: no installed integrations, and for each link a preview, none, a request to connect the
/// account first, or a server error.
private nonisolated final class UnfurlServer: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, body) = Self.answer(path: url.path, link: Self.link(in: request))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(path: String, link: String?) -> (Int, String) {
        switch (path, link) {
        case ("/api/integrations/installed", _):
            (200, #"{"data": []}"#)
        case ("/api/integrations/unfurl", Link.previewed?):
            (200, #"{"data": {"data": {"title": "Crash when opening settings", "url": "\#(Link.previewed)", "provider": "github", "status": "Open"}}}"#)
        case ("/api/integrations/unfurl", Link.unpreviewed?):
            (200, #"{"data": {"data": null}}"#)
        case ("/api/integrations/unfurl", Link.needsConnection?):
            (200, #"{"data": {"data": {"needsConnection": true, "integrationId": "i1", "integrationType": "github", "integrationName": "GitHub", "title": "Connect GitHub"}}}"#)
        default:
            (500, #"{"statusCode": 500, "message": "Internal server error"}"#)
        }
    }

    /// The link a request asks about; URLSession hands the body over as a stream.
    private static func link(in request: URLRequest) -> String? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[..<count])
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["url"] as? String
    }
}
