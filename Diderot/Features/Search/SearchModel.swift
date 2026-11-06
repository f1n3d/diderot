import SwiftUI
import DocmostKit

/// Debounced full-text search in the workspace or one space, with offset paging. Shared by the Search tab and the
/// space view's inline search.
@MainActor @Observable
final class SearchModel {
    struct Key: Equatable {
        let query: String
        let titleOnly: Bool
    }

    var query: String
    var titleOnly = false
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    @ObservationIgnored var session: AppSession?
    @ObservationIgnored let spaceId: String?
    private let pageSize = 25
    /// Searches started (`run`, `loadMore`): only the latest ends `isSearching`, as an earlier one's query is gone.
    @ObservationIgnored private var started = 0
    /// What the wait for more typing runs on; tests move a clock of their own (`TestClock`).
    @ObservationIgnored private let clock: any Clock<Duration>

    init(spaceId: String? = nil, query: String = "", clock: any Clock<Duration> = ContinuousClock()) {
        self.spaceId = spaceId
        self.query = query
        self.clock = clock
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var key: Key { Key(query: trimmedQuery, titleOnly: titleOnly) }
    /// A query is entered: the UI shows results instead of its normal content.
    var isActive: Bool { !trimmedQuery.isEmpty }

    /// For `.task(id: key)`: debounces typing, then searches; an empty query clears the results.
    func run() async {
        started += 1
        let generation = started
        guard isActive else {
            results = []
            hasMore = false
            errorMessage = nil
            isSearching = false
            return
        }
        // From the first key on: during the debounce, the results said "No Results" for a query not sent yet.
        isSearching = true
        try? await clock.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        await search(append: false)
        if generation == started { isSearching = false }
    }

    func loadMore() async {
        started += 1
        let generation = started
        isSearching = true
        await search(append: true)
        if generation == started { isSearching = false }
    }

    func clear() {
        query = ""
    }

    private func search(append: Bool) async {
        guard let session, session.client != nil else { return }
        errorMessage = nil
        let key = key
        let offset = append ? results.count : 0
        let spaceId = spaceId
        let limit = pageSize
        do {
            let response = try await session.send(Endpoints.Search.search(
                query: key.query, spaceId: spaceId, titleOnly: key.titleOnly ? true : nil, limit: limit, offset: offset
            ))
            // "Load More" outlives its query's task: drop a page that no longer continues the results shown.
            guard !Task.isCancelled, key == self.key, !append || results.count == offset else { return }
            results = append ? results + response.items : response.items
            hasMore = response.items.count == pageSize
        } catch is CancellationError {
        } catch {
            // Cancelled (typing on) or outdated: the search for the current query reports its own errors.
            guard !Task.isCancelled, key == self.key else { return }
            errorMessage = error.userMessage
        }
    }
}

/// Search result row: icon, title, highlighted snippet, space.
struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PageIconView(icon: result.icon, size: 20)
                Text(result.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            if let highlight = result.highlight, !highlight.isEmpty {
                highlightedText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let space = result.space?.name {
                Text(space)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var highlightedText: Text {
        var attributed = AttributedString()
        for run in result.highlightRuns {
            var piece = AttributedString(run.text)
            if run.isMatch {
                piece.font = .subheadline.bold()
                piece.foregroundColor = .primary
            }
            attributed.append(piece)
        }
        return Text(attributed)
    }
}
