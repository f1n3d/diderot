import SwiftUI
import DocmostKit

/// Long-press and drag a block to move it, unless a block is being edited; where shown, its "…" button offers Duplicate,
/// Delete and edit actions.
struct BlockDragModifier: ViewModifier {
    let model: DocumentModel
    let entry: NodeEntry
    @State private var height: CGFloat = 0
    @State private var isTargeted = false
    @State private var insertBefore = true
    @State private var showsActions = false

    /// Text, lists and code get actions from the keyboard toolbar, synced blocks from their menu; others from "…".
    private var showsMenuButton: Bool {
        if ["paragraph", "heading", "bulletList", "orderedList", "taskList", "codeBlock", "transclusionSource",
            "transclusionReference"].contains(entry.node.type) { return false }
        // A table shows its own "…" after its last column: on a wide one this corner would cover a cell.
        if entry.node.type == "table" { return false }
        // Active columns show their own bar on top; the button would cover it.
        if entry.node.type == "columns", model.activeAncestorPath(ofType: "columns") == entry.ref.path { return false }
        return true
    }

    func body(content: Content) -> some View {
        // By `engine`, which the page keeps: `isEditable` turns true after the first sync, and switching branches
        // would rebuild every block (formulas re-render, media reload).
        if model.engine != nil {
            content
                .environment(\.showsBlockActions, model.isEditable && showsMenuButton)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .overlay(alignment: insertBefore ? .top : .bottom) {
                    if isTargeted {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .offset(y: insertBefore ? -6 : 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.isEditable, showsMenuButton {
                        BlockActionsButton {
                            model.deactivate()
                            showsActions = true
                        }
                        // On the button: iOS shows the actions as a popover from the view they're attached to.
                        .confirmationDialog("Block", isPresented: $showsActions, titleVisibility: .hidden) {
                            switch entry.node.type {
                            case "embed":
                                Button("Change Link") {
                                    let provider = EmbedProvider(rawValue: entry.node.string("provider") ?? "") ?? .iframe
                                    model.editorSheet = .embed(.edit(entry.ref), provider: provider, link: entry.node.string("src") ?? "")
                                }
                            case "mathBlock":
                                Button("Edit Equation") { model.editorSheet = .mathBlock(.edit(entry.ref), latex: entry.node.string("text") ?? "") }
                            case "drawio", "excalidraw":
                                Button("Edit in Web Editor") { model.requestsWebEditor = true }
                            case "integrationCard":
                                Button("Show as Mention") { Task { await model.showIntegrationCard(entry.ref, as: .mention) } }
                                Button("Show as URL") { Task { await model.showIntegrationCard(entry.ref, as: .link) } }
                            default:
                                EmptyView()
                            }
                            Button("Duplicate") { Task { await model.duplicate(entry.ref) } }
                            Button("Delete", role: .destructive) { Task { await model.delete(entry.ref) } }
                        }
                    }
                }
                .onDrag {
                    DragPayload.provider(BlockDropDelegate.prefix(model) + entry.ref.identity)
                }
                // While a block is edited, a long press belongs to the text (`LongPressPlacesCaret`), not to moving
                // blocks: they move through "Arrange Blocks" then. This one keeps the drag from starting elsewhere.
                .gesture(LongPressGesture(minimumDuration: 0.3), including: model.hasActiveBlock ? .all : .subviews)
                .onDrop(of: DragPayload.types, delegate: BlockDropDelegate(
                    model: model, ref: entry.ref, height: { height },
                    targeted: { isTargeted = $0 }, before: { insertBefore = $0 }
                ))
        } else {
            content
        }
    }
}

private struct BlockDropDelegate: DropDelegate {
    let model: DocumentModel
    let ref: NodeRef
    let height: () -> CGFloat
    let targeted: (Bool) -> Void
    let before: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        model.isEditable && info.hasItemsConforming(to: DragPayload.types)
    }

    func dropEntered(info: DropInfo) {
        targeted(true)
        before(info.location.y < height() / 2)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        before(info.location.y < height() / 2)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        targeted(false)
    }

    /// Carries the page: a block dragged from another window's page (iPad) must not move one here with its identity.
    static func prefix(_ model: DocumentModel) -> String { "docmost-block:\(model.page.id)/" }

    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        let insertBefore = info.location.y < height() / 2
        let model = model
        let ref = ref
        return DragPayload.load(info, prefix: Self.prefix(model)) { identity in
            Task { await model.moveBlock(identity: identity, relativeTo: ref, before: insertBefore) }
        }
    }
}
