import Foundation
import Synchronization

/// Log entry per request, for the app's debug log.
public struct APIRequestLog: Sendable {
    public let method: String
    public let path: String
    public let status: Int?
    public let duration: TimeInterval
    public let error: String?
}

/// HTTP client for the Docmost API; networking and decoding run on the actor, off the main thread.
/// Its own `URLSession` stores no cookies: the server prefers an `authToken` cookie over the bearer header, so a
/// stale cookie would override a valid token.
public actor APIClient {
    public let baseURL: URL
    public private(set) var token: String?
    public let userAgent: String

    private let session: URLSession
    private let decoder = JSONDecoding.makeDecoder()
    private let encoder = JSONDecoding.makeEncoder()
    private let logger: (@Sendable (APIRequestLog) -> Void)?
    private let clockOffset = Mutex<TimeInterval>(0)

    public static let defaultUserAgent = "DocmostKit/\(DocmostKitInfo.version)"

    /// - Parameter configuration: Session base (tests inject a `URLProtocol`); its cookie, connectivity and timeout
    ///   settings are overridden in place.
    public init(
        baseURL: URL,
        token: String? = nil,
        userAgent: String = APIClient.defaultUserAgent,
        configuration: URLSessionConfiguration = .ephemeral,
        logger: (@Sendable (APIRequestLog) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.userAgent = userAgent
        self.logger = logger

        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    /// Server clock minus device clock, from the latest response's `Date` header (to the second); 0 before one.
    /// Server timestamps such as `updatedAt` compare with device times only after this correction.
    public nonisolated var serverClockOffset: TimeInterval { clockOffset.withLock { $0 } }

    public func setToken(_ token: String?) {
        self.token = token
    }

    /// Absolute URL for an API path, e.g. `files/<id>/<name>`.
    public nonisolated func apiURL(_ path: String) -> URL {
        baseURL.appending(path: "api/" + path.trimmingPrefix("/"))
    }

    /// Returns the payload unwrapped from the envelope.
    public func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        let (data, _) = try await perform(endpoint)
        return try decode(Response.self, from: data, unwrapsEnvelope: true)
    }

    /// Returns raw data and response, e.g. for Set-Cookie headers or files.
    public func sendRaw<Response>(_ endpoint: Endpoint<Response>) async throws -> (Data, HTTPURLResponse) {
        try await perform(endpoint)
    }

    /// Downloads an API file (image, attachment) with the bearer token; files on other hosts, which page content may
    /// link, load without it.
    public func fetchFile(at url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request, requiresAuth: origin(of: url) == origin(of: baseURL))
        // File names are user content and logs can be exported, so log only the folder (`/api/files/<id>`).
        return try await execute(request, path: url.deletingLastPathComponent().path)
    }

    /// Uploads a file to a page as `multipart/form-data`. `files/upload` answers without an envelope (`res.send`).
    public func uploadAttachment(pageId: String, fileName: String, mimeType: String, data: Data) async throws -> Attachment {
        let boundary = "----DocmostBoundary" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"pageId\"\r\n\r\n\(pageId)\r\n")
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let path = "files/upload"
        var request = URLRequest(url: apiURL(path))
        request.httpMethod = "POST"
        applyHeaders(to: &request, requiresAuth: true)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, _) = try await execute(request, path: path)
        return try decode(Attachment.self, from: responseData, unwrapsEnvelope: false)
    }

    // MARK: - Internal

    private func perform<Response>(_ endpoint: Endpoint<Response>) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: apiURL(endpoint.path))
        request.httpMethod = "POST"
        if let timeout = endpoint.timeout { request.timeoutInterval = timeout }
        applyHeaders(to: &request, requiresAuth: endpoint.requiresAuth)
        for (field, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(endpoint.body)
        } catch {
            throw APIError.decoding("Request body: \(error)")
        }
        return try await execute(request, path: endpoint.path)
    }

    private func applyHeaders(to request: inout URLRequest, requiresAuth: Bool) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if requiresAuth, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Scheme, host and port; a missing port is the scheme's default.
    private func origin(of url: URL) -> (String?, String?, Int) {
        let scheme = url.scheme?.lowercased()
        return (scheme, url.host()?.lowercased(), url.port ?? (scheme == "http" ? 80 : 443))
    }

    private func execute(_ request: URLRequest, path: String) async throws -> (Data, HTTPURLResponse) {
        let started = ContinuousClock.now
        let method = request.httpMethod ?? "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            log(method: method, path: path, status: http.statusCode, started: started, error: nil)
            if let date = http.value(forHTTPHeaderField: "Date").flatMap({ try? Date($0, strategy: .http) }) {
                clockOffset.withLock { $0 = date.timeIntervalSinceNow }
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.from(status: http.statusCode, data: data)
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch _ where Task.isCancelled {
            // A closed screen or a newer search cancelled the caller; URLSession then fails with `URLError(.cancelled)`.
            throw CancellationError()
        } catch let error as URLError {
            log(method: method, path: path, status: nil, started: started, error: error.localizedDescription)
            throw APIError.network(error)
        } catch {
            log(method: method, path: path, status: nil, started: started, error: error.localizedDescription)
            throw APIError.invalidResponse
        }
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data, unwrapsEnvelope: Bool) throws -> Response {
        do {
            if !unwrapsEnvelope {
                return try decoder.decode(Response.self, from: data)
            }
            let envelope = try decoder.decode(APIEnvelope<Response>.self, from: data)
            if let payload = envelope.data {
                return payload
            }
            if let empty = NoContent() as? Response {
                return empty
            }
            throw APIError.unexpectedPayload
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decoding(error.shortDescription)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private func log(method: String, path: String, status: Int?, started: ContinuousClock.Instant, error: String?) {
        guard let logger else { return }
        let seconds = started.duration(to: .now) / .seconds(1)
        logger(APIRequestLog(method: method, path: path, status: status, duration: seconds, error: error))
    }
}

extension DecodingError {
    /// Short form with coding path, e.g. `keyNotFound: user.id`.
    var shortDescription: String {
        func path(_ context: Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch self {
        case .keyNotFound(let key, let context):
            return "keyNotFound: \(path(context)).\(key.stringValue)"
        case .typeMismatch(let type, let context):
            return "typeMismatch(\(type)): \(path(context))"
        case .valueNotFound(let type, let context):
            return "valueNotFound(\(type)): \(path(context))"
        case .dataCorrupted(let context):
            return "dataCorrupted: \(path(context)) \(context.debugDescription)"
        @unknown default:
            return localizedDescription
        }
    }
}
