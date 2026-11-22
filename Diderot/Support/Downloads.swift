import SwiftUI

/// Starts a download that a tap asks for to open a file (an attachment, a database file), kept by the view around
/// (`View.keepsDownloads`).
struct StartDownloadAction {
    let start: (@escaping () async -> Void) -> Void

    func callAsFunction(_ download: @escaping () async -> Void) { start(download) }
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
    @State private var downloads: [UUID: Task<Void, Never>] = [:]

    func body(content: Content) -> some View {
        content
            .environment(\.startDownload, StartDownloadAction { download in
                let id = UUID()
                downloads[id] = Task {
                    await download()
                    downloads[id] = nil
                }
            })
            .onDisappear {
                for download in downloads.values { download.cancel() }
                downloads = [:]
            }
    }
}
