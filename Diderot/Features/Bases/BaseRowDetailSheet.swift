import SwiftUI
import DocmostKit

/// Field picker pushed onto the detail sheet's navigation stack.
enum BaseFieldPicker: Hashable {
    case choices(String)
    case people(String)
    case page(String)
}

/// Row detail sheet like Airtable and Notion: title, then each field with its name above the value. With permission
/// and license, fields edit in place and save at once; select, people and page fields open a searchable list.
struct BaseRowDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ReaderNavigation.self) private var navigation
    @Environment(AppSession.self) private var session
    let model: BaseModel
    let route: BaseRowRoute
    @State private var path: [BaseFieldPicker] = []
    @State private var highlighted: String?
    @State private var confirmsDelete = false
    /// One-shot actions on open: scroll to a field or focus the title. The list reappears after each picker, and its
    /// rows while scrolling; without these flags, scroll position and cursor would jump back each time.
    @State private var pendingJump: String?
    @State private var pendingTitleFocus: Bool
    /// The entry shown; the arrows move it through the view's entries.
    @State private var rowId: String

    init(model: BaseModel, route: BaseRowRoute) {
        self.model = model
        self.route = route
        _pendingJump = State(initialValue: route.fieldId)
        _pendingTitleFocus = State(initialValue: route.focusTitle)
        _rowId = State(initialValue: route.rowId)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let base = model.base, let row = model.row(id: rowId) {
                    // Per entry: the previous one's fields save their input as they disappear.
                    content(base: base, row: row).id(rowId)
                } else {
                    ContentUnavailableView("Entry not found", systemImage: "tablecells", description: Text("This entry no longer exists."))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("base-detail-done")
                }
            }
            .navigationDestination(for: BaseFieldPicker.self) { picker in
                switch picker {
                case .choices(let propertyId):
                    BaseChoicePicker(model: model, rowId: rowId, propertyId: propertyId)
                case .people(let propertyId):
                    BasePersonPicker(model: model, rowId: rowId, propertyId: propertyId)
                case .page(let propertyId):
                    BasePagePicker(model: model, rowId: rowId, propertyId: propertyId)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .toast(Binding { model.toast } set: { model.toast = $0 })
        .opensExternalLinks()
        .accessibilityIdentifier("base-row-detail")
    }

    private func show(_ id: String) {
        path = []
        pendingJump = nil
        pendingTitleFocus = false
        highlighted = nil
        rowId = id
    }

    private func content(base: Base, row: BaseRow) -> some View {
        let editable = model.canEdit
        return ScrollViewReader { proxy in
            List {
                Section {
                    BaseTitleField(model: model, base: base, row: row, editable: editable, autoFocus: $pendingTitleFocus)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
                    if let reason = model.readOnlyReason {
                        readOnlyNote(reason)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                    }
                }
                Section {
                    ForEach(fields(of: base)) { property in
                        BaseFieldRow(model: model, row: row, property: property, editable: editable) { picker in
                            path.append(picker)
                        } onOpenPage: { page in
                            dismiss()
                            navigation.open(PageSelection(pageId: page.id, title: page.title))
                        }
                        .id(property.id)
                        .listRowBackground(highlighted == property.id ? Color.accentColor.opacity(0.14) : nil)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                // Scroll once to the field tapped in the table and briefly highlight it.
                guard let fieldId = pendingJump else { return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                pendingJump = nil
                withAnimation {
                    proxy.scrollTo(fieldId, anchor: .top)
                    highlighted = fieldId
                }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.6)) { highlighted = nil }
            }
        }
        .navigationTitle(BaseLayout.title(of: row, in: base))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                menu(base: base, row: row, editable: editable)
            }
            // Previous and next entry of the view, as the web's arrows in the entry's header.
            ToolbarItemGroup(placement: .topBarTrailing) {
                let ids = model.orderedRowIds
                let index = ids.firstIndex(of: row.id)
                Button("Previous Entry", systemImage: "chevron.up") { if let index { show(ids[index - 1]) } }
                    .disabled((index ?? 0) == 0)
                    .accessibilityIdentifier("base-detail-previous")
                Button("Next Entry", systemImage: "chevron.down") { if let index { show(ids[index + 1]) } }
                    .disabled(index.map { $0 + 1 >= ids.count } ?? true)
                    .accessibilityIdentifier("base-detail-next")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .accessibilityIdentifier("base-keyboard-done")
            }
        }
        .overlay {
            if model.isUploading {
                ProgressView("Uploading…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func menu(base: Base, row: BaseRow, editable: Bool) -> some View {
        Menu {
            if let url = rowURL(base: base, row: row) {
                Button("Copy Link", systemImage: "link") {
                    UIPasteboard.general.url = url
                    model.toast = String(localized: "Link copied")
                }
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
            }
            if editable {
                Divider()
                Button("Delete Entry", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("base-row-menu")
        .deleteEntryConfirmation(isPresented: $confirmsDelete) {
            let rowId = row.id
            dismiss()
            Task { await model.deleteRow(rowId) }
        }
    }

    private func readOnlyNote(_ reason: BaseModel.ReadOnlyReason) -> some View {
        Label {
            switch reason {
            case .license:
                Text("Read only. Editing databases requires a Docmost Business license on this server.")
            case .permission:
                Text("Read only. You don't have permission to edit this database.")
            case .offline:
                Text("Read only while offline.")
            }
        } icon: {
            Image(systemName: "lock")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("base-read-only")
    }

    /// Same link as the web client: the database's page with `?row=…&rowBase=…`.
    private func rowURL(base: Base, row: BaseRow) -> URL? {
        guard let server = session.server?.url, let slug = base.slugId else { return nil }
        return ContentLinkRouter.webPageURL(server: server, slugId: slug).appending(queryItems: [
            URLQueryItem(name: "row", value: row.id), URLQueryItem(name: "rowBase", value: base.id),
        ])
    }

    /// All fields except the title, in database order (like the web client's detail view).
    private func fields(of base: Base) -> [BaseProperty] {
        base.properties
            .filter { $0.isPrimary != true }
            .sorted { ($0.position ?? "") < ($1.position ?? "") }
    }
}

/// Row title (primary property).
private struct BaseTitleField: View {
    let model: BaseModel
    let base: Base
    let row: BaseRow
    let editable: Bool
    /// New row: focus the title once, then reset.
    @Binding var autoFocus: Bool
    @State private var draft = BaseDraft()
    @FocusState private var focused: Bool

    private var stored: String {
        base.primaryProperty.flatMap { row.cells[$0.id]?.stringValue } ?? ""
    }

    var body: some View {
        if editable, let primary = base.primaryProperty {
            TextField("Untitled", text: $draft.text, axis: .vertical)
                .font(.title2.bold())
                .focused($focused)
                .submitLabel(.done)
                .onChange(of: draft.text) { _, text in
                    // Titles are single-line: Return ends the input instead of adding a line break.
                    if text.contains("\n") {
                        draft.text = text.replacingOccurrences(of: "\n", with: "")
                        focused = false
                    }
                }
                .baseDraft($draft, focused: focused, stored: stored, model: model, rowId: row.id, propertyId: primary.id) {
                    .value(BaseValue.text($0))
                }
                .task {
                    guard autoFocus else { return }
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, autoFocus else { return }
                    autoFocus = false
                    focused = true
                }
                .accessibilityIdentifier("base-row-title")
        } else {
            Text(stored.isEmpty ? PageTitle.untitled : stored)
                .font(.title2.bold())
                .foregroundStyle(stored.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .accessibilityIdentifier("base-row-title")
        }
    }
}
