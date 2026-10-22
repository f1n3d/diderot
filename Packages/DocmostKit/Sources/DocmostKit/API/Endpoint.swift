import Foundation

/// An API call: a POST with a JSON body; `Response` is the type inside the envelope.
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    /// Path relative to `/api/`, e.g. `users/me`.
    public var path: String
    public var body: any Encodable & Sendable
    public var headers: [String: String]
    public var requiresAuth: Bool
    /// Seconds without an answer before the request fails; nil: the client's 30 s.
    public var timeout: TimeInterval?

    public init(
        path: String,
        body: any Encodable & Sendable,
        headers: [String: String] = [:],
        requiresAuth: Bool = true,
        timeout: TimeInterval? = nil
    ) {
        self.path = path
        self.body = body
        self.headers = headers
        self.requiresAuth = requiresAuth
        self.timeout = timeout
    }

    /// Sends `{}` when there is no body.
    public static func post(
        _ path: String, body: (any Encodable & Sendable)? = nil, requiresAuth: Bool = true, timeout: TimeInterval? = nil
    ) -> Endpoint {
        Endpoint(path: path, body: body ?? EmptyBody(), requiresAuth: requiresAuth, timeout: timeout)
    }
}
