import SwiftUI
import UIKit
import DocmostKit

/// Page reference for actions from lists (tree, recent, search).
extension PageRef {
    init(_ page: SidebarPage) {
        self.init(id: page.id, slugId: page.slugId, title: page.title, icon: page.icon, spaceId: page.spaceId)
    }

    init(_ page: Page) {
        self.init(id: page.id, slugId: page.slugId, title: page.title, icon: page.icon, spaceId: page.spaceId)
    }
}

/// Runs page actions and holds their dialogs (export, space picker, trash, toast).
@MainActor
@Observable
final class PageActionRunner {
    enum Pending: Identifiable {
        case export(PageRef)
        case moveToSpace(PageRef)
        case copyToSpace(PageRef)

        var id: String {
            switch self {
            case .export(let page): "export-\(page.id)"
            case .moveToSpace(let page): "move-\(page.id)"
            case .copyToSpace(let page): "copy-\(page.id)"
            }
        }
    }

    var pending: Pending?
    var trashCandidate: PageRef?
    var shareFile: URL?
    var toast: String?
    private let session: AppSession
    private let changes: ContentChanges

    init(session: AppSession, changes: ContentChanges) {
        self.session = session
        self.changes = changes
    }

    func copyLink(_ page: PageRef) {
        guard let server = session.server?.url, let slugId = page.slugId else { return }
        UIPasteboard.general.url = ContentLinkRouter.webPageURL(server: server, slugId: slugId)
        toast = String(localized: "Link copied")
    }

    /// The pages being duplicated or copied to another space, one request at a time each: the server answers once it has
    /// copied the whole tree, which can take minutes, and every request makes a copy.
    private var copying: Set<String> = []

    /// While true, the menu turns Duplicate and Copy to Space off for the page.
    func isCopying(_ page: PageRef) -> Bool { copying.contains(page.id) }

    func duplicate(_ page: PageRef, toSpaceId: String? = nil) async {
        guard copying.insert(page.id).inserted else { return }
        defer { copying.remove(page.id) }
        await run {
            // Nothing else shows that it started until the server answers.
            self.toast = toSpaceId == nil ? String(localized: "Duplicating page…") : String(localized: "Copying page…")
            let done: String
            do {
                _ = try await $0.send(Endpoints.Pages.duplicate(pageId: page.id, spaceId: toSpaceId))
                done = toSpaceId == nil ? String(localized: "Page duplicated") : String(localized: "Page copied")
            } catch let error as APIError where error.serverMayStillBeWorking {
                // The server makes the new pages first and answers once it has copied their attachments; it goes on
                // after the app, or a gateway in front of it, stops waiting. The tree shows the copy, and the toast
                // doesn't invite a second one.
                done = String(localized: "The server is still making the copy. It may take a while to appear.")
            }
            self.changes.pageChanged(in: toSpaceId ?? page.spaceId)
            self.toast = done
        }
    }

    func moveToSpace(_ page: PageRef, spaceId: String) async {
        await run {
            _ = try await $0.send(Endpoints.Pages.moveToSpace(pageId: page.id, spaceId: spaceId))
            self.changes.pageChanged(in: nil)
            self.toast = String(localized: "Page moved")
        }
    }

    func export(_ page: PageRef, format: Endpoints.Pages.ExportFormat, includeChildren: Bool, includeAttachments: Bool) async {
        guard let server = session.server?.url else { return }
        await run { client in
            // Into a file as it arrives: an export with subpages and attachments can be large.
            let (file, response) = try await client.download(
                Endpoints.Pages.export(pageId: page.id, format: format, includeChildren: includeChildren, includeAttachments: includeAttachments)
            )
            // The sheet was closed as the last byte came: nobody waits for the share sheet any more.
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: file)
                throw CancellationError()
            }
            let fallback = "\(page.displayTitle).\(includeChildren || includeAttachments ? "zip" : format.fileExtension)"
            let name = ContentDisposition.filename(from: response) ?? fallback
            self.shareFile = try TempFile.take(file, server: server, folder: ["exports"], name: name)
        }
    }

    func trash(_ page: PageRef) async {
        await run {
            _ = try await $0.send(Endpoints.Pages.delete(pageId: page.id))
            self.changes.pageChanged(in: page.spaceId)
            self.toast = String(localized: "Moved to Trash")
        }
    }

    private func run(_ operation: @MainActor (APIClient) async throws -> Void) async {
        guard let ready = session.ready else { return }
        do {
            try await session.perform(on: ready) { try await operation($0) }
        } catch is CancellationError {
            // Its sheet was closed (an export the user stopped): there is nothing to say.
        } catch {
            toast = error.userMessage
        }
    }
}

/// Menu items for a page (use inside `Menu { }` or `contextMenu { }`, with `trashConfirmation` on the menu's view).
struct PageActionsMenu: View {
    @Environment(FavoritesStore.self) private var favorites
    let page: PageRef
    let runner: PageActionRunner
    let canEdit: Bool
    /// Why exports are turned off here (`ExportPolicy`): "Export…" stays in the menu, turned off, with the reason below,
    /// as the web's stays with it as a tooltip.
    var exportOffReason: String?

    var body: some View {
        Button("Copy Link", systemImage: "link") { runner.copyLink(page) }
        let isFavorite = favorites.isFavorite(pageId: page.id)
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star") {
            Task { await favorites.togglePage(page.id) }
        }
        Button {
            runner.pending = .export(page)
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
            if let exportOffReason { Text(exportOffReason) }
        }
        .disabled(exportOffReason != nil)
        if canEdit {
            Divider()
            Button("Duplicate", systemImage: "doc.on.doc") { Task { await runner.duplicate(page) } }
                .disabled(runner.isCopying(page))
            Button("Move to Space…", systemImage: "folder") { runner.pending = .moveToSpace(page) }
            Button("Copy to Space…", systemImage: "folder.badge.plus") { runner.pending = .copyToSpace(page) }
                .disabled(runner.isCopying(page))
            Button("Move to Trash", systemImage: "trash", role: .destructive) { runner.trashCandidate = page }
        }
    }
}

/// Attaches the runner's sheets and toast to a view.
struct PageActionSheets: ViewModifier {
    @Bindable var runner: PageActionRunner

    func body(content: Content) -> some View {
        content
            .linkSheet(item: $runner.pending) { pending in
                switch pending {
                case .export(let page):
                    ExportOptionsSheet(page: page, runner: runner)
                case .moveToSpace(let page):
                    SpacePickerSheet(title: "Move to Space", excludedSpaceId: page.spaceId) { space in
                        Task { await runner.moveToSpace(page, spaceId: space.id) }
                    }
                case .copyToSpace(let page):
                    SpacePickerSheet(title: "Copy to Space", excludedSpaceId: nil) { space in
                        Task { await runner.duplicate(page, toSpaceId: space.id) }
                    }
                }
            }
            .linkSheet(item: $runner.shareFile) { url in
                ShareSheet(items: [url])
            }
            .toast($runner.toast)
    }
}

extension View {
    func pageActionSheets(_ runner: PageActionRunner) -> some View {
        modifier(PageActionSheets(runner: runner))
    }

    /// The trash confirmation for `page`, anchored at this view: iOS shows it as a popover from there.
    func trashConfirmation(for page: PageRef, runner: PageActionRunner) -> some View {
        confirmationDialog(
            "Move this page and its subpages to the trash?",
            isPresented: Binding(get: { runner.trashCandidate?.id == page.id }, set: { if !$0 { runner.trashCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await runner.trash(page) } }
        }
    }
}

/// Asks for export format and scope, then shares the file.
struct ExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let page: PageRef
    let runner: PageActionRunner
    @State private var format: Endpoints.Pages.ExportFormat = .markdown
    @State private var includeChildren = false
    @State private var includeAttachments = false
    /// The running export. Closing the sheet stops it: one with subpages and attachments can take minutes, and it ran
    /// on after Cancel, then opened a share sheet nobody waited for.
    @State private var exporting: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        Text("Markdown").tag(Endpoints.Pages.ExportFormat.markdown)
                        Text("HTML").tag(Endpoints.Pages.ExportFormat.html)
                    }
                    Toggle("Include subpages", isOn: $includeChildren)
                    Toggle("Include attachments", isOn: $includeAttachments)
                } header: {
                    Text(page.displayTitle)
                } footer: {
                    Text("Subpages and attachments are exported as a ZIP archive.")
                }
            }
            .navigationTitle("Export")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Before the sheet goes: a file that arrives while it closes must not open the share sheet.
                        exporting?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if exporting != nil {
                        ProgressView()
                    } else {
                        Button("Export") {
                            exporting = Task {
                                await runner.export(page, format: format, includeChildren: includeChildren, includeAttachments: includeAttachments)
                                // A stopped export's sheet is closing already.
                                if !Task.isCancelled { dismiss() }
                            }
                        }
                    }
                }
            }
        }
        // While it exports, only Cancel closes the sheet: stopping a long export takes a tap, not a stray swipe.
        .interactiveDismissDisabled(exporting != nil)
        // Any other close (the space view leaving) stops it too.
        .onDisappear { exporting?.cancel() }
    }
}

/// Lets the user choose the target space.
struct SpacePickerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(SpacesStore.self) private var spaces
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let excludedSpaceId: String?
    let onPick: (Space) -> Void

    var body: some View {
        NavigationStack {
            AsyncContentView(state: spaces.state, retry: spaces.load) { spaces in
                let candidates = Self.candidates(in: spaces, excluding: excludedSpaceId)
                List(candidates) { space in
                    Button {
                        onPick(space)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            SpaceLogoView(space: space, baseURL: session.server?.url)
                            Text(space.name)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .overlay {
                    if candidates.isEmpty {
                        ContentUnavailableView("No other space", systemImage: "folder", description: Text("You can't edit pages in any other space."))
                    }
                }
            }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            // Full load on every open for current spaces and memberships.
            .task { await spaces.load() }
        }
    }

    /// The spaces whose pages the user may edit, but not `excludedSpaceId` and, as on the web (its space select lists
    /// the active ones), no archived one.
    static func candidates(in spaces: [Space], excluding excludedSpaceId: String?) -> [Space] {
        spaces.filter { $0.id != excludedSpaceId && !$0.isArchived && ($0.membership?.canEditPages ?? true) }
    }
}
