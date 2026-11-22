import SwiftUI

/// Starts a download that a tap asks for to open a file (an attachment, a database file), kept by the view around
/// (`View.keepsDownloads`).
struct StartDownloadAction {
    fileprivate let downloads: KeptDownloads

    /// Starts `download` of the file `id` names, unless one of it runs already: a second one replaced the file under
    /// the first one's preview.
    func callAsFunction(_ id: String, _ download: @escaping () async -> Void) { downloads.start(id, download) }

    /// Whether the file `id` names loads. The view that started it may be gone, made anew in its place, and the new
    /// one shows it too.
    func isRunning(_ id: String) -> Bool { downloads.isRunning(id) }
}

extension EnvironmentValues {
    /// Nil where no view around keeps the downloads: one runs to its end then.
    @Entry var startDownload: StartDownloadAction?
}

extension View {
    /// Keeps the downloads that taps inside start to open a file (`startDownload`) and stops them when this view goes,
    /// as a sheet closes or the page is left: they ran on to their end, of any size, for a view that was gone. Not the
    /// view that was tapped: a list's row goes as it scrolls away or a picker opens over it, and a block of the page
    /// when a collaborator adds one above (`blockPresentations`). Quick Look or a full-screen cover over this view
    /// doesn't stop them: SwiftUI calls no `onDisappear` for it, in a window or a sheet (tried on November 22, 2026).
    func keepsDownloads() -> some View {
        modifier(DownloadHost())
    }
}

private struct DownloadHost: ViewModifier {
    @State private var downloads = KeptDownloads()

    func body(content: Content) -> some View {
        content
            .environment(\.startDownload, StartDownloadAction(downloads: downloads))
            .onDisappear { downloads.stopAll() }
    }
}

/// The running downloads by the file they load; a view reading `isRunning` shows when one ends.
@Observable private final class KeptDownloads {
    /// Each with a token of its own: one stopped as the view went, ending after a new one of its file started, leaves
    /// the new one in.
    private var running: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    func start(_ id: String, _ download: @escaping () async -> Void) {
        guard running[id] == nil else { return }
        let token = UUID()
        running[id] = (token, Task {
            await download()
            if running[id]?.token == token { running[id] = nil }
        })
    }

    func isRunning(_ id: String) -> Bool { running[id] != nil }

    func stopAll() {
        for download in running.values { download.task.cancel() }
        running = [:]
    }
}
