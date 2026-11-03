import SwiftUI
import DocmostKit

/// Recently updated pages across the workspace.
struct RecentPagesView: View {
    @Environment(AppSession.self) private var session
    @Environment(ContentChanges.self) private var changes
    /// Only the newest load's answer shows.
    @State private var recent = RemoteValue<[Page]>()

    var body: some View {
        AsyncContentView(state: recent.state, retry: load) { pages in
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
        await recent.load(cached: { await ready.cache.read([Page].self, key: CacheKey.recent) },
                          save: { await ready.cache.write($0, key: CacheKey.recent) }) {
            try await session.load(Endpoints.Pages.recent(limit: 50), of: ready).items
        }
    }
}
