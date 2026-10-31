import Foundation
import Synchronization
@testable import DocmostKit

/// Answers requests instead of the network; each test sets its own response.
final class MockURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Fails the request with this error instead of answering.
        var error: URLError?
        /// Redirects there with `status` (e.g. 307) first; a request to it gets status 200 and `body`.
        var redirect: URL?
    }

    private static let state = Mutex<(response: Response?, requests: [URLRequest])>((nil, []))

    static func respond(with response: Response) {
        state.withLock { $0 = (response, []) }
    }

    static var recordedRequests: [URLRequest] {
        state.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves `httpBody` into `httpBodyStream`; read it back so tests can inspect it.
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            request.httpBody = data
        }

        let response = Self.state.withLock { state -> Response? in
            state.requests.append(request)
            return state.response
        }
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let redirect = response.redirect {
            guard url == redirect else {
                let moved = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                            headerFields: ["Location": redirect.absoluteString])!
                var next = request
                next.url = redirect
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: moved)
                // A session that refuses the redirect gets the redirect itself as the answer, as from the network.
                client?.urlProtocol(self, didReceive: moved, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum TestSupport {
    static let baseURL = URL(string: "http://localhost:3000")!

    /// Client whose requests `MockURLProtocol` answers.
    static func mockClient(
        token: String? = "test-token", baseURL: URL = Self.baseURL, logger: (@Sendable (APIRequestLog) -> Void)? = nil
    ) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(baseURL: baseURL, token: token, userAgent: "DocmostKitTests/1.0", configuration: configuration, logger: logger)
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    /// The `data` payload of a recorded `{data, success, status}` response.
    static func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoding.makeDecoder().decode(DataBody<T>.self, from: fixture(name)).data
    }

    private struct DataBody<Payload: Decodable>: Decodable {
        let data: Payload
    }

    /// Unsigned JWT with the given claims (for parsing in tests only).
    static func jwt(claims: [String: JSONValue]) throws -> String {
        func segment(_ value: some Encodable) throws -> String {
            try JSONEncoder().encode(value).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return try [segment(["alg": "HS256", "typ": "JWT"]), segment(claims), "signature"].joined(separator: ".")
    }
}
