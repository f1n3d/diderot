import Foundation
import Observation
import DocmostKit

/// Page tree of a space: children load lazily on expand; the server order is kept.
@MainActor
@Observable
final class PageTreeStore {
    struct Row: Identifiable, Hashable {
        let page: SidebarPage
        let depth: Int
        var id: String { page.id }
    }

    let spaceId: String
    /// Children per parent page; the root level is under `rootKey`.
    private(set) var children: [String: [SidebarPage]] = [:]
    private(set) var loadingParents: Set<String> = []
    private(set) var expanded: Set<String> = []
    private(set) var rootState: LoadState<Void> = .idle

    private static let rootKey = "__root__"
    private let loader: (@MainActor (_ parentPageId: String?, _ cursor: String?) async throws -> Paginated<SidebarPage>)?
    private let cache: DiskCache?
    @ObservationIgnored private var reloads = 0

    /// - Parameters:
    ///   - loader: loads one batch of children (`nil` = root); without one the tree stays local (tests).
    ///   - cache: offline copy per level, shown when loading fails unless the level is gone (403, 404).
    init(spaceId: String, cache: DiskCache? = nil, loader: (@MainActor (String?, String?) async throws -> Paginated<SidebarPage>)? = nil) {
        self.spaceId = spaceId
        self.cache = cache
        self.loader = loader
    }

    // MARK: - Reading

    var hasLoader: Bool { loader != nil }

    var rootPages: [SidebarPage] { children[Self.rootKey] ?? [] }

    func children(of pageId: String) -> [SidebarPage] { children[pageId] ?? [] }

    func isExpanded(_ pageId: String) -> Bool { expanded.contains(pageId) }

    func isLoading(_ pageId: String) -> Bool { loadingParents.contains(pageId) }

    /// Visible rows in display order (depth-first over expanded nodes).
    var visibleRows: [Row] {
        var rows: [Row] = []
        // Each page once: levels load at different times, so a page a collaborator moved meanwhile can turn up under its
        // old and its new parent, even below itself, and the walk went on forever.
        var shown: Set<String> = []
        func visit(_ pages: [SidebarPage], depth: Int) {
            for page in pages where shown.insert(page.id).inserted {
                rows.append(Row(page: page, depth: depth))
                if expanded.contains(page.id), let kids = children[page.id] {
                    visit(kids, depth: depth + 1)
                }
            }
        }
        visit(rootPages, depth: 0)
        return rows
    }

    /// A visible row's ancestors are visible too, so a row's subtree is the run of deeper rows right below it.
    func isDescendant(_ pageId: String, of ancestorId: String) -> Bool {
        let rows = visibleRows
        guard let start = rows.firstIndex(where: { $0.id == ancestorId }) else { return false }
        return rows[(start + 1)...].prefix { $0.depth > rows[start].depth }.contains { $0.id == pageId }
    }

    // MARK: - Loading

    /// Also after a failure: SwiftUI cancels the space view's load when a push or tab switch hides it.
    func loadRootIfNeeded() async {
        switch rootState {
        case .idle, .failed: await reload()
        case .loading, .loaded: break
        }
    }

    func reload() async {
        reloads += 1
        let generation = reloads
        // A loaded tree stays while refreshing and when the refresh fails.
        if rootState.value == nil { rootState = .loading }
        let wasExpanded = expanded
        let root: [SidebarPage]
        do {
            root = try await loadAll(parent: nil)
        } catch is CancellationError {
            // A push or tab switch cancelled the first load: with nothing shown, the spinner stayed for good.
            // `loadRootIfNeeded` starts it again when the space shows again.
            if generation == reloads, rootState.value == nil { rootState = .idle }
            return
        } catch let error as APIError where error.isGone {
            // The space was deleted or unshared: say so instead of leaving the shown tree up.
            rootState = .failed(error)
            return
        } catch {
            if rootState.value == nil { rootState = .failed(error) }
            return
        }
        // Drop collapsed levels so a tap during the walk loads them fresh.
        children = children.filter { $0.key == Self.rootKey || expanded.contains($0.key) }
        // Reload each expanded level still in the tree, top-down, and show the result in one step.
        var levels = [Self.rootKey: root]
        var pending = root
        while let page = pending.popLast() {
            guard expanded.contains(page.id), levels[page.id] == nil,
                  let level = try? await loadAll(parent: page.id)
            else { continue }
            levels[page.id] = level
            pending += level
        }
        // A refresh started meanwhile shows the newer tree.
        guard generation == reloads else { return }
        // Pages the walk didn't reach (gone, or under a collapsed page) or that failed to load collapse, so the next
        // tap loads them again. A page expanded meanwhile keeps the level its tap loaded.
        expanded.subtract(wasExpanded.subtracting(levels.keys))
        children = levels.merging(children.filter { expanded.contains($0.key) }) { fresh, _ in fresh }
        rootState = .loaded(())
    }

    func toggle(_ pageId: String) async {
        if expanded.contains(pageId) {
            expanded.remove(pageId)
            return
        }
        expanded.insert(pageId)
        if children[pageId] == nil {
            await loadChildren(of: pageId)
        }
    }

    func loadChildren(of pageId: String) async {
        guard !loadingParents.contains(pageId) else { return }
        loadingParents.insert(pageId)
        defer { loadingParents.remove(pageId) }
        do {
            children[pageId] = try await loadAll(parent: pageId)
        } catch {
            // Expanded with nothing below, it would look like a page without subpages; the next tap loads it again.
            expanded.remove(pageId)
        }
    }

    /// For tests.
    func setChildren(_ pages: [SidebarPage], of parentPageId: String?) {
        children[parentPageId ?? Self.rootKey] = pages
        if parentPageId == nil { rootState = .loaded(()) }
    }

    func setExpanded(_ pageId: String, _ isExpanded: Bool) {
        if isExpanded { expanded.insert(pageId) } else { expanded.remove(pageId) }
    }

    /// Loads a level until `hasNextPage` is false, like the web client (`limit: 100`). A load error falls back to the
    /// cached level and rethrows only without one; a level that is gone (403, 404) drops its cache and rethrows.
    private func loadAll(parent: String?) async throws -> [SidebarPage] {
        guard let loader else { return children[parent ?? Self.rootKey] ?? [] }
        let cacheKey = CacheKey.tree(spaceId: spaceId, parentPageId: parent)
        do {
            let result = try await Paginated.all { try await loader(parent, $0) }
            await cache?.write(result, key: cacheKey)
            return result
        } catch let error as APIError where error.isGone {
            await cache?.remove(key: cacheKey)
            throw error
        } catch {
            if let cached = await cache?.read([SidebarPage].self, key: cacheKey) {
                return cached
            }
            throw error
        }
    }
}
