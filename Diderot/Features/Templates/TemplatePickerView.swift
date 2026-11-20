import SwiftUI
import DocmostKit

/// The templates to start a page with, as the web's "Use a template" (Docmost's Enterprise feature `templates`): the
/// space's own or all of them, filtered by title. A template shows its content before it is used; "Use" on a row skips
/// that, as on the web. On Docmost 0.98 a template with fields asks for their values first (`TemplateFieldsView`).
/// Creating and editing templates stays on the web.
struct TemplatePickerView: View {
    /// Uses a template (with its content on 0.98), with the values of its fields by variable id if it has any; the
    /// picker closes unless it throws.
    typealias Use = (PageTemplate, [String: String]?) async throws -> Void

    /// The space the page starts in: its own templates come first. Without one, all of them.
    let spaceId: String?
    /// What the fields' form confirms with ("Create Page", "Use Template").
    let action: LocalizedStringKey
    let use: Use

    @Environment(AppSession.self) private var session
    @Environment(SpacesStore.self) private var spaces
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope
    @State private var templates = RemoteValue<[PageTemplate]>()
    @State private var query = ""
    /// The template being used.
    @State private var using: String?
    @State private var errorMessage: String?
    /// A template whose fields are being filled in.
    @State private var asking: TemplateFields?

    enum Scope: Hashable {
        case space, all
    }

    init(spaceId: String?, action: LocalizedStringKey, use: @escaping Use) {
        self.spaceId = spaceId
        self.action = action
        self.use = use
        _scope = State(initialValue: spaceId == nil ? .all : .space)
    }

    var body: some View {
        NavigationStack {
            AsyncContentView(state: templates.state, retry: { await load() }) { templates in
                let shown = filtered(templates)
                if shown.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No templates found", systemImage: "doc.on.doc")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    List(shown) { template in
                        HStack(spacing: 12) {
                            NavigationLink(value: template) {
                                TemplateRow(template: template, place: place(of: template))
                            }
                            Button("Use") { Task { await apply(template) } }
                                .buttonStyle(.bordered)
                                .disabled(using != nil)
                                .accessibilityIdentifier("template-use-\(template.displayTitle)")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if spaceId != nil {
                    Picker("Templates", selection: $scope) {
                        Text("This Space").tag(Scope.space)
                        Text("All Templates").tag(Scope.all)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .searchable(text: $query, prompt: "Search templates")
            .navigationTitle("Use a Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: PageTemplate.self) { template in
                TemplatePreviewView(template: template, isUsing: using == template.id) { await apply($0) }
            }
            .task(id: scope) { await load() }
            .sheet(item: $asking) { fields in
                TemplateFieldsView(fields: fields, action: action) { values in
                    try await use(fields.template, values)
                    asking = nil
                    dismiss()
                }
            }
            // As in the comments: a template that couldn't be used says why below the list.
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
        }
    }

    /// The templates whose title contains the query, as the web filters them.
    private func filtered(_ templates: [PageTemplate]) -> [PageTemplate] {
        let term = query.trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? templates : templates.filter { $0.displayTitle.localizedStandardContains(term) }
    }

    /// The space a template belongs to, or "Global".
    private func place(of template: PageTemplate) -> String {
        guard let id = template.spaceId else { return String(localized: "Global") }
        return spaces.state.value?.first { $0.id == id }?.name ?? String(localized: "Space")
    }

    private func load() async {
        guard let ready = session.ready else { return }
        let space = scope == .space ? spaceId : nil
        // Each scope is a list of its own: the other's goes. Back from a template's preview the task starts again, and
        // the list refreshes where it is (code review V38: it started over with a spinner, at the top).
        await templates.load(for: scope) {
            try await Paginated.all { cursor in
                try await session.load(Endpoints.Templates.list(spaceId: space, cursor: cursor), of: ready)
            }
        }
    }

    private func apply(_ template: PageTemplate) async {
        guard using == nil else { return }
        using = template.id
        errorMessage = nil
        defer { using = nil }
        do {
            // Docmost 0.98: a template with fields needs their values, from the content as it is now (the web reads the
            // template again, too). Older servers have no fields.
            guard session.ready?.hasDocmost098Features == true else {
                try await use(template, nil)
                dismiss()
                return
            }
            let full = try await session.send(Endpoints.Templates.info(templateId: template.id))
            let variables: [TemplateVariable]
            do {
                variables = try TemplateVariable.fields(in: full.content)
            } catch {
                errorMessage = String(localized: "Failed to load template")
                return
            }
            if variables.isEmpty {
                try await use(full, nil)
                dismiss()
            } else {
                asking = TemplateFields(template: full, variables: variables)
            }
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct TemplateRow: View {
    let template: PageTemplate
    let place: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = template.icon, !icon.isEmpty {
                    Text(icon)
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayTitle)
                    .lineLimit(2)
                if let description = template.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(place)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A template's content, read-only, before it is used.
private struct TemplatePreviewView: View {
    let template: PageTemplate
    let isUsing: Bool
    let use: (PageTemplate) async -> Void

    @Environment(AppSession.self) private var session
    @State private var full = RemoteValue<PageTemplate>()
    /// Subpages and databases in the preview don't open behind the picker.
    @State private var previewNavigation = ReaderNavigation()

    var body: some View {
        AsyncContentView(state: full.state, retry: { await load() }) { full in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        if let icon = full.icon, !icon.isEmpty {
                            Text(icon).font(.system(size: 32))
                        }
                        Text(full.displayTitle).font(.title.bold())
                    }
                    if let description = full.description, !description.isEmpty {
                        Text(description).foregroundStyle(.secondary)
                    }
                    Divider()
                    ContentDocumentView(document: ContentDocument(json: full.content))
                }
                .padding()
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .environment(\.renderContext, RenderContext(session: session, pageId: nil))
        .environment(\.linkPreviews, session.linkPreviews)
        .environment(previewNavigation)
        // Only web links open (in the app's browser); pages and anchors belong to wherever the template is used.
        .handlesLinks { url, outside in
            if case .outside(let external) = LinkTarget.of(url, serverURL: session.server?.url) { outside(external) }
        }
        .navigationTitle(template.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isUsing {
                    ProgressView()
                } else {
                    Button("Use Template") { Task { await use(full.value ?? template) } }
                        .accessibilityIdentifier("template-use")
                }
            }
        }
        .task { if full.value == nil { await load() } }
    }

    private func load() async {
        guard let ready = session.ready else { return }
        await full.load { try await session.load(Endpoints.Templates.info(templateId: template.id), of: ready) }
    }
}

enum TemplateError: LocalizedError {
    /// Someone typed into the page while the template was chosen.
    case pageNotEmpty

    var errorDescription: String? {
        String(localized: "This page is no longer empty")
    }
}

/// Presents `TemplatePickerView` (a modifier of its own: the page's view chains are at the type checker's limit).
struct TemplatePickerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let spaceId: String?
    let use: TemplatePickerView.Use

    func body(content: Content) -> some View {
        content.linkSheet(isPresented: $isPresented) {
            TemplatePickerView(spaceId: spaceId, action: "Use Template", use: use)
        }
    }
}

/// A template and the fields it asks for (Docmost 0.98).
struct TemplateFields: Identifiable {
    let template: PageTemplate
    let variables: [TemplateVariable]
    var id: String { template.id }
}

/// The values of a template's fields before a page is made from it, as the web's form asks for them: a line, several
/// lines or one of the choices each, empty where left out. They become text on the page.
struct TemplateFieldsView: View {
    let fields: TemplateFields
    let action: LocalizedStringKey
    let submit: ([String: String]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(fields.variables) { variable in
                    Section(variable.name) {
                        field(variable)
                    }
                }
                Section {
                    Text("These values become editable text on the page.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(fields.template.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(action) { Task { await send() } }
                            .accessibilityIdentifier("template-fields-use")
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy || values.values.contains { !$0.isEmpty })
    }

    @ViewBuilder
    private func field(_ variable: TemplateVariable) -> some View {
        let value = Binding { values[variable.id] ?? "" } set: { values[variable.id] = $0 }
        switch variable.fieldType {
        case .text:
            TextField(variable.name, text: value)
                .accessibilityIdentifier("template-field-\(variable.name)")
        case .multiline:
            TextField(variable.name, text: value, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("template-field-\(variable.name)")
        case .select:
            Picker(variable.name, selection: value) {
                Text("Select an Option").tag("")
                ForEach(variable.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .accessibilityIdentifier("template-field-\(variable.name)")
        }
    }

    private func send() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        // Every field, empty where left out, as the web sends them.
        let filled = Dictionary(uniqueKeysWithValues: fields.variables.map { ($0.id, values[$0.id] ?? "") })
        do {
            try await submit(filled)
        } catch {
            errorMessage = error.userMessage
        }
    }
}
