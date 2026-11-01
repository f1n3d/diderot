import Foundation
import Observation
import DocmostKit

/// Loaded rows of a table or kanban column, with the cursor to load more.
nonisolated struct BaseRowList: Codable, Sendable, Equatable {
    var rows: [BaseRow] = []
    var cursor: String?
    var hasMore = false
}

/// Column of a kanban board: one choice of the grouping property, or "No value".
nonisolated struct BaseKanbanColumn: Identifiable, Codable, Sendable, Equatable {
    static let noValueId = "__no_value"

    let id: String
    /// `nil` for the "No value" column.
    let name: String?
    let color: String?
    var list = BaseRowList()

    var isNoValue: Bool { id == Self.noValueId }
}

/// View state for the offline cache.
nonisolated struct BaseViewSnapshot: Codable, Sendable {
    var table: BaseRowList?
    var columns: [BaseKanbanColumn]?
    var users: [String: UserRef]
    var pages: [String: PageRef]
}

/// Database (base) of a page: schema, selected view and its rows; loads the cache first, then the server. Requests
/// carry the view's filter (table requests also its sorts); each kanban column is queried separately (web parity).
@MainActor
@Observable
final class BaseModel {
    let pageId: String
    private(set) var state: LoadState<Base> = .idle
    private(set) var selectedViewId: String?
    private(set) var table = BaseRowList()
    private(set) var columns: [BaseKanbanColumn] = []
    /// Rows outside what the view shows: board rows edited into a hidden column (or one added since loading), and an
    /// entry opened from a link that the table's loaded rows or filter leave out. Their open detail sheet keeps them.
    private var offBoardRows: [String: BaseRow] = [:]
    private(set) var users: [String: UserRef] = [:]
    private(set) var pages: [String: PageRef] = [:]
    private(set) var isLoadingRows = false
    /// Load failure while no rows are shown; with rows visible it shows as a toast instead.
    private(set) var rowsError: (any Error)?
    private(set) var isUploading = false
    /// Most recently created row; table and board scroll to it.
    private(set) var lastCreatedRowId: String?
    /// Toast: failed writes, confirmations ("Link copied"), input and file errors.
    var toast: String?
    @ObservationIgnored private unowned let session: AppSession
    @ObservationIgnored private var loadingMore: Set<String> = []
    /// Writes run one at a time so the server applies them in input order.
    @ObservationIgnored private var writeQueue: Task<Void, Never>?
    /// Pending changes and their rows' last confirmed state, so a response can't overwrite later changes already shown.
    @ObservationIgnored private var pendingWrites: [PendingWrite] = []
    @ObservationIgnored private var confirmedRows: [String: BaseRow] = [:]
    /// Rows deleted, or whose delete waits in the write queue: an earlier change's response, a load (also one the
    /// server answered before the delete) or a view's offline copy doesn't bring them back.
    @ObservationIgnored private var deletedRowIds: Set<String> = []
    /// Rows a write saved while a load ran: an answer the server gave before the write doesn't revert them.
    @ObservationIgnored private var savedDuringLoad: [String: BaseRow] = [:]
    @ObservationIgnored private var runningLoads = 0
    /// Set by the screen. Offline the database is read-only, as pages are: a save would fail at once.
    var isOffline = false
    /// Text a failed save didn't get to the server, by "rowId/propertyId": its field shows it again, not the old value.
    /// Unless the server refused it for good, it is also kept for the server (`UnsentCell`), which this restores at the
    /// first load.
    private(set) var unsavedDrafts: [String: String] = [:]
    /// The sign-in this database was opened with. Its requests and cache stay with it: after a switch or sign-out a
    /// queued write doesn't reach the new server, and a late answer doesn't go into its cache.
    @ObservationIgnored private let owner: ReadySession?

    /// The server this database was opened on; its file uploads are staged in that server's folder (`UploadFile`).
    var serverURL: URL? { owner?.server.url }

    private struct PendingWrite {
        let id = UUID()
        let rowId: String
        let cells: [String: JSONValue]
        let position: String?
    }

    /// A field's typed text in a save (`setCell`'s `typed`).
    private struct TypedInput {
        let propertyId: String
        let text: String
        /// An input a failed save kept for the field, which this one replaces.
        let replacesKept: Bool
    }

    init(pageId: String, session: AppSession) {
        self.pageId = pageId
        self.session = session
        self.owner = session.ready
        self.selectedViewId = UserDefaults.standard.string(forKey: Self.viewKey(pageId))
    }

    private static func viewKey(_ pageId: String) -> String { "base.view.\(pageId)" }

    var base: Base? { state.value }

    /// Views in Docmost order.
    var views: [BaseView] {
        (base?.views ?? []).sorted { ($0.position ?? "") < ($1.position ?? "") }
    }

    var selectedView: BaseView? {
        views.first { $0.id == selectedViewId } ?? views.first
    }

    /// Entry order for "previous / next" in the detail, as on the web: the table's rows; on a board every card by
    /// position.
    var orderedRowIds: [String] {
        guard selectedView?.kind == .kanban else { return table.rows.map(\.id) }
        return Self.byPosition(columns.flatMap(\.list.rows)).map(\.id)
    }

    // MARK: - Loading

    func load() async {
        guard owner != nil else { return }
        // Opening offline, the page itself says it shows the saved version.
        let isOpening = state.value == nil
        if state.value == nil {
            await restoreUnsent()
            if let cached = await ownSession?.cache.read(Base.self, key: CacheKey.base(pageId)) {
                state = .loaded(cached)
                await restoreSnapshot()
            } else {
                state = .loading
            }
        }
        do {
            let base = try await send(Endpoints.Bases.info(pageId: pageId))
            state = .loaded(base)
            await ownSession?.cache.write(base, key: CacheKey.base(pageId))
            await loadRows()
        } catch let error as APIError where error.isGone {
            // Deleted for good or access removed: show that instead of the saved copy, and drop the copy and its rows.
            let keys = [CacheKey.base(pageId)] + views.map { CacheKey.baseView(pageId, viewId: $0.id) }
            state = .failed(error)
            for key in keys { await ownSession?.cache.remove(key: key) }
        } catch {
            let isOffline = if case .network = error as? APIError { true } else { false }
            if state.value == nil { state = .failed(error) } else { showRowsError(error, notice: !(isOpening && isOffline)) }
        }
    }

    func select(_ view: BaseView) async {
        guard view.id != selectedView?.id else { return }
        selectedViewId = view.id
        UserDefaults.standard.set(view.id, forKey: Self.viewKey(pageId))
        table = BaseRowList()
        columns = []
        offBoardRows = [:]
        await restoreSnapshot()
        await loadRows()
    }

    /// First result page(s) of the selected view.
    func loadRows() async {
        guard let base, let view = selectedView else { return }
        isLoadingRows = true
        rowsError = nil
        runningLoads += 1
        // Switched tabs (or the view changed in a reload) meanwhile: the newer load shows the rows.
        defer {
            runningLoads -= 1
            if runningLoads == 0 { savedDuringLoad = [:] }
            if selectedView == view { isLoadingRows = false }
        }
        do {
            switch view.kind {
            case .table:
                let page = try await fetch(filter: BaseLayout.filter(of: view), sorts: BaseLayout.sorts(of: view), cursor: nil)
                guard selectedView == view else { return }
                table = BaseRowList(rows: page.items, cursor: page.meta.nextCursor, hasMore: page.meta.hasNextPage)
                table.rows.removeAll { deletedRowIds.contains($0.id) }
                merge(page.references)
                reapplyOwnChanges()
            case .kanban:
                guard let groupBy = BaseLayout.groupByProperty(base: base, view: view) else {
                    columns = []
                    return
                }
                var loaded = BaseLayout.kanbanColumns(view: view, groupBy: groupBy)
                let viewFilter = BaseLayout.filter(of: view)
                // Columns load concurrently; results apply in column order.
                let requests = loaded.map { column in
                    let filter = BaseLayout.columnFilter(viewFilter: viewFilter, groupBy: groupBy.id, column: column)
                    return Task { try await self.fetch(filter: filter, sorts: nil, cursor: nil) }
                }
                for (index, request) in requests.enumerated() {
                    let page = try await request.value
                    loaded[index].list = BaseRowList(
                        rows: Self.byPosition(page.items), cursor: page.meta.nextCursor, hasMore: page.meta.hasNextPage
                    )
                    merge(page.references)
                }
                guard selectedView == view else { return }
                for index in loaded.indices { loaded[index].list.rows.removeAll { deletedRowIds.contains($0.id) } }
                columns = loaded
                reapplyOwnChanges()
            }
            await storeSnapshot()
        } catch is CancellationError {
        } catch {
            if selectedView == view { showRowsError(error) }
        }
    }

    /// Saved rows stay visible (with a toast if `notice`); with none, the view shows the error with "Try Again".
    private func showRowsError(_ error: any Error, notice: Bool = true) {
        // Leaving the screen cancels the load: no error, it reloads on return.
        guard !Task.isCancelled else { return }
        if table.rows.isEmpty && columns.isEmpty { rowsError = error } else if notice { toast = error.userMessage }
    }

    func loadMoreTable() async {
        guard let view = selectedView, table.hasMore, let cursor = table.cursor, !loadingMore.contains("table") else { return }
        loadingMore.insert("table")
        defer { loadingMore.remove("table") }
        do {
            let page = try await fetch(filter: BaseLayout.filter(of: view), sorts: BaseLayout.sorts(of: view), cursor: cursor)
            guard selectedView == view else { return }
            let known = Set(table.rows.map(\.id)).union(deletedRowIds)
            table.rows += page.items.filter { !known.contains($0.id) }
            table.cursor = page.meta.nextCursor
            table.hasMore = page.meta.hasNextPage
            merge(page.references)
        } catch {
            if selectedView == view { toast = error.userMessage }
        }
    }

    func loadMore(columnId: String) async {
        guard let base, let view = selectedView, let groupBy = BaseLayout.groupByProperty(base: base, view: view),
              let index = columns.firstIndex(where: { $0.id == columnId }), columns[index].list.hasMore,
              let cursor = columns[index].list.cursor, !loadingMore.contains(columnId)
        else { return }
        loadingMore.insert(columnId)
        defer { loadingMore.remove(columnId) }
        let filter = BaseLayout.columnFilter(viewFilter: BaseLayout.filter(of: view), groupBy: groupBy.id, column: columns[index])
        do {
            let page = try await fetch(filter: filter, sorts: nil, cursor: cursor)
            guard selectedView == view, let current = columns.firstIndex(where: { $0.id == columnId }) else { return }
            let known = Set(columns[current].list.rows.map(\.id)).union(deletedRowIds)
            columns[current].list.rows = Self.byPosition(columns[current].list.rows + page.items.filter { !known.contains($0.id) })
            columns[current].list.cursor = page.meta.nextCursor
            columns[current].list.hasMore = page.meta.hasNextPage
            merge(page.references)
        } catch {
            if selectedView == view { toast = error.userMessage }
        }
    }

    /// Kanban cards sort by position (web parity: plain string comparison of the keys).
    private static func byPosition(_ rows: [BaseRow]) -> [BaseRow] {
        rows.sorted { ($0.position ?? "") < ($1.position ?? "") }
    }

    private func fetch(filter: JSONValue?, sorts: JSONValue?, cursor: String?) async throws -> BaseRowsPage {
        try await send(Endpoints.Bases.rows(pageId: pageId, filter: filter, sorts: sorts, cursor: cursor))
    }

    /// One request with the sign-in this database was opened with (`AppSession.send(_:on:)`); each request checks it
    /// again, so a flow's second request doesn't follow a switch either.
    private func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        guard let owner else { throw CancellationError() }
        return try await session.send(endpoint, on: owner)
    }

    /// The app's session while it is still the one this database was opened with; nil after a switch or sign-out.
    private var ownSession: ReadySession? {
        guard let owner, session.isStillCurrent(owner) else { return nil }
        return session.ready
    }

    private func merge(_ references: BaseReferences?) {
        if let more = references?.users { users.merge(more) { _, new in new } }
        if let more = references?.pages { pages.merge(more) { _, new in new } }
    }

    // MARK: - Editing

    /// Why the database can't be edited.
    enum ReadOnlyReason {
        /// The server's license doesn't unlock databases (writing requires Business).
        case license
        /// No write permission for this page.
        case permission
        /// No connection: a save would fail at once.
        case offline
    }

    var readOnlyReason: ReadOnlyReason? {
        guard ownSession?.entitlements.has("bases") == true else { return .license }
        guard base?.canEdit == true else { return .permission }
        return isOffline ? .offline : nil
    }

    /// The text a failed save of this cell didn't get to the server, if any.
    func unsavedDraft(rowId: String, propertyId: String) -> String? { unsavedDrafts["\(rowId)/\(propertyId)"] }

    var canEdit: Bool { base != nil && readOnlyReason == nil }

    /// Current state of a row from the table or board.
    /// Makes a row available to the detail sheet, loading it by id if the view doesn't show it (a linked entry outside
    /// the loaded rows or the view's filter, as the web does). False if it can't be loaded.
    func fetchRowIfNeeded(_ id: String) async -> Bool {
        if row(id: id) != nil { return true }
        guard let row = try? await send(Endpoints.Bases.rowInfo(pageId: pageId, rowId: id)) else { return false }
        offBoardRows[row.id] = row
        return true
    }

    func row(id: String) -> BaseRow? {
        if let row = table.rows.first(where: { $0.id == id }) { return row }
        for column in columns {
            if let row = column.list.rows.first(where: { $0.id == id }) { return row }
        }
        return offBoardRows[id]
    }

    /// Grouping property of the selected board.
    var groupByProperty: BaseProperty? {
        guard let base, let view = selectedView, view.kind == .kanban else { return nil }
        return BaseLayout.groupByProperty(base: base, view: view)
    }

    /// Changes a cell optimistically; the response (with recomputed formulas and "Last edited") replaces the row, and a
    /// failure restores the previous state. `nil` clears the cell.
    /// `typed`: the field's text, kept if the save fails (see `unsavedDrafts`).
    func setCell(rowId: String, propertyId: String, to value: JSONValue?, typed draft: String? = nil) async {
        guard let current = row(id: rowId) else { return }
        // The newest input replaces one a failed save kept, for the server too.
        let replacesKept = unsavedDrafts.removeValue(forKey: "\(rowId)/\(propertyId)") != nil
        let value = value.flatMap { $0.isNull ? nil : $0 }
        guard current.cells[propertyId] != value else {
            if replacesKept { await forgetUnsent(rowId: rowId, propertyId: propertyId) }
            return
        }
        let input = draft.map { TypedInput(propertyId: propertyId, text: $0, replacesKept: replacesKept) }
        await write(rowId: rowId, cells: [propertyId: value ?? .null], position: nil, typed: input)
    }

    /// Moves a card into a column, before `anchorId` (after it if `below`) or to the end. Column and order change in
    /// one call (web parity); the position applies to all views.
    func moveCard(_ rowId: String, to columnId: String, beside anchorId: String? = nil, below: Bool = false) async {
        guard anchorId != rowId, let groupBy = groupByProperty, let current = row(id: rowId),
              let column = columns.first(where: { $0.id == columnId })
        else { return }
        let others = column.list.rows.filter { $0.id != rowId }
        let index = anchorId.flatMap { id in others.firstIndex { $0.id == id } }.map { below ? $0 + 1 : $0 } ?? others.endIndex
        let previous = index > others.startIndex ? others[index - 1].position : nil
        let next = index < others.endIndex ? others[index].position : nil
        let sourceColumnId = BaseLayout.columnId(of: current, groupBy: groupBy)
        // Already in place.
        if sourceColumnId == columnId, let position = current.position,
           (previous.map { $0 < position } ?? true), (next.map { position < $0 } ?? true)
        {
            return
        }
        guard let position = (try? FractionalIndex.jitteredKeyBetween(previous, next))
            ?? (try? FractionalIndex.jitteredKeyBetween(others.last?.position, nil))
        else { return }
        var cells: [String: JSONValue] = [:]
        if sourceColumnId != columnId {
            cells[groupBy.id] = column.isNoValue ? .null : .string(column.id)
        }
        await write(rowId: rowId, cells: cells, position: position)
    }

    /// Creates a row (table: at the end; board: top or bottom of a column); `nil` on failure or if the view changed.
    func createRow(inColumn columnId: String? = nil, atTop: Bool = false) async -> BaseRow? {
        guard canEdit else { return nil }
        let view = selectedView
        var cells: [String: JSONValue] = [:]
        var position: String?
        if let groupBy = groupByProperty {
            guard let column = columns.first(where: { $0.id == columnId }) ?? columns.first else { return nil }
            if !column.isNoValue { cells[groupBy.id] = .string(column.id) }
            let rows = column.list.rows
            position = atTop
                ? (try? FractionalIndex.jitteredKeyBetween(nil, rows.first?.position))
                : (try? FractionalIndex.jitteredKeyBetween(rows.last?.position, nil))
        }
        let pageId = pageId
        do {
            let created = try await enqueue {
                try await self.send(Endpoints.Bases.createRow(pageId: pageId, cells: cells, position: position))
            }
            // Switched tabs meanwhile: the new view shows the row only if its own load found it; no sheet opens there.
            guard selectedView == view else { return nil }
            if groupByProperty != nil {
                place(created)
            } else {
                table.rows.append(created)
            }
            lastCreatedRowId = created.id
            await storeSnapshot()
            return created
        } catch {
            toast = error.userMessage
            return nil
        }
    }

    /// Deletes a row (permanently, web parity).
    func deleteRow(_ rowId: String) async {
        guard canEdit, let old = row(id: rowId) else { return }
        let view = selectedView
        let tableIndex = table.rows.firstIndex { $0.id == rowId }
        table.rows.removeAll { $0.id == rowId }
        for index in columns.indices {
            columns[index].list.rows.removeAll { $0.id == rowId }
        }
        offBoardRows[rowId] = nil
        deletedRowIds.insert(rowId)
        let pageId = pageId
        do {
            _ = try await enqueue { try await self.send(Endpoints.Bases.deleteRow(pageId: pageId, rowId: rowId)) }
            await storeSnapshot()
        } catch {
            deletedRowIds.remove(rowId)
            toast = error.userMessage
            // Switched tabs meanwhile: the new view loaded without the row, so it loads again to show it if it fits.
            guard selectedView == view else {
                await loadRows()
                return
            }
            if let tableIndex, !table.rows.contains(where: { $0.id == rowId }) {
                table.rows.insert(old, at: min(tableIndex, table.rows.count))
            }
            if groupByProperty != nil { place(old) }
            await storeSnapshot()
        }
    }

    /// Uploads a file to the database's page and appends it to the file cell.
    /// Uploads a staged file (`UploadFile`) and adds it to the cell; the staged copy goes afterwards.
    func attachFile(rowId: String, propertyId: String, file: UploadFile) async {
        defer { file.remove() }
        guard canEdit, let owner else { return }
        isUploading = true
        defer { isUploading = false }
        let pageId = pageId
        let mimeType = file.mimeType
        do {
            let attachment = try await session.perform(on: owner) {
                try await $0.uploadAttachment(pageId: pageId, fileName: file.fileName, mimeType: file.mimeType, fileURL: file.fileURL)
            }
            let files = row(id: rowId)?.cells[propertyId]?.arrayValue ?? []
            await setCell(rowId: rowId, propertyId: propertyId, to: .array(files + [BaseValue.file(attachment, mimeType: mimeType)]))
        } catch {
            toast = error.userMessage
        }
    }

    /// Adds a select or multi-select option (not status, web parity); waits for the server before a cell gets it.
    func addChoice(named name: String, to propertyId: String) async -> BaseChoice? {
        guard canEdit, var base, let property = base.property(id: propertyId),
              property.kind == .select || property.kind == .multiSelect
        else { return nil }
        let existing = BaseLayout.choices(of: property)
        let choice = BaseChoice(
            id: BaseValue.newChoiceId(), name: name,
            color: BaseValue.choiceColors[existing.count % BaseValue.choiceColors.count]
        )
        let pageId = pageId
        do {
            let result = try await enqueue {
                // Onto the server's current options, not the copy loaded with the screen (there are no live updates): the
                // server replaces the whole list, so options others added, renamed or recolored meanwhile would go.
                let current = try await self.send(Endpoints.Bases.info(pageId: pageId)).property(id: propertyId)
                let options = BaseValue.typeOptions((current ?? property).typeOptions, adding: choice)
                return try await self.send(Endpoints.Bases.updateProperty(pageId: pageId, propertyId: propertyId, typeOptions: options))
            }
            // A reload may have brought a newer base meanwhile.
            base = self.base ?? base
            base.replace(result.property)
            state = .loaded(base)
            await ownSession?.cache.write(base, key: CacheKey.base(pageId))
            return choice
        } catch {
            toast = error.userMessage
            return nil
        }
    }

    /// People search (web parity): all workspace members; without a query, the first ten.
    func suggestPeople(_ query: String) async -> [SearchSuggestions.UserSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = Endpoints.Search.suggest(query: trimmed, users: true, pages: false, limit: trimmed.isEmpty ? 10 : 25)
        return (try? await send(endpoint))?.users ?? []
    }

    /// Page search (web parity): pages in the database's space first.
    func suggestPages(_ query: String) async -> [SearchSuggestions.PageSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = Endpoints.Search.suggest(
            query: trimmed, users: false, pages: true, spaceId: base?.spaceId, limit: trimmed.isEmpty ? 5 : 25
        )
        return (try? await send(endpoint))?.pages ?? []
    }

    /// Records picked people and pages so cells show their names right away.
    func remember(user: UserRef) { users[user.id] = user }
    func remember(page: PageRef) { pages[page.id] = page }

    // MARK: Internal writes

    /// Cell patch and/or new position of a row: queued and shown immediately.
    /// `typed`: a field's text, which a failed save keeps (`unsavedDrafts`, `UnsentCell`) before the row shows its old
    /// value again.
    private func write(rowId: String, cells: [String: JSONValue], position: String?, typed input: TypedInput? = nil) async {
        // Not `canEdit`: a field that saves as the database turns read-only offline still tries, so its text is kept.
        guard base?.canEdit == true, ownSession?.entitlements.has("bases") == true, let current = row(id: rowId) else { return }
        let view = selectedView
        if confirmedRows[rowId] == nil { confirmedRows[rowId] = current }
        let pending = PendingWrite(rowId: rowId, cells: cells, position: position)
        pendingWrites.append(pending)
        place(overlay(rowId: rowId))
        let pageId = pageId
        do {
            let saved = try await enqueue {
                try await self.send(Endpoints.Bases.updateRow(pageId: pageId, rowId: rowId, cells: cells, position: position))
            }
            pendingWrites.removeAll { $0.id == pending.id }
            confirmedRows[rowId] = saved
            if runningLoads > 0 { savedDuringLoad[rowId] = saved }
            if let input, input.replacesKept { await forgetUnsent(rowId: rowId, propertyId: input.propertyId) }
        } catch {
            pendingWrites.removeAll { $0.id == pending.id }
            toast = failureMessage(error, cells: cells)
            if let input {
                unsavedDrafts["\(rowId)/\(input.propertyId)"] = input.text
                // Kept for the server, like a page's title, unless it can never go (entry deleted, value refused).
                if UnsentChanges.isFinal(error) {
                    if input.replacesKept { await forgetUnsent(rowId: rowId, propertyId: input.propertyId) }
                } else if await keepUnsent(rowId: rowId, propertyId: input.propertyId, value: cells[input.propertyId] ?? .null, typed: input.text) {
                    toast = String(localized: "The change goes to the server once it can be reached.")
                }
            }
        }
        // Switched tabs meanwhile: update the row only where the new view shows it, never add it there.
        if let display = overlay(rowId: rowId), selectedView == view || row(id: rowId) != nil { place(display) }
        if !pendingWrites.contains(where: { $0.rowId == rowId }) {
            confirmedRows[rowId] = nil
            await storeSnapshot()
        }
    }

    /// The user's saved and pending changes over a rows answer the server may have given before them; only for rows the
    /// answer shows, so a view switched to meanwhile gets no row it leaves out.
    private func reapplyOwnChanges() {
        func shown(_ id: String) -> Bool {
            table.rows.contains { $0.id == id } || columns.contains { $0.list.rows.contains { $0.id == id } }
        }
        for row in savedDuringLoad.values where shown(row.id) { place(row) }
        for rowId in Set(pendingWrites.map(\.rowId)) where shown(rowId) { place(overlay(rowId: rowId)) }
    }

    /// Failed-save message; on "Cell validation failed" it says which value is invalid, not the server's English text.
    private func failureMessage(_ error: Error, cells: [String: JSONValue]) -> String {
        guard case .validation(let messages)? = error as? APIError, messages.contains("Cell validation failed"),
              cells.count == 1, let property = base?.properties.first(where: { $0.id == cells.keys.first })
        else { return error.userMessage }
        switch property.kind {
        case .url: return String(localized: "Not a valid link")
        case .email: return String(localized: "Not a valid email address")
        default: return String(localized: "Invalid value for “\(property.name)”")
        }
    }

    /// Confirmed state plus all pending changes in input order.
    private func overlay(rowId: String) -> BaseRow? {
        guard var row = confirmedRows[rowId] else { return nil }
        for pending in pendingWrites where pending.rowId == rowId {
            for (key, value) in pending.cells {
                if value.isNull { row.cells.removeValue(forKey: key) } else { row.cells[key] = value }
            }
            if let position = pending.position { row.position = position }
        }
        return row
    }

    /// Applies a row to table and board: in the table it keeps its place; on the board it moves to its grouping value's
    /// column, ordered by position, or into `offBoardRows` if that column isn't shown.
    private func place(_ row: BaseRow?) {
        guard let row, !deletedRowIds.contains(row.id) else { return }
        if let index = table.rows.firstIndex(where: { $0.id == row.id }) {
            table.rows[index] = row
        }
        if offBoardRows[row.id] != nil { offBoardRows[row.id] = row }
        guard let groupBy = groupByProperty else { return }
        let target = BaseLayout.columnId(of: row, groupBy: groupBy)
        for index in columns.indices {
            columns[index].list.rows.removeAll { $0.id == row.id }
        }
        guard let index = columns.firstIndex(where: { $0.id == target }) else {
            offBoardRows[row.id] = row
            return
        }
        offBoardRows[row.id] = nil
        let key = row.position ?? ""
        let rows = columns[index].list.rows
        let insertAt = rows.firstIndex { ($0.position ?? "") > key } ?? rows.endIndex
        columns[index].list.rows.insert(row, at: insertAt)
    }

    /// Appends an operation to the write queue and waits for its result. A write that waited past a switch or sign-out
    /// doesn't go out: each request checks the session the database was opened with (`send`).
    private func enqueue<Output: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Output
    ) async throws -> Output {
        let previous = writeQueue
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        writeQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - Kept for the server

    /// Keeps a field's input for the server (`UnsentCell`; `AppSession.sendUnsentCells` sends it); false if it can't be
    /// kept. In the store of the sign-in the database was opened with, also after a switch: it goes once that is back.
    private func keepUnsent(rowId: String, propertyId: String, value: JSONValue, typed: String) async -> Bool {
        guard let store = owner?.unsentChanges else { return false }
        let cell = UnsentCell(basePageId: pageId, rowId: rowId, propertyId: propertyId, value: value, typed: typed,
                              propertyName: base?.property(id: propertyId)?.name ?? "")
        do {
            try await store.update([String: UnsentCell].self, key: CacheKey.unsentCells, initial: [:]) { $0[cell.key] = cell }
            return true
        } catch {
            AppLog.ui.error("Field not kept: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func forgetUnsent(rowId: String, propertyId: String) async {
        let key = UnsentCell.key(basePageId: pageId, rowId: rowId, propertyId: propertyId)
        try? await owner?.unsentChanges.update([String: UnsentCell].self, key: CacheKey.unsentCells, initial: [:]) { $0[key] = nil }
    }

    /// The inputs kept for this database's fields (`keepUnsent`): their fields show them until they reach the server.
    private func restoreUnsent() async {
        guard let cells = await owner?.unsentChanges.read([String: UnsentCell].self, key: CacheKey.unsentCells) else { return }
        for cell in cells.values where cell.basePageId == pageId {
            unsavedDrafts["\(cell.rowId)/\(cell.propertyId)"] = cell.typed
        }
    }

    // MARK: - Cache

    private func snapshotKey() -> String? {
        selectedView.map { CacheKey.baseView(pageId, viewId: $0.id) }
    }

    private func storeSnapshot() async {
        guard let cache = ownSession?.cache, let key = snapshotKey(), let view = selectedView else { return }
        let snapshot = BaseViewSnapshot(
            table: view.kind == .kanban ? nil : table, columns: view.kind == .kanban ? columns : nil, users: users, pages: pages
        )
        await cache.write(snapshot, key: key)
    }

    private func restoreSnapshot() async {
        guard let cache = ownSession?.cache, let key = snapshotKey(),
              let snapshot = await cache.read(BaseViewSnapshot.self, key: key), key == snapshotKey()
        else { return }
        if let cached = snapshot.table { table = cached }
        if let cached = snapshot.columns { columns = cached }
        table.rows.removeAll { deletedRowIds.contains($0.id) }
        for index in columns.indices { columns[index].list.rows.removeAll { deletedRowIds.contains($0.id) } }
        users.merge(snapshot.users) { current, _ in current }
        pages.merge(snapshot.pages) { current, _ in current }
    }
}
