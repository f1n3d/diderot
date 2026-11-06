import SwiftUI

/// A sheet a block opens over the page (`View.blockPresentations`): a PDF full screen, the sign-in to a service.
struct BlockSheet: Identifiable {
    let id: String
    var onDismiss: (() -> Void)?
    let content: () -> AnyView
}

/// What a block opens over the page.
enum BlockPresentation {
    case modal(BlockSheet)
    /// A downloaded file in Quick Look (an attachment).
    case quickLook(URL)
}

/// Opens what a block shows over the page from the page around it (`View.blockPresentations`).
struct PresentFromPageAction {
    let present: (BlockPresentation) -> Void

    func callAsFunction(_ presentation: BlockPresentation) { present(presentation) }
}

extension EnvironmentValues {
    /// Nil where no view around presents for the blocks: they present it themselves then.
    @Entry var presentFromPage: PresentFromPageAction?
}

extension View {
    /// Presents what the blocks inside open over the page (a PDF full screen, an attachment's preview, the sign-in to a
    /// service) from here instead of from the block's row. The editor keys the rows of blocks without an id (media,
    /// cards) by their path: a collaborator's block above made the row anew, and what it had opened closed, a sign-in
    /// halfway with it (review V43).
    func blockPresentations() -> some View {
        modifier(BlockPresentationHost())
    }
}

private struct BlockPresentationHost: ViewModifier {
    @State private var sheet: BlockSheet?
    @State private var dismissed: (() -> Void)?
    @State private var preview: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.presentFromPage, PresentFromPageAction { presentation in
                switch presentation {
                case .modal(let sheet):
                    dismissed = sheet.onDismiss
                    self.sheet = sheet
                case .quickLook(let url):
                    preview = url
                }
            })
            .linkSheet(item: $sheet, onDismiss: {
                dismissed?()
                dismissed = nil
            }) { $0.content() }
            .quickLookPreview($preview)
    }
}
