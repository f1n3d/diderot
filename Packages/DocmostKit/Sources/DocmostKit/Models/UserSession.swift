import Foundation

/// Active session from `POST /api/sessions`; the current one comes first.
public struct UserSession: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let deviceName: String?
    public let lastActiveAt: Date?
    public let createdAt: Date?
    public let isCurrentDevice: Bool?

    public var displayName: String {
        deviceName?.isEmpty == false ? deviceName! : String(localized: "Unknown device", bundle: .main)
    }

    public var isCurrent: Bool { isCurrentDevice ?? false }
}

public struct UserSessionList: Decodable, Sendable {
    public let sessions: [UserSession]
}
