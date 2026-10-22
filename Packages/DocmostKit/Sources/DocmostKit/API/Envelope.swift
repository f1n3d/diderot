import Foundation

/// Server success response: `{data?, success, status}`. `data` is missing for handlers that return nothing.
struct APIEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
}

/// Response type for endpoints without a payload.
public struct NoContent: Decodable, Sendable, Hashable {
    public init() {}
}

/// Cursor-paginated list.
public struct Paginated<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let meta: PaginationMeta

    public init(items: [Item], meta: PaginationMeta) {
        self.items = items
        self.meta = meta
    }

    /// Fetches pages until `hasNextPage` is false or no cursor follows; `fetch` gets `nil` for the first page. Runs on
    /// the caller's actor, so `fetch` may use the caller's state.
    public nonisolated(nonsending) static func all(_ fetch: (_ cursor: String?) async throws -> Paginated) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            let page = try await fetch(cursor)
            items.append(contentsOf: page.items)
            cursor = page.meta.hasNextPage ? page.meta.nextCursor : nil
            // A cursor seen before would page forever (a server answering the same page again): stop there.
            if let next = cursor, !seen.insert(next).inserted { cursor = nil }
        } while cursor != nil
        return items
    }
}

public struct PaginationMeta: Decodable, Sendable, Hashable {
    public let hasNextPage: Bool
    public let nextCursor: String?

    public init(hasNextPage: Bool, nextCursor: String?) {
        self.hasNextPage = hasNextPage
        self.nextCursor = nextCursor
    }
}

/// Request fields for paginated endpoints (sent in the JSON body).
public struct PaginationOptions: Encodable, Sendable, Hashable {
    public var limit: Int?
    public var cursor: String?

    public init(limit: Int? = nil, cursor: String? = nil) {
        self.limit = limit
        self.cursor = cursor
    }
}

/// `{}` for POSTs without parameters; the server rejects an empty body with 400.
public struct EmptyBody: Encodable, Sendable {
    public init() {}
}
