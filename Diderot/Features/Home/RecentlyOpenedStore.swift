import Foundation
import Observation
import DocmostKit

/// Local history of recently opened pages (cached per server).
nonisolated struct RecentlyOpenedItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String?
    let icon: String?
    let spaceName: String?
    let openedAt: Date
    var isBase: Bool?
    /// So a page opened by its short link (slugId) is found when it turns out to be gone.
    var slugId: String?

    var displayTitle: String { PageTitle.display(title) }
}

@MainActor
@Observable
final class RecentlyOpenedStore {
    typealias Item = RecentlyOpenedItem

    private(set) var items: [Item] = []
    private let cache: DiskCache?
    private static let limit = 20

    init(cache: DiskCache?) {
        self.cache = cache
    }

    /// Called from the main view's task, not `init`: SwiftUI builds a throwaway store on every view init.
    func load() async {
        if let cached = await cache?.read([Item].self, key: CacheKey.recentlyOpened) {
            items = cached
        }
    }

    func record(_ page: Page) {
        let item = Item(
            id: page.id, title: page.title, icon: page.icon,
            spaceName: page.space?.name, openedAt: .now, isBase: page.isBase, slugId: page.slugId
        )
        items.removeAll { $0.id == page.id }
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        persist()
    }

    /// `pageId`: the page's id or slugId.
    func remove(pageId: String) {
        items.removeAll { $0.id == pageId || $0.slugId == pageId }
        persist()
    }

    private func persist() {
        let snapshot = items
        Task { await cache?.write(snapshot, key: CacheKey.recentlyOpened) }
    }
}
