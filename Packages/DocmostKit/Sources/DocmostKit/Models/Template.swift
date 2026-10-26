import Foundation

/// A page template (the Enterprise license feature `templates`, Docmost 0.90): global, or of one space.
public struct PageTemplate: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let description: String?
    public let icon: String?
    /// The space it belongs to; `nil` for a global one, which every space offers.
    public let spaceId: String?
    /// Its document (`templates/info`).
    public let content: JSONValue?
    public let updatedAt: Date?

    public var displayTitle: String { PageTitle.display(title) }
}
