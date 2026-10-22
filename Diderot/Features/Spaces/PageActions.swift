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

    func duplicate(_ page: PageRef, toSpaceId: String? = nil) async {
        await run {
            _ = try await $0.send(Endpoints.Pages.duplicate(pageId: page.id, spaceId: toSpaceId))
            self.changes.pageChanged(in: toSpaceId ?? page.spaceId)
            self.toast = toSpaceId == nil ? String(localized: "Page duplicated") : String(localized: "Page copied")
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
        await run { client in
            let (data, response) = try await client.sendRaw(
                Endpoints.Pages.export(pageId: page.id, format: format, includeChildren: includeChildren, includeAttachments: includeAttachments)
            )
            let fallback = "\(page.displayTitle).\(includeChildren || includeAttachments ? "zip" : format.fileExtension)"
            let name = ContentDisposition.filename(from: response) ?? fallback
            self.shareFile = try TempFile.write(data, folder: ["exports"], name: name)
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
        guard let client = session.client else { return }
        do {
            try await session.perform { try await operation(client) }
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

    var body: some View {
        Button("Copy Link", systemImage: "link") { runner.copyLink(page) }
        let isFavorite = favorites.isFavorite(pageId: page.id)
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star") {
            Task { await favorites.togglePage(page.id) }
        }
        Button("Export…", systemImage: "square.and.arrow.up") { runner.pending = .export(page) }
        if canEdit {
            Divider()
            Button("Duplicate", systemImage: "doc.on.doc") { Task { await runner.duplicate(page) } }
            Button("Move to Space…", systemImage: "folder") { runner.pending = .moveToSpace(page) }
            Button("Copy to Space…", systemImage: "folder.badge.plus") { runner.pending = .copyToSpace(page) }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { runner.trashCandidate = page }
        }
    }
}

/// Attaches the runner's sheets and toast to a view.
struct PageActionSheets: ViewModifier {
    @Bindable var runner: PageActionRunner

    func body(content: Content) -> some View {
        content
            .sheet(item: $runner.pending) { pending in
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
            .sheet(item: $runner.shareFile) { url in
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
    @State private var isExporting = false

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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Export") {
                            Task {
                                isExporting = true
                                await runner.export(page, format: format, includeChildren: includeChildren, includeAttachments: includeAttachments)
                                isExporting = false
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
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
                let candidates = spaces.filter { $0.id != excludedSpaceId && ($0.membership?.canEditPages ?? true) }
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
}
