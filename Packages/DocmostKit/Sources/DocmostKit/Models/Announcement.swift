import Foundation

/// A workspace announcement (license feature `announcements`, Docmost 0.98): a line of rich text the web shows as a
/// colored bar across the top of the workspace while it runs (`ee/announcement`).
public struct Announcement: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// `info`, `success`, `warning`, `critical` or `neutral`: the bar's icon.
    public let type: String?
    /// `blue`, `green`, `yellow`, `red`, `purple`, `gray` or `black`: the bar's colors.
    public let color: String?
    /// A document of one paragraph: text with bold, italic, underline and links.
    public let content: JSONValue?
    public let isDismissible: Bool?
    /// The time it runs, by the server's clock; open-ended where nil.
    public let startsAt: Date?
    public let endsAt: Date?
}

/// Response of `announcements/visible`: the announcements the person may see, and the server's time, by which they run.
public struct VisibleAnnouncements: Codable, Sendable, Hashable {
    public let now: Date?
    public let items: [Announcement]
}
