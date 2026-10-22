import Foundation

/// Hit from `POST /api/search`. `highlight` is plain text with `<b>…</b>` markers (Postgres `ts_headline`).
public struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let icon: String?
    public let highlight: String?
    public let space: SpaceRef?

    public var displayTitle: String { PageTitle.display(title) }

    /// Splits `highlight` into runs; `isMatch` marks the hits (`<b>…</b>`).
    public var highlightRuns: [HighlightRun] { HighlightRun.parse(highlight ?? "") }
}

public struct HighlightRun: Sendable, Hashable {
    public let text: String
    public let isMatch: Bool

    public static func parse(_ text: String) -> [HighlightRun] {
        var runs: [HighlightRun] = []
        var remainder = Substring(text)
        while let open = remainder.range(of: "<b>") {
            let before = remainder[..<open.lowerBound]
            if !before.isEmpty { runs.append(HighlightRun(text: String(before), isMatch: false)) }
            remainder = remainder[open.upperBound...]
            if let close = remainder.range(of: "</b>") {
                let match = remainder[..<close.lowerBound]
                if !match.isEmpty { runs.append(HighlightRun(text: String(match), isMatch: true)) }
                remainder = remainder[close.upperBound...]
            } else {
                runs.append(HighlightRun(text: String(remainder), isMatch: true))
                remainder = ""
            }
        }
        if !remainder.isEmpty { runs.append(HighlightRun(text: String(remainder), isMatch: false)) }
        return runs
    }
}

/// `{items}` without a cursor; search paginates via `offset`.
public struct SearchResponse: Decodable, Sendable {
    public let items: [SearchResult]
}

/// `POST /api/search/suggest`, for @-mentions and quick search.
public struct SearchSuggestions: Decodable, Sendable, Hashable {
    public struct UserSuggestion: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String?
        public let email: String?
        public let avatarUrl: String?
    }

    public struct PageSuggestion: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let slugId: String?
        public let title: String?
        public let icon: String?
        public let spaceId: String?
        public let space: SpaceRef?
    }

    public let users: [UserSuggestion]?
    public let pages: [PageSuggestion]?
}
