import SwiftUI
import DocmostKit

/// Recently updated pages across the workspace.
struct RecentPagesView: View {
    @Environment(AppSession.self) private var session
    @Environment(ContentChanges.self) private var changes
    @State private var state: LoadState<[Page]> = .idle
    /// Counts loads, so only the newest answer shows.
    @State private var loads = 0

    var body: some View {
        AsyncContentView(state: state, retry: load) { pages in
            if pages.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "clock", description: Text("Pages you and your team edit will show up here."))
            } else {
                List {
                    ForEach(pages) { page in
                        NavigationLink(value: PageSelection(page: page)) {
                            HStack(spacing: 10) {
                                PageIconView(icon: page.icon, size: 22, isBase: page.isBase == true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.displayTitle)
                                        .lineLimit(2)
                                    HStack(spacing: 4) {
                                        if let space = page.space?.name {
                                            Text(space)
                                        }
                                        if let updatedAt = page.updatedAt {
                                            Text("·")
                                            Text(updatedAt, format: .relative(presentation: .named))
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Recently Updated")
        .toolbarTitleDisplayMode(.inline)
        // On every appearance, as on the web: a page renamed or trashed after opening it here would stay stale. And
        // after the app's own changes, as the space view does: the rename's save may finish after that load.
        .task { await load() }
        .onChange(of: changes.version) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard let ready = session.ready else { return }
        if state.value == nil {
            if let cached = await ready.cache.read([Page].self, key: CacheKey.recent) {
                state = .loaded(cached)
            } else {
                state = .loading
            }
        }
        loads += 1
        let load = loads
        do {
            let page = try await session.perform { try await ready.client.send(Endpoints.Pages.recent(limit: 50)) }
            guard load == loads else { return }
            state = .loaded(page.items)
            await ready.cache.write(page.items, key: CacheKey.recent)
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }
}
