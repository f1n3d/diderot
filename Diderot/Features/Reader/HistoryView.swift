import SwiftUI
import DocmostKit

/// Versions of a page; a version opens read-only.
struct HistoryView: View {
    @Environment(AppSession.self) private var session
    @Environment(ReaderNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    let page: Page
    @State private var state: LoadState<[PageHistoryEntry]> = .idle
    /// Subpages, databases and page links in a version open on the page's stack, once the history has closed: pushed
    /// there while it is open, they appeared behind it.
    @State private var versionNavigation = ReaderNavigation()

    var body: some View {
        NavigationStack {
            AsyncContentView(state: state, retry: load) { entries in
                if entries.isEmpty {
                    ContentUnavailableView("No versions yet", systemImage: "clock.arrow.circlepath", description: Text("Versions are captured a few minutes after a page was edited."))
                } else {
                    List(entries) { entry in
                        NavigationLink(value: entry) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let createdAt = entry.createdAt {
                                    Text(createdAt, format: .dateTime.day().month().year().hour().minute())
                                        .font(.body.weight(.medium))
                                }
                                HStack(spacing: 4) {
                                    Text(entry.lastUpdatedBy?.name ?? String(localized: "Unknown"))
                                    if entry.displayTitle != page.displayTitle {
                                        Text("· \(entry.displayTitle)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Page History")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PageHistoryEntry.self) { entry in
                HistoryDetailView(entry: entry)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { if state.value == nil { await load() } }
        }
        // On the stack, not its root: pushed versions don't get values set inside the stack.
        .environment(\.renderContext, RenderContext(session: session, pageId: page.id))
        .environment(\.linkPreviews, session.linkPreviews)
        // As in the presentation mode: a version's comments open nowhere, and its marks showed as links that did nothing.
        .environment(\.showsCommentMarks, false)
        .environment(versionNavigation)
        .onAppear {
            let pageNavigation = navigation
            versionNavigation.redirect = { [dismiss] selection in
                dismiss()
                pageNavigation.open(selection)
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        if state.value == nil { state = .loading }
        do {
            let entries = try await Paginated.all { cursor in
                try await session.perform { try await client.send(Endpoints.History.list(pageId: page.id, cursor: cursor)) }
            }
            state = .loaded(entries)
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }
}

private struct HistoryDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(ReaderNavigation.self) private var navigation
    let entry: PageHistoryEntry
    @State private var state: LoadState<ContentDocument> = .idle
    @State private var anchor: String?

    var body: some View {
        AsyncContentView(state: state, retry: load) { document in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 10) {
                            if let icon = entry.icon, !icon.isEmpty {
                                Text(icon).font(.system(size: 32))
                            }
                            Text(entry.displayTitle).font(.title.bold())
                        }
                        if let createdAt = entry.createdAt {
                            Text("Version from \(createdAt, format: .dateTime.day().month().year().hour().minute()) by \(entry.lastUpdatedBy?.name ?? String(localized: "Unknown"))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        if document.isEmpty {
                            Text("This version is empty.").foregroundStyle(.secondary)
                        } else {
                            ContentDocumentView(document: document)
                        }
                    }
                    .padding()
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: anchor) { _, target in
                    guard let target, let id = document.anchors[target] else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                    anchor = nil
                }
            }
        }
        .navigationTitle("Version")
        .navigationBarTitleDisplayMode(.inline)
        // Links as on a page: pages and database entries open there (the history closes), anchors scroll within the
        // version, the rest leaves the app as from a page.
        .handlesLinks { url, outside in
            switch ContentLinkRouter.destination(for: url, serverURL: session.server?.url) {
            case .page(let slugId, _): navigation.open(PageSelection(pageId: slugId))
            case .databaseEntry(let basePageId, let rowId): navigation.open(PageSelection(pageId: basePageId, rowId: rowId))
            case .comment(let slugId, let commentId): navigation.open(PageSelection(pageId: slugId, commentId: commentId))
            case .anchor(let target): anchor = target
            case .user: break
            case .external(let external): outside(external)
            }
        }
        .opensExternalLinks()
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        guard session.client != nil else { return }
        state = .loading
        do {
            let detail = try await session.send(Endpoints.History.info(historyId: entry.id))
            let content = detail.content
            state = .loaded(await Task.detached { ContentDocument(json: content) }.value)
        } catch is CancellationError {
        } catch {
            state = .failed(error)
        }
    }
}
