import SwiftUI
import DocmostKit

/// Opened row: the tapped field (the detail sheet jumps to it) or the title, which gets the cursor.
struct BaseRowRoute: Identifiable, Hashable {
    let rowId: String
    var fieldId: String?
    var focusTitle = false

    var id: String { rowId }
}

/// Database (base) page. In the table the header scrolls away so users move freely; kanban columns scroll on their own,
/// so there the header stays, shrunk to the view tabs in landscape. Rows are edited in a sheet with all fields.
struct BaseScreen<Header: View>: View {
    @Environment(AppSession.self) private var session
    @Environment(OfflineMonitor.self) private var offline
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let page: Page
    /// Entry from a link, opened once the database has loaded.
    var linkedRowId: String?
    @ViewBuilder let header: () -> Header
    @State private var model: BaseModel?
    @State private var openRow: BaseRowRoute?
    @State private var openedLinkedRow = false
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            if let model, case .loaded(let base) = model.state, let view = model.selectedView {
                switch view.kind {
                case .kanban:
                    VStack(spacing: 0) {
                        topArea(model, showsHeader: verticalSizeClass != .compact)
                        Divider()
                        BaseKanbanView(model: model, base: base, view: view) { openRow = $0 }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .table:
                    BaseTableView(model: model, base: base, view: view) {
                        topArea(model, showsHeader: true)
                    } onOpen: { openRow = $0 }
                }
            } else {
                VStack(spacing: 0) {
                    topArea(model, showsHeader: true)
                    Divider()
                    status
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: page.id) {
            let model = model ?? BaseModel(pageId: page.id, session: session)
            model.isOffline = offline.isOffline
            self.model = model
            await model.load()
            if let linkedRowId, !openedLinkedRow, await model.fetchRowIfNeeded(linkedRowId) {
                openedLinkedRow = true
                openRow = BaseRowRoute(rowId: linkedRowId)
            }
            #if DEBUG
            if let name = DebugLaunch.baseView, let view = model.views.first(where: { $0.name == name || $0.type == name }) {
                await model.select(view)
            }
            #endif
        }
        .onChange(of: offline.isOffline) { _, isOffline in model?.isOffline = isOffline }
        .sheet(item: $openRow) { route in
            if let model {
                BaseRowDetailSheet(model: model, route: route)
            }
        }
        .toolbar {
            if let model, model.canEdit, let view = model.selectedView,
               view.kind != .kanban || model.groupByProperty != nil
            {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Entry", systemImage: "plus") {
                        Task { await create(in: model) }
                    }
                    .disabled(isCreating)
                    .accessibilityIdentifier("base-new-entry")
                }
            }
        }
        .toast(Binding { model?.toast } set: { model?.toast = $0 })
    }

    /// "+" adds a row at the table's end or atop the board's first column, then opens it with the cursor in the title.
    private func create(in model: BaseModel) async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        if let row = await model.createRow(atTop: true) {
            openRow = BaseRowRoute(rowId: row.id, focusTitle: true)
        }
    }

    private func topArea(_ model: BaseModel?, showsHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                header()
            }
            if let model, model.views.count > 1 {
                viewTabs(model)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Always full height: space above the kanban board is limited, and the horizontal scroll views (breadcrumbs,
        // tabs) otherwise take height from the title, whose text field then shows only its lower half.
        .fixedSize(horizontal: false, vertical: true)
        // Identifier on the header, not the outer container: in the table that container has only one child, and
        // SwiftUI would merge the two, losing "base-table".
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("base-screen")
    }

    /// Loading, error, or no views.
    @ViewBuilder
    private var status: some View {
        switch model?.state {
        case .failed(let error):
            ErrorStateView(error: error) { await model?.load() }
        case .loaded:
            ContentUnavailableView("No views", systemImage: "tablecells", description: Text("This database has no views yet."))
        default:
            ProgressView()
        }
    }

    private func viewTabs(_ model: BaseModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.views) { view in
                    let selected = view.id == model.selectedView?.id
                    Button {
                        Task { await model.select(view) }
                    } label: {
                        Label(view.name, systemImage: view.kind == .kanban ? "rectangle.split.3x1" : "tablecells")
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                            .background(selected ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("base-view-\(view.id)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

extension View {
    /// "Delete entry?" on the card, row or menu that asks: iOS shows it as a popover from the view it's attached to.
    func deleteEntryConfirmation(isPresented: Binding<Bool>, delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete entry?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete Entry", role: .destructive, action: delete)
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// Database (base) embedded in a page: card with title and views; tapping opens the database page.
struct BaseEmbedCard: View {
    let pageId: String?
    @Environment(\.renderContext) private var context
    @Environment(ReaderNavigation.self) private var navigation
    @State private var state: LoadState<Base> = .idle

    var body: some View {
        Button {
            guard let pageId else { return }
            navigation.open(PageSelection(pageId: pageId, title: state.value?.title))
        } label: {
            HStack(spacing: 12) {
                PageIconView(icon: state.value?.icon, size: 22, isBase: true)
                    .padding(6)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.value?.displayTitle ?? String(localized: "Database"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pageId == nil)
        .accessibilityIdentifier("base-embed-\(pageId ?? "")")
        .task(id: pageId) { await load() }
    }

    private var detail: String {
        switch state {
        case .failed(let error):
            return error.userMessage
        case .loaded(let base) where !base.views.isEmpty:
            return String(localized: "Database · \(base.views.map(\.name).joined(separator: ", "))")
        default:
            return String(localized: "Database")
        }
    }

    private func load() async {
        guard let client = context.client, let pageId else { return }
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await client.send(Endpoints.Bases.info(pageId: pageId)))
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }
}
