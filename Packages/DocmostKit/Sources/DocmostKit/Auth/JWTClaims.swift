import Foundation

/// Docmost JWT claims, decoded only (the server verifies the token).
public struct JWTClaims: Sendable, Hashable {
    public let type: String?
    public let expiresAt: Date?

    public init?(token: String) {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let data = Self.base64URLDecode(String(segments[1])),
              let payload = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }

        type = payload["type"]?.stringValue
        expiresAt = payload["exp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
    }

    public var isAccessToken: Bool { type == "access" }

    public func isExpired(at date: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Remaining lifetime; `nil` without `exp`.
    public func remainingLifetime(at date: Date = .now) -> TimeInterval? {
        expiresAt.map { $0.timeIntervalSince(date) }
    }

    static func base64URLDecode(_ input: String) -> Data? {
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }
}
