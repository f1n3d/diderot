import SwiftUI
import DocmostKit

/// Navigation target for a space's trash.
struct SpaceTrashRoute: Hashable {
    let spaceId: String
}

/// Deleted pages of a space: restore or delete permanently.
struct TrashView: View {
    @Environment(AppSession.self) private var session
    @Environment(ContentChanges.self) private var changes
    let route: SpaceTrashRoute
    @State private var state: LoadState<[Page]> = .idle
    @State private var toast: String?
    @State private var permanentDeleteCandidate: Page?

    var body: some View {
        AsyncContentView(state: state, retry: load) { pages in
            if pages.isEmpty {
                ContentUnavailableView("The trash is empty", systemImage: "trash", description: Text("Pages you move to the trash show up here."))
            } else {
                List(pages) { page in
                    HStack(spacing: 10) {
                        PageIconView(icon: page.icon, size: 22, isBase: page.isBase == true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.displayTitle).lineLimit(2)
                            if let deletedAt = page.deletedAt {
                                Text("Deleted \(deletedAt, format: .relative(presentation: .named))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Restore", systemImage: "arrow.uturn.backward") {
                            Task { await restore(page) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("trash-restore-\(page.id)")
                    }
                    .swipeActions(edge: .trailing) {
                        // Red tint, not the destructive role: that role slides the row out, and with it the
                        // confirmation attached to the row.
                        Button("Delete Permanently", systemImage: "trash.slash") {
                            permanentDeleteCandidate = page
                        }
                        .tint(.red)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Restore", systemImage: "arrow.uturn.backward") {
                            Task { await restore(page) }
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore(page) } }
                        Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) { permanentDeleteCandidate = page }
                    }
                    // On the row, not the list: iOS shows the confirmation as a popover from the view it's attached to.
                    .confirmationDialog(
                        "Delete this page permanently?",
                        isPresented: Binding(get: { permanentDeleteCandidate?.id == page.id }, set: { if !$0 { permanentDeleteCandidate = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("Delete Permanently", role: .destructive) { Task { await deletePermanently(page) } }
                    } message: {
                        Text("This cannot be undone.")
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Trash")
        .toolbarTitleDisplayMode(.inline)
        .toast($toast)
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        guard let client = session.client else { return }
        if state.value == nil { state = .loading }
        do {
            let pages = try await Paginated.all { cursor in
                try await session.perform { try await client.send(Endpoints.Pages.trash(spaceId: route.spaceId, cursor: cursor)) }
            }
            state = .loaded(pages)
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) } else { toast = error.userMessage }
        }
    }

    private func restore(_ page: Page) async {
        guard session.client != nil else { return }
        do {
            _ = try await session.send(Endpoints.Pages.restore(pageId: page.id))
            changes.pageChanged(in: route.spaceId)
            toast = String(localized: "Page restored")
            await load()
        } catch {
            toast = error.userMessage
        }
    }

    private func deletePermanently(_ page: Page) async {
        guard session.client != nil else { return }
        do {
            _ = try await session.send(Endpoints.Pages.delete(pageId: page.id, permanently: true))
            toast = String(localized: "Page deleted")
            await load()
        } catch {
            toast = error.userMessage
        }
    }
}
