import Foundation
import Testing
import DocmostKit
@testable import Diderot

@MainActor
struct PageTreeStoreTests {
    private func page(_ id: String, parent: String? = nil, children: Bool = false) -> SidebarPage {
        SidebarPage(id: id, title: id, parentPageId: parent, hasChildren: children)
    }

    @Test func flattensExpandedNodesDepthFirst() {
        let store = PageTreeStore(spaceId: "s")
        store.setChildren([page("A", children: true), page("B"), page("C", children: true)], of: nil)
        store.setChildren([page("A1", parent: "A", children: true), page("A2", parent: "A")], of: "A")
        store.setChildren([page("A1a", parent: "A1")], of: "A1")
        store.setChildren([page("C1", parent: "C")], of: "C")

        #expect(store.visibleRows.map(\.id) == ["A", "B", "C"])

        store.setExpanded("A", true)
        #expect(store.visibleRows.map { "\($0.id)@\($0.depth)" } == ["A@0", "A1@1", "A2@1", "B@0", "C@0"])

        store.setExpanded("A1", true)
        store.setExpanded("C", true)
        #expect(store.visibleRows.map(\.id) == ["A", "A1", "A1a", "A2", "B", "C", "C1"])

        store.setExpanded("A", false)
        #expect(store.visibleRows.map(\.id) == ["A", "B", "C", "C1"])
    }

    /// SpaceView.movePage drops nothing on, before or after a page's own subpages. Only visible rows are drop
    /// targets, so pages below a collapsed node don't count.
    @Test func isDescendantCoversOnlyVisibleSubpages() {
        let store = PageTreeStore(spaceId: "s")
        store.setChildren([page("P", children: true), page("S", children: true)], of: nil)
        store.setChildren([page("P1", parent: "P", children: true), page("P2", parent: "P", children: true)], of: "P")
        store.setChildren([page("P1a", parent: "P1")], of: "P1")
        store.setChildren([page("P2a", parent: "P2")], of: "P2")
        store.setChildren([page("S1", parent: "S")], of: "S")
        store.setExpanded("P", true)
        store.setExpanded("P1", true)
        store.setExpanded("S", true)

        #expect(store.isDescendant("P1", of: "P"))
        #expect(store.isDescendant("P1a", of: "P"))
        #expect(!store.isDescendant("P", of: "P"))
        #expect(!store.isDescendant("S", of: "P"))
        #expect(!store.isDescendant("S1", of: "P"))
        #expect(!store.isDescendant("P2a", of: "P"))
    }

    @Test func toggleLoadsChildrenOncePerParent() async {
        let calls = Calls()
        let store = PageTreeStore(spaceId: "s") { parent, cursor in
            await calls.record(parent ?? "root", cursor)
            if parent == nil {
                return Paginated(items: [SidebarPage(id: "A", title: "A", hasChildren: true)],
                                 meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
            }
            // Two result pages of one item each, to exercise paging.
            if cursor == nil {
                return Paginated(items: [SidebarPage(id: "A1", title: "A1", parentPageId: "A")],
                                 meta: PaginationMeta(hasNextPage: true, nextCursor: "c2"))
            }
            return Paginated(items: [SidebarPage(id: "A2", title: "A2", parentPageId: "A")],
                             meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        await store.loadRootIfNeeded()
        await store.toggle("A")
        #expect(store.visibleRows.map(\.id) == ["A", "A1", "A2"])

        await store.toggle("A")
        await store.toggle("A")
        #expect(store.visibleRows.map(\.id) == ["A", "A1", "A2"])
        #expect(await calls.list == ["root/-", "A/-", "A/c2"])
    }

    /// A push or tab switch cancels the space view's first load (nothing cached): the tree loads again when the view
    /// reappears instead of keeping the error.
    @Test func loadRootIfNeededRetriesAfterAFailure() async {
        let calls = Calls()
        let store = PageTreeStore(spaceId: "s") { parent, cursor in
            await calls.record(parent ?? "root", cursor)
            if await calls.list.count == 1 { throw URLError(.cancelled) }
            return Paginated(items: [SidebarPage(id: "A", title: "A")], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        await store.loadRootIfNeeded()
        #expect(store.rootPages.isEmpty)
        await store.loadRootIfNeeded()
        #expect(store.visibleRows.map(\.id) == ["A"])
        #expect(await calls.list == ["root/-", "root/-"])
    }

    /// A refresh (after a rename, a move or a pull) keeps every expanded level open, not only the root's.
    @Test func reloadKeepsNestedLevelsExpanded() async {
        let levels = ["root": [page("A", children: true)], "A": [page("A1", parent: "A", children: true)], "A1": [page("A1a", parent: "A1")]]
        let store = PageTreeStore(spaceId: "s") { parent, _ in
            Paginated(items: levels[parent ?? "root"] ?? [], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        await store.loadRootIfNeeded()
        await store.toggle("A")
        await store.toggle("A1")
        await store.reload()
        #expect(store.visibleRows.map(\.id) == ["A", "A1", "A1a"])
    }

    /// Nothing cached: a failed refresh keeps the loaded tree instead of showing an error; a failed level collapses
    /// and loads again on the next tap.
    @Test func failedReloadKeepsTheTree() async {
        let levels = ["root": [page("A", children: true)], "A": [page("A1", parent: "A")]]
        let calls = Calls()
        let store = PageTreeStore(spaceId: "s") { parent, cursor in
            await calls.record(parent ?? "root", cursor)
            // The first refresh fails at the root, the second one at A's level.
            if [3, 5].contains(await calls.list.count) { throw URLError(.notConnectedToInternet) }
            return Paginated(items: levels[parent ?? "root"] ?? [], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        await store.loadRootIfNeeded()
        await store.toggle("A")
        await store.reload()
        #expect(store.rootState.value != nil)
        #expect(store.visibleRows.map(\.id) == ["A", "A1"])

        await store.reload()
        #expect(store.visibleRows.map(\.id) == ["A"])
        await store.toggle("A")
        #expect(store.visibleRows.map(\.id) == ["A", "A1"])
    }

    /// Nothing cached: a page whose subpages fail to load collapses instead of looking childless; the next tap retries.
    @Test func failedExpandCollapsesAndRetries() async {
        let levels = ["root": [page("A", children: true)], "A": [page("A1", parent: "A")]]
        let calls = Calls()
        let store = PageTreeStore(spaceId: "s") { parent, cursor in
            await calls.record(parent ?? "root", cursor)
            if await calls.list.count == 2 { throw URLError(.notConnectedToInternet) }
            return Paginated(items: levels[parent ?? "root"] ?? [], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        await store.loadRootIfNeeded()
        await store.toggle("A")
        #expect(!store.isExpanded("A"))
        await store.toggle("A")
        #expect(store.visibleRows.map(\.id) == ["A", "A1"])
    }

    /// Offline, a space opens with its saved tree; once the space or level is gone (403, 404), it opens with the error
    /// and drops the saved copy.
    @Test func goneLevelDropsItsSavedCopy() async {
        let base = FileManager.default.temporaryDirectory.appending(path: "page-tree-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = DiskCache(scope: "server", baseDirectory: base)
        func open(failing error: APIError?) async -> PageTreeStore {
            let store = PageTreeStore(spaceId: "s", cache: cache) { _, _ in
                if let error { throw error }
                return Paginated(items: [SidebarPage(id: "A", title: "A")], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
            }
            await store.reload()
            return store
        }

        _ = await open(failing: nil)
        #expect(await open(failing: .network(URLError(.notConnectedToInternet))).visibleRows.map(\.id) == ["A"])
        let gone = await open(failing: .forbidden(message: nil))
        #expect(gone.rootState.value == nil && gone.rootPages.isEmpty)
        #expect(await cache.read([SidebarPage].self, key: CacheKey.tree(spaceId: "s", parentPageId: nil)) == nil)
    }

    /// A shown tree whose space went away (deleted, unshared) shows the error on the next refresh; it used to stay up
    /// without a hint.
    @Test func goneSpaceReplacesTheShownTree() async {
        let failure = FailureBox()
        let store = PageTreeStore(spaceId: "s") { _, _ in
            if let error = failure.error { throw error }
            return Paginated(items: [SidebarPage(id: "A", title: "A")], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }
        await store.reload()
        failure.error = .notFound(message: nil)
        await store.reload()
        #expect(store.rootState.value == nil)
    }

    /// A page expanded while a refresh runs stays expanded with the level its tap loaded.
    @Test func reloadKeepsAPageExpandedMeanwhile() async {
        let levels = ["root": [page("A", children: true), page("B", children: true)], "A": [page("A1", parent: "A")], "B": [page("B1", parent: "B")]]
        let box = StoreBox()
        let store = PageTreeStore(spaceId: "s") { parent, _ in
            // The refresh reloads A's level after passing B, and B is expanded right then.
            if parent == "A", let store = box.store {
                box.store = nil
                await store.toggle("B")
            }
            return Paginated(items: levels[parent ?? "root"] ?? [], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        await store.loadRootIfNeeded()
        await store.toggle("A")
        box.store = store
        await store.reload()
        #expect(store.visibleRows.map(\.id) == ["A", "A1", "B", "B1"])
    }

    /// A page tapped while a refresh runs shows its current subpages, not the ones it had before it was collapsed.
    @Test func reloadShowsCurrentSubpagesOfAPageExpandedMeanwhile() async {
        let levels = ["root": [page("A", children: true), page("K", children: true), page("Z")], "A": [page("A1", parent: "A")], "K": [page("K2", parent: "K")]]
        let box = StoreBox()
        let store = PageTreeStore(spaceId: "s") { parent, _ in
            // The walk goes last page first: it reloads A's level after passing K, and K is tapped right then.
            if parent == "A", let store = box.store {
                box.store = nil
                await store.toggle("K")
            }
            return Paginated(items: levels[parent ?? "root"] ?? [], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        await store.loadRootIfNeeded()
        await store.toggle("A")
        // K was expanded once and collapsed again; the server has K2 under it now.
        store.setChildren([page("K1", parent: "K")], of: "K")
        box.store = store
        await store.reload()
        #expect(store.visibleRows.map(\.id) == ["A", "A1", "K", "K2", "Z"])
    }

    /// Two quick changes start two refreshes and the first finishes last: the tree keeps the second one's data.
    @Test func olderReloadFinishingLastKeepsTheNewerTree() async {
        let box = StoreBox()
        let store = PageTreeStore(spaceId: "s") { _, _ in
            var id = "new"
            // The first refresh's root call runs the second refresh before returning its older data.
            if let store = box.store {
                box.store = nil
                await store.reload()
                id = "old"
            }
            return Paginated(items: [SidebarPage(id: id, title: id)], meta: PaginationMeta(hasNextPage: false, nextCursor: nil))
        }

        box.store = store
        await store.reload()
        #expect(store.visibleRows.map(\.id) == ["new"])
    }

    private final class StoreBox { var store: PageTreeStore? }
    private final class FailureBox { var error: APIError? }

    private actor Calls {
        var list: [String] = []
        func record(_ parent: String, _ cursor: String?) { list.append("\(parent)/\(cursor ?? "-")") }
    }
}
