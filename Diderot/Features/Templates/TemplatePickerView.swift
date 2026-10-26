import SwiftUI
import DocmostKit

/// The templates to start a page with, as the web's "Use a template" (Docmost's Enterprise feature `templates`): the
/// space's own or all of them, filtered by title. A template shows its content before it is used; "Use" on a row skips
/// that, as on the web. Creating and editing templates stays on the web.
struct TemplatePickerView: View {
    /// The space the page starts in: its own templates come first. Without one, all of them.
    let spaceId: String?
    /// Uses the template; the picker closes unless it throws.
    let use: (PageTemplate) async throws -> Void

    @Environment(AppSession.self) private var session
    @Environment(SpacesStore.self) private var spaces
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope
    @State private var state: LoadState<[PageTemplate]> = .idle
    @State private var query = ""
    /// The template being used.
    @State private var using: String?
    @State private var errorMessage: String?

    enum Scope: Hashable {
        case space, all
    }

    init(spaceId: String?, use: @escaping (PageTemplate) async throws -> Void) {
        self.spaceId = spaceId
        self.use = use
        _scope = State(initialValue: spaceId == nil ? .all : .space)
    }

    var body: some View {
        NavigationStack {
            AsyncContentView(state: state, retry: { await load() }) { templates in
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
        guard let client = session.client else { return }
        state = .loading
        let space = scope == .space ? spaceId : nil
        do {
            let templates = try await Paginated.all { cursor in
                try await session.perform { try await client.send(Endpoints.Templates.list(spaceId: space, cursor: cursor)) }
            }
            state = .loaded(templates)
        } catch is CancellationError {
        } catch {
            state = .failed(error)
        }
    }

    private func apply(_ template: PageTemplate) async {
        guard using == nil else { return }
        using = template.id
        errorMessage = nil
        defer { using = nil }
        do {
            try await use(template)
            dismiss()
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
    @State private var state: LoadState<PageTemplate> = .idle
    /// Subpages and databases in the preview don't open behind the picker.
    @State private var previewNavigation = ReaderNavigation()

    var body: some View {
        AsyncContentView(state: state, retry: { await load() }) { full in
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
            if case .external(let external) = ContentLinkRouter.destination(for: url, serverURL: session.server?.url) { outside(external) }
        }
        .opensExternalLinks()
        .navigationTitle(template.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isUsing {
                    ProgressView()
                } else {
                    Button("Use Template") { Task { await use(state.value ?? template) } }
                        .accessibilityIdentifier("template-use")
                }
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        guard let client = session.client else { return }
        state = .loading
        do {
            state = .loaded(try await session.perform { try await client.send(Endpoints.Templates.info(templateId: template.id)) })
        } catch is CancellationError {
        } catch {
            state = .failed(error)
        }
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
    let use: (PageTemplate) async throws -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            TemplatePickerView(spaceId: spaceId, use: use)
        }
    }
}
