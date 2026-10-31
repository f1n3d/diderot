import Foundation

/// API client error. Server errors come without the envelope: `{statusCode, message: String | [String], error?}`.
public enum APIError: Error, Sendable, Equatable {
    case network(URLError)
    case invalidResponse
    /// 401: token missing or expired, or wrong credentials.
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound(message: String?)
    /// 429: e.g. the sign-in rate limit (10/min per IP).
    case throttled
    /// 400 with validation messages.
    case validation(messages: [String])
    /// All other status codes.
    case server(status: Int, message: String?)
    case decoding(String)
    /// Envelope without `data` although a payload was expected.
    case unexpectedPayload

    /// Errors after which the user must sign in again.
    public var isSessionExpired: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// 403 or 404 on a read: deleted for good, or access removed. A saved copy must not stand in for it.
    public var isGone: Bool {
        switch self {
        case .forbidden, .notFound: return true
        default: return false
        }
    }

    public var userMessage: String {
        switch self {
        case .network(let error): return error.localizedDescription
        case .invalidResponse: return String(localized: "Invalid response from server.", bundle: .main)
        case .unauthorized(let message): return message ?? String(localized: "Not signed in.", bundle: .main)
        case .forbidden(let message): return message ?? String(localized: "You don't have permission to do that.", bundle: .main)
        case .notFound(let message): return message ?? String(localized: "Not found.", bundle: .main)
        case .throttled: return String(localized: "Too many requests. Please wait a moment and try again.", bundle: .main)
        case .validation(let messages): return messages.joined(separator: "\n")
        case .server(let status, let message): return message ?? String(localized: "Server error (\(status)).", bundle: .main)
        case .decoding(let detail): return String(localized: "Could not read the server response (\(detail)).", bundle: .main)
        case .unexpectedPayload: return String(localized: "The server returned an empty response.", bundle: .main)
        }
    }

    /// Maps a non-2xx response to an error.
    static func from(status: Int, data: Data) -> APIError {
        let body = try? JSONDecoding.makeDecoder().decode(ServerErrorBody.self, from: data)
        let messages = body?.messages ?? []
        let first = messages.first
        // Only Docmost's own answer, whose body names the status: a 400, 401, 403 or 404 from a reverse proxy, a sign-in
        // gateway in front of Docmost or a captive portal must not sign out (the server session would stay valid), drop
        // a kept title, or count as a page gone for good (that drops its saved copy).
        switch status {
        case 400 where body?.statusCode == 400:
            return .validation(messages: messages.isEmpty ? [String(localized: "Bad request.", bundle: .main)] : messages)
        case 401 where body?.statusCode == 401:
            return .unauthorized(message: first)
        case 403 where body?.statusCode == 403:
            return .forbidden(message: first)
        case 404 where body?.statusCode == 404:
            return .notFound(message: first)
        case 429:
            return .throttled
        default:
            return .server(status: status, message: first)
        }
    }
}

struct ServerErrorBody: Decodable {
    let statusCode: Int?
    let message: Message?

    var messages: [String] {
        switch message {
        case .single(let text): return [text]
        case .multiple(let texts): return texts
        case nil: return []
        }
    }

    enum Message: Decodable {
        case single(String)
        case multiple([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .single(text)
            } else {
                self = .multiple(try container.decode([String].self))
            }
        }
    }
}
