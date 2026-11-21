import SwiftUI
import DocmostKit

/// Favorite pages and spaces.
struct FavoritesView: View {
    @Environment(FavoritesStore.self) private var favorites
    @Environment(ContentChanges.self) private var changes

    var body: some View {
        AsyncContentView(state: favorites.listState, retry: { await favorites.loadList() }) { items in
            let pages = items.compactMap { $0.favoriteType == .page ? $0.page : nil }
            let spaces = items.compactMap { $0.favoriteType == .space ? $0.space : nil }
            // Favorites name each entry's space (Docmost 0.98): pages of an archived space are marked too, as on the web.
            let archived = Set(items.compactMap { $0.space?.isArchived == true ? $0.pageId ?? $0.spaceId : nil })
            if pages.isEmpty && spaces.isEmpty {
                ContentUnavailableView("No favorites yet", systemImage: "star", description: Text("Use the star in a page's menu to add it here."))
            } else {
                List {
                    if !pages.isEmpty {
                        Section("Pages") {
                            ForEach(pages) { page in
                                NavigationLink(value: PageSelection(pageId: page.id, title: page.title)) {
                                    HStack(spacing: 10) {
                                        PageIconView(icon: page.icon, size: 22, isBase: page.isBase == true)
                                        Text(page.displayTitle).lineLimit(2)
                                        if archived.contains(page.id) { ArchivedBadge() }
                                    }
                                }
                                .swipeActions {
                                    Button("Remove", systemImage: "star.slash", role: .destructive) {
                                        Task { await favorites.togglePage(page.id) }
                                    }
                                }
                            }
                        }
                    }
                    if !spaces.isEmpty {
                        Section("Spaces") {
                            ForEach(spaces) { space in
                                NavigationLink(value: SpaceRoute(spaceId: space.id)) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28)
                                        Text(space.name ?? space.slug ?? "Space")
                                        if space.isArchived { ArchivedBadge() }
                                    }
                                }
                                .swipeActions {
                                    Button("Remove", systemImage: "star.slash", role: .destructive) {
                                        Task { await favorites.toggleSpace(space.id) }
                                    }
                                }
                            }
                        }
                    }
                }
                .refreshable { await favorites.loadList() }
            }
        }
        .navigationTitle("Favorites")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { WorkspaceMenu() }
        }
        // On every appearance, like the web: a page renamed after opening it from here would keep its old title. And
        // after the app's own changes, as the space view does: the rename's save may finish after that load.
        .task { await favorites.loadList() }
        .onChange(of: changes.version) { _, _ in Task { await favorites.loadList() } }
    }
}
