import SwiftUI
import DocmostKit

/// Space view: header card with search, "Hierarchy | Recent" switcher, page tree as a card, FAB for new pages.
struct SpaceView: View {
    @Environment(AppSession.self) private var session
    @Environment(ContentChanges.self) private var changes
    @Environment(ReaderNavigation.self) private var navigation
    let space: Space
    @State private var store: PageTreeStore
    @State private var runner: PageActionRunner?
    @State private var mode: Mode = .hierarchy
    @State private var recent: LoadState<[Page]> = .idle
    @State private var search: SearchModel
    @State private var isCreatingPage = false
    @FocusState private var searchFocused: Bool

    private enum Mode: Hashable { case hierarchy, recent }

    init(space: Space) {
        self.space = space
        self._store = State(initialValue: PageTreeStore(spaceId: space.id))
        self._search = State(initialValue: SearchModel(spaceId: space.id))
    }

    private var canEdit: Bool { space.membership?.canEditPages ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                if search.isActive {
                    SearchResultsCard(search: search)
                } else {
                    Picker("View", selection: $mode) {
                        Text("Hierarchy").tag(Mode.hierarchy)
                        Text("Recent").tag(Mode.recent)
                    }
                    .pickerStyle(.segmented)
                    switch mode {
                    case .hierarchy: treeCard
                    case .recent: recentCard
                    }
                }
            }
            .padding()
            .padding(.bottom, 72)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(space.name)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canEdit {
                    NavigationLink(value: SpaceTrashRoute(spaceId: space.id)) {
                        Label("Trash", systemImage: "trash")
                    }
                    .accessibilityIdentifier("space-trash")
                }
                WorkspaceMenu()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if canEdit {
                Button {
                    Task { await createPage(parentPageId: nil) }
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(isCreatingPage)
                .padding(20)
                .accessibilityLabel("New Page")
                .accessibilityIdentifier("space-new-page")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .modifier(OptionalPageActionSheets(runner: runner))
        .onChange(of: changes.version) { _, _ in
            if changes.lastChangedSpaceId == nil || changes.lastChangedSpaceId == space.id {
                Task { await store.reload() }
                if mode == .recent { Task { await loadRecent() } }
            }
        }
        .refreshable {
            await store.reload()
            if mode == .recent { await loadRecent() }
        }
        .task {
            configureStoreIfNeeded()
            await store.loadRootIfNeeded()
            if DebugLaunch.expandsTree {
                for page in store.rootPages where page.mayHaveChildren {
                    await store.toggle(page.id)
                }
            }
        }
        .task(id: mode) {
            // On every switch: `onChange` reloads Recent only while it shows, so tree changes would stay hidden.
            if mode == .recent { await loadRecent() }
        }
        .task(id: search.key) {
            search.session = session
            await search.run()
        }
    }

    // MARK: - Header

    private var hero: some View {
        @Bindable var search = search
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SpaceLogoView(space: space, baseURL: session.server?.url, size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(space.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    if let description = space.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let role = space.role {
                            Chip(text: String(localized: role.title), symbol: "person.badge.key")
                        }
                        if let count = space.memberCount {
                            Chip(text: String(localized: "\(count) members"), symbol: "person.2")
                        }
                    }
                }
            }
            // Inline search: with a query, results replace the tree and "Recent".
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search in \(space.name)", text: $search.query)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .accessibilityIdentifier("space-search")
                if search.isSearching {
                    ProgressView().controlSize(.small)
                } else if !search.query.isEmpty {
                    Button {
                        search.clear()
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("space-search-clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Tree

    @ViewBuilder
    private var treeCard: some View {
        switch store.rootState {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity).padding(40)
        case .failed(let error):
            ErrorStateView(error: error) { await store.reload() }
        case .loaded:
            if store.rootPages.isEmpty {
                ContentUnavailableView("No pages yet", systemImage: "doc", description: Text("Pages created in this space will show up here."))
                    .padding(.vertical, 20)
            } else if let runner {
                let rows = store.visibleRows
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        TreeRow(row: row, store: store, runner: runner, canEdit: canEdit) {
                            Task { await createPage(parentPageId: row.page.id) }
                        }
                        .modifier(TreeDragModifier(page: row.page, depth: row.depth, spaceId: space.id, enabled: canEdit, store: store) { draggedId, zone in
                            Task { await movePage(draggedId, relativeTo: row.page, zone: zone) }
                        })
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 16 + CGFloat(row.depth) * 20)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var recentCard: some View {
        switch recent {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity).padding(40)
        case .failed(let error):
            ErrorStateView(error: error) { await loadRecent() }
        case .loaded(let pages):
            if pages.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "clock", description: Text("Recently updated pages in this space show up here."))
                    .padding(.vertical, 20)
            } else if let runner {
                LazyVStack(spacing: 0) {
                    ForEach(pages) { page in
                        NavigationLink(value: PageSelection(page: page)) {
                            HStack(spacing: 10) {
                                PageIconView(icon: page.icon, size: 22, isBase: page.isBase == true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.displayTitle).lineLimit(2)
                                    if let updatedAt = page.updatedAt {
                                        Text(updatedAt, format: .relative(presentation: .named))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { PageActionsMenu(page: PageRef(page), runner: runner, canEdit: canEdit) }
                        .trashConfirmation(for: PageRef(page), runner: runner)
                        if page.id != pages.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    // MARK: - Loading

    /// The store needs the session and a loader, which exist only once the environment is available.
    private func configureStoreIfNeeded() {
        if runner == nil {
            runner = PageActionRunner(session: session, changes: changes)
        }
        guard !store.hasLoader, let client = session.client else { return }
        let spaceId = space.id
        let session = session
        store = PageTreeStore(spaceId: spaceId, cache: session.ready?.cache) { parent, cursor in
            try await session.perform {
                if let parent {
                    return try await client.send(Endpoints.Pages.children(of: parent, cursor: cursor))
                }
                return try await client.send(Endpoints.Pages.sidebar(spaceId: spaceId, cursor: cursor))
            }
        }
    }

    /// Reorders or reparents a page (`pages/move` with a fractional-index position, like the web client).
    private func movePage(_ pageId: String, relativeTo target: SidebarPage, zone: TreeDropZone) async {
        // A page can't move into its own subtree: not on, before or after one of its subpages.
        guard session.client != nil, !store.isDescendant(target.id, of: pageId) else { return }
        let newParentId: String?
        let position: String
        do {
            switch zone {
            case .nest:
                newParentId = target.id
                if !store.isExpanded(target.id) { await store.toggle(target.id) } else if store.children(of: target.id).isEmpty { await store.loadChildren(of: target.id) }
                let last = store.children(of: target.id).last { $0.id != pageId }
                position = try FractionalIndex.jitteredKeyBetween(last?.position, nil)
            case .before, .after:
                newParentId = target.parentPageId
                let all = (target.parentPageId.map { store.children(of: $0) } ?? store.rootPages).filter { $0.id != pageId }
                guard let index = all.firstIndex(where: { $0.id == target.id }) else { return }
                let insertIndex = zone == .before ? index : index + 1
                let lower = insertIndex > 0 ? all[insertIndex - 1].position : nil
                let upper = insertIndex < all.count ? all[insertIndex].position : nil
                position = try FractionalIndex.jitteredKeyBetween(lower, upper)
            }
            _ = try await session.send(Endpoints.Pages.move(pageId: pageId, position: position, parentPageId: newParentId))
            changes.pageChanged(in: space.id)
        } catch {
            runner?.toast = error.userMessage
        }
    }

    /// Creates an empty page and opens it for editing right away (title focused).
    private func createPage(parentPageId: String?) async {
        // The FAB, Cmd-N and every row's "+" land here: a second tap during the request must not create a second page.
        guard !isCreatingPage, session.client != nil else { return }
        isCreatingPage = true
        defer { isCreatingPage = false }
        do {
            let created = try await session.send(Endpoints.Pages.create(spaceId: space.id, parentPageId: parentPageId, title: nil))
            // `pageChanged` below makes `onChange` reload the tree, including the expanded parent's children.
            if let parentPageId { store.setExpanded(parentPageId, true) }
            changes.pageChanged(in: space.id)
            var selection = PageSelection(page: created)
            selection.focusTitle = true
            navigation.open(selection)
        } catch {
            runner?.toast = error.userMessage
        }
    }

    private func loadRecent() async {
        guard session.client != nil else { return }
        if recent.value == nil { recent = .loading }
        do {
            let page = try await session.send(Endpoints.Pages.recent(spaceId: space.id, limit: 50))
            recent = .loaded(page.items)
        } catch is CancellationError {
        } catch {
            if recent.value == nil { recent = .failed(error) }
        }
    }
}

/// Page tree row: indent guide lines, chevron, icon, title, menu and "+" for subpages.
private struct TreeRow: View {
    let row: PageTreeStore.Row
    let store: PageTreeStore
    let runner: PageActionRunner
    let canEdit: Bool
    let onAddSubpage: () -> Void

    private var page: SidebarPage { row.page }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<row.depth, id: \.self) { _ in
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .padding(.horizontal, 9.5)
            }
            disclosureButton
            NavigationLink(value: PageSelection(page: page)) {
                HStack(spacing: 8) {
                    PageIconView(icon: page.icon, isBase: page.isBase == true)
                    Text(page.displayTitle)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page-\(page.id)")
            Menu {
                PageActionsMenu(page: PageRef(page), runner: runner, canEdit: canEdit && (page.canEdit ?? true))
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
            .trashConfirmation(for: PageRef(page), runner: runner)
            if canEdit {
                Button(action: onAddSubpage) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Subpage")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tree-row-\(page.id)")
    }

    @ViewBuilder
    private var disclosureButton: some View {
        if store.isLoading(page.id) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
        } else if page.mayHaveChildren {
            Button {
                Task { await store.toggle(page.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(store.isExpanded(page.id) ? 90 : 0))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(store.isExpanded(page.id) ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: 24, height: 24)
        }
    }
}

/// Attaches the action dialogs only once the runner exists.
private struct OptionalPageActionSheets: ViewModifier {
    let runner: PageActionRunner?

    func body(content: Content) -> some View {
        if let runner {
            content.pageActionSheets(runner)
        } else {
            content
        }
    }
}
