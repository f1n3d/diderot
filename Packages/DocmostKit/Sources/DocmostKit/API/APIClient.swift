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
    public nonisolated let baseURL: URL
    public private(set) var token: String?
    public let userAgent: String

    private let session: URLSession
    /// The session's delegate: writes the downloads that go to a file (`downloadFile`).
    private let transfers = FileTransfers()
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
        self.session = URLSession(configuration: configuration, delegate: transfers, delegateQueue: nil)
    }

    deinit {
        // A session keeps its delegate until it is invalidated; requests still running end first.
        session.finishTasksAndInvalidate()
        // What a download left that nobody took (its caller was cancelled before moving it) goes with the client, so a
        // sign-out leaves nothing of that server here.
        try? FileManager.default.removeItem(at: downloads)
    }

    /// Where downloads are written while they load, until whoever asked for one moves it (`downloadFile`): a folder
    /// per client in here.
    public static let downloadsDirectory = FileManager.default.temporaryDirectory.appending(path: "docmost-downloads", directoryHint: .isDirectory)

    /// This client's folder in `downloadsDirectory`; it goes with the client.
    private let downloads = APIClient.downloadsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    /// Removes the downloads of clients that ended without removing theirs: the app was ended while one ran. For the
    /// app's start, before a client downloads.
    public static func removeAbandonedDownloads() {
        try? FileManager.default.removeItem(at: downloadsDirectory)
    }

    /// Server clock minus device clock, from the latest API response's `Date` header (to the second); 0 before one.
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

    /// Returns raw data and response, e.g. for Set-Cookie headers.
    public func sendRaw<Response>(_ endpoint: Endpoint<Response>) async throws -> (Data, HTTPURLResponse) {
        try await perform(endpoint)
    }

    /// Downloads a file (an attachment, an image, a PDF) into a file of its own in `downloadsDirectory`, written as it
    /// arrives: nothing of it is held in memory. The bearer token goes only to the server; files on other hosts, which
    /// page content may link, load without it. The caller moves the file to its place or removes it, before it lets go
    /// of the client; a download that fails or is cancelled leaves none. With `maxBytes`, a larger file is refused with
    /// `APIError.tooLarge`: as soon as the answer names its size, so nothing of it loads, or once more than that has
    /// arrived.
    public func downloadFile(at url: URL, maxBytes: Int64? = nil) async throws -> (file: URL, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request, requiresAuth: Origin(url) == Origin(baseURL))
        // File names are user content and logs can be exported, so log only the folder (`/api/files/<id>`).
        return try await download(request, path: url.deletingLastPathComponent().path, readsClock: false, maxBytes: maxBytes)
    }

    /// Sends an endpoint whose answer is a file (a page export) and downloads it as `downloadFile` does.
    public func download<Response>(_ endpoint: Endpoint<Response>, maxBytes: Int64? = nil) async throws -> (file: URL, response: HTTPURLResponse) {
        try await download(request(for: endpoint), path: endpoint.path, readsClock: true, maxBytes: maxBytes)
    }

    /// Uploads a file to a page as `multipart/form-data`. `files/upload` answers without an envelope (`res.send`).
    /// Uploads a file on disk: the request body goes to a file beside it, written in chunks, and URLSession sends it from
    /// there, so neither the file nor the body is held in memory (a large video took the app's memory).
    public func uploadAttachment(pageId: String, fileName: String, mimeType: String, fileURL: URL) async throws -> Attachment {
        let boundary = "----DocmostBoundary" + UUID().uuidString
        let body = fileURL.deletingLastPathComponent().appending(path: "body-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        // Its error says why, as reading the file's does: a full disk, or a sign-out that removed the staged file mid-upload.
        try Data().write(to: body, options: .completeFileProtection)
        let output = try FileHandle(forWritingTo: body)
        do {
            defer { try? output.close() }
            let (head, tail) = Self.multipartFrame(boundary: boundary, pageId: pageId, fileName: fileName, mimeType: mimeType)
            try output.write(contentsOf: head)
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: tail)
        }
        let request = uploadRequest(boundary: boundary)
        let (responseData, _) = try await execute(request, path: "files/upload") {
            try await self.session.upload(for: request, fromFile: body, delegate: $0)
        }
        return try decode(Attachment.self, from: responseData, unwrapsEnvelope: false)
    }

    private static func multipartFrame(boundary: String, pageId: String, fileName: String, mimeType: String) -> (head: Data, tail: Data) {
        // A quote or a line break (any control character) would end the name, and what follows would count as headers.
        let safeName = String(fileName.unicodeScalars.map { $0 == "\"" || $0.properties.generalCategory == .control ? "_" : Character($0) })
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"pageId\"\r\n\r\n\(pageId)\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        return (Data(head.utf8), Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private func uploadRequest(boundary: String) -> URLRequest {
        var request = URLRequest(url: apiURL("files/upload"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, requiresAuth: true)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Uploads data in memory (small payloads, tests).
    public func uploadAttachment(pageId: String, fileName: String, mimeType: String, data: Data) async throws -> Attachment {
        let boundary = "----DocmostBoundary" + UUID().uuidString
        let (head, tail) = Self.multipartFrame(boundary: boundary, pageId: pageId, fileName: fileName, mimeType: mimeType)
        var request = uploadRequest(boundary: boundary)
        request.httpBody = head + data + tail
        let (responseData, _) = try await execute(request, path: "files/upload")
        return try decode(Attachment.self, from: responseData, unwrapsEnvelope: false)
    }

    // MARK: - Internal

    private func perform<Response>(_ endpoint: Endpoint<Response>) async throws -> (Data, HTTPURLResponse) {
        try await execute(request(for: endpoint), path: endpoint.path)
    }

    private func request<Response>(for endpoint: Endpoint<Response>) throws -> URLRequest {
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
        return request
    }

    private func applyHeaders(to request: inout URLRequest, requiresAuth: Bool) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if requiresAuth, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// `send`: how the request goes out, if not as `session.data(for:delegate:)` (an upload from a file); it gets the
    /// delegate to pass on. `readsClock`: the response's `Date` header sets `serverClockOffset`. API calls and uploads
    /// go to the server and no cache answers them; a file can come from another host, or from the session's cache with
    /// the `Date` of its first download.
    private func execute(
        _ request: URLRequest, path: String, readsClock: Bool = true,
        send: ((URLSessionTaskDelegate?) async throws -> (Data, URLResponse))? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await execute(request, path: path, readsClock: readsClock, errorBody: { $0 }, discard: { _ in }) { delegate in
            if let send {
                try await send(delegate)
            } else {
                try await self.session.data(for: request, delegate: delegate)
            }
        }
    }

    /// A request whose answer goes to a file (`downloadFile`): the same checks, and the file goes whenever one fails.
    private func download(_ request: URLRequest, path: String, readsClock: Bool, maxBytes: Int64?) async throws -> (file: URL, response: HTTPURLResponse) {
        let file = downloads.appending(path: UUID().uuidString)
        return try await execute(request, path: path, readsClock: readsClock, errorBody: Self.errorBody(inFile:), discard: Self.discard) { refusal in
            do {
                // `execute` decides which requests follow no redirect, and hands a delegate for those.
                return (file, try await self.transfer(request, to: file, maxBytes: maxBytes, refusesRedirects: refusal != nil))
            } catch {
                Self.discard(file)
                throw error
            }
        }
    }

    private static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    /// Loads `request`'s answer into `file` as it arrives (`FileTransfers`) and returns the answer's head. URLSession's
    /// own file download leaves its temporary file behind whenever it is cancelled, with no way to find it (tried on
    /// November 10, 2026), and reading the answer byte by byte (`bytes(for:)`) is far too slow.
    private func transfer(_ request: URLRequest, to file: URL, maxBytes: Int64?, refusesRedirects: Bool) async throws -> URLResponse {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        // Readable only while the device is unlocked, like the places downloads move to, but still writable while it
        // is open: the device may lock while a long download runs.
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUnlessOpen]
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        let task = session.dataTask(with: request)
        let transfer = FileTransfers.Transfer(handle: handle, maxBytes: maxBytes, refusesRedirects: refusesRedirects)
        transfers.add(transfer, for: task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.wait(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The start of a downloaded error answer, enough for the server's message (`APIError.from`).
    private static func errorBody(inFile file: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: FileTransfers.errorBodyBytes)) ?? Data()
    }

    /// One request and the checks of its answer, whatever holds the answer's body: `Data`, or a downloaded file.
    /// `errorBody` reads the server's message from it, `discard` removes it when a check fails.
    private func execute<Body>(
        _ request: URLRequest, path: String, readsClock: Bool,
        errorBody: (Body) -> Data, discard: (Body) -> Void,
        send: (URLSessionTaskDelegate?) async throws -> (Body, URLResponse)
    ) async throws -> (Body, HTTPURLResponse) {
        let started = ContinuousClock.now
        let method = request.httpMethod ?? "GET"
        // Requests to the server don't follow redirects: Docmost sends none, and URLSession would send a request's body
        // and cookie (a password, the MFA cookie, page content) on to wherever one points, another host or plain HTTP
        // included, and drop its token, so the server's 401 would sign out. Files on other hosts follow them.
        let toServer = request.url.map { Origin($0) == Origin(baseURL) } == true
        let delegate = toServer ? RedirectRefusal() : nil
        do {
            let (body, response) = try await send(delegate)
            do {
                guard let http = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }
                log(method: method, path: path, status: http.statusCode, started: started, error: nil)
                if readsClock, let date = http.value(forHTTPHeaderField: "Date").flatMap({ try? Date($0, strategy: .http) }) {
                    clockOffset.withLock { $0 = date.timeIntervalSinceNow }
                }
                if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location") {
                    throw APIError.server(status: http.statusCode, message: String(localized: "The server redirects to \(location).", bundle: .main))
                }
                guard (200..<300).contains(http.statusCode) else {
                    // Docmost's rules only for the server's answers: a file a page links from another host answered a 401 in
                    // its shape (any NestJS API's), and the reader was signed out. Its message isn't the server's to show.
                    guard toServer else { throw http.statusCode == 429 ? APIError.throttled : APIError.server(status: http.statusCode, message: nil) }
                    throw APIError.from(status: http.statusCode, data: errorBody(body))
                }
                return (body, http)
            } catch {
                discard(body)
                throw error
            }
        } catch let error as APIError {
            throw error
        } catch _ where Task.isCancelled {
            // A closed screen or a newer search cancelled the caller; URLSession then fails with `URLError(.cancelled)`.
            throw CancellationError()
        } catch let error as URLError {
            log(method: method, path: path, status: nil, started: started, error: error.localizedDescription)
            throw APIError.network(error)
        } catch {
            // Not the server's doing (an upload's body file gone, say): the error keeps its cause.
            log(method: method, path: path, status: nil, started: started, error: error.localizedDescription)
            throw error
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

/// Hands a redirect back as the response instead of following it (see `APIClient.execute`).
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// The session's delegate, for the downloads that go to a file (`APIClient.transfer`): it writes each one's data to
/// its file as it arrives and ends one that is larger than asked for, when the answer names its size or once more has
/// arrived. Every other request of the session has no transfer here and passes untouched.
private final class FileTransfers: NSObject, URLSessionDataDelegate, Sendable {
    /// How much of an error's answer is kept: enough for the server's message.
    static let errorBodyBytes = 1 << 16

    /// One download. Its writing state is touched only on the session's delegate queue, one call at a time; whoever
    /// waits for it and its end meet under the lock, in either order.
    final class Transfer: @unchecked Sendable {
        fileprivate let handle: FileHandle
        fileprivate let maxBytes: Int64?
        fileprivate let refusesRedirects: Bool
        fileprivate var written: Int64 = 0
        /// An error's answer reached `errorBodyBytes`: nothing more of it is kept.
        fileprivate var isCut = false
        fileprivate var response: URLResponse?
        /// Why the transfer ended its task itself (too large, a write that failed), instead of the task's own error.
        fileprivate var failure: (any Error)?
        private let ending = Mutex<(result: Result<URLResponse, any Error>?, waiting: CheckedContinuation<URLResponse, any Error>?)>((nil, nil))

        init(handle: FileHandle, maxBytes: Int64?, refusesRedirects: Bool) {
            self.handle = handle
            self.maxBytes = maxBytes
            self.refusesRedirects = refusesRedirects
        }

        /// Resumes `continuation` with the transfer's end, at once if it ended already (a task cancelled before it ran).
        func wait(_ continuation: CheckedContinuation<URLResponse, any Error>) {
            let result = ending.withLock { ending in
                if ending.result == nil { ending.waiting = continuation }
                return ending.result
            }
            if let result { continuation.resume(with: result) }
        }

        fileprivate func end(_ result: Result<URLResponse, any Error>) {
            let waiting = ending.withLock { ending in
                ending.result = result
                defer { ending.waiting = nil }
                return ending.waiting
            }
            waiting?.resume(with: result)
        }

        /// The file's answer, not an error's: only that counts against `maxBytes`.
        fileprivate var isFile: Bool {
            (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        }
    }

    private let transfers = Mutex<[Int: Transfer]>([:])

    /// Before the task runs.
    func add(_ transfer: Transfer, for task: URLSessionTask) {
        transfers.withLock { $0[task.taskIdentifier] = transfer }
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        transfers.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        transfer(for: task)?.refusesRedirects == true ? nil : request
    }

    /// With a completion handler, not `async`: that one would run off the delegate queue, where the transfer's state
    /// belongs.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer = transfer(for: dataTask) else { return completionHandler(.allow) }
        transfer.response = response
        // A larger file than asked for ends here, before any of it loads.
        if let maxBytes = transfer.maxBytes, transfer.isFile, response.expectedContentLength > maxBytes {
            transfer.failure = APIError.tooLarge(limit: maxBytes)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask), transfer.failure == nil, !transfer.isCut else { return }
        let arrived = transfer.written + Int64(data.count)
        if transfer.isFile {
            // Its size wasn't named, or named too small.
            if let maxBytes = transfer.maxBytes, arrived > maxBytes {
                transfer.failure = APIError.tooLarge(limit: maxBytes)
                return dataTask.cancel()
            }
        } else if arrived > Self.errorBodyBytes {
            // An error's answer: its start has the message, the rest isn't kept, whatever size its pieces come in.
            transfer.isCut = true
            return
        }
        do {
            try transfer.handle.write(contentsOf: data)
            transfer.written = arrived
        } catch {
            // A full disk, or the device locked for long: the download ends with that, not half a file.
            transfer.failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = transfers.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? transfer.handle.close()
        if let failure = transfer.failure ?? error {
            transfer.end(.failure(failure))
        } else if let response = transfer.response {
            transfer.end(.success(response))
        } else {
            transfer.end(.failure(APIError.invalidResponse))
        }
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
