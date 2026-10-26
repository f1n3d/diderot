import SwiftUI
import DocmostKit

/// Where a page dropped onto a tree row goes.
enum TreeDropZone: Equatable {
    case before, after, nest

    /// The zone under `y` of a row `height` tall, as the web's page tree splits a row: its top quarter places the page
    /// before the row, its bottom quarter after it, the half between nests it. A row that shows its subpages has no
    /// "after", as the line would show above the subpages while the page went below them: its bottom quarter nests the
    /// page too.
    static func at(_ y: CGFloat, height: CGFloat, showsSubpages: Bool) -> TreeDropZone {
        let height = max(height, 1)
        if y <= height / 4 { return .before }
        if y >= height * 3 / 4 { return showsSubpages ? .nest : .after }
        return .nest
    }
}

/// Long-press drag of a page onto another one: before, after or into it (`TreeDropZone`), as on the web.
/// - The line before or after a row starts at that row's level, so between a last subpage and the next page it shows
///   which of the two levels the page goes to.
/// - A page never goes onto itself or its own subpages; those rows don't take it.
/// - A collapsed page with subpages opens when the dragged page stays over it, so it can go between them.
struct TreeDragModifier: ViewModifier {
    let page: SidebarPage
    let depth: Int
    /// The tree's space: a page dragged in from another space's window (iPad) is ignored, which the server would
    /// refuse ("Parent page not found") or put at its own space's top level.
    let spaceId: String
    let enabled: Bool
    let store: PageTreeStore
    let onDrop: @MainActor @Sendable (_ draggedPageId: String, _ zone: TreeDropZone) -> Void
    @State private var height: CGFloat = 0
    @State private var zone: TreeDropZone?
    @State private var opening: Task<Void, Never>?

    static let prefix = "docmost-page:"
    /// The rows' indent per level (`TreeRow`): a level's guide, 20 points, and the row's spacing, 4.
    static let indent: CGFloat = 24
    /// How long the dragged page stays over a collapsed page before it opens (the web's delay).
    static let openDelay = Duration.milliseconds(500)
    /// The page whose drag started last, in any window, and its space. A drop's payload loads only once it's dropped, so
    /// the rows know the dragged page from here. A value left by an earlier drag does no harm: what else is dragged
    /// (a block, a card) can't be dropped on the tree anyway.
    private static var dragged: (spaceId: String, pageId: String)?

    /// Expanded with its subpages below (one whose subpages failed to load collapses again).
    private var showsSubpages: Bool { store.isExpanded(page.id) && !store.children(of: page.id).isEmpty }

    func body(content: Content) -> some View {
        if enabled {
            content
                // The whole row takes the drop: above and below its title and buttons is empty space, which takes
                // none, and that's where the line before or after it is.
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .background {
                    if zone == .nest {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.15))
                    }
                }
                .overlay(alignment: zone == .after ? .bottom : .top) {
                    if zone == .before || zone == .after {
                        Capsule().fill(Color.accentColor).frame(height: 3)
                            .padding(.leading, 12 + CGFloat(depth) * Self.indent)
                            .padding(.trailing, 12)
                    }
                }
                .onDrag {
                    Self.dragged = (spaceId, page.id)
                    return DragPayload.provider(Self.prefix + spaceId + "/" + page.id)
                }
                .onDrop(of: DragPayload.types, delegate: TreeDropDelegate(
                    pageId: page.id, spaceId: spaceId, height: { height }, showsSubpages: { showsSubpages },
                    accepts: accepts, zone: { zone = $0 }, hovering: hovering, perform: onDrop
                ))
        } else {
            content
        }
    }

    /// A page of this space, not the dragged page itself or one of its subpages: the server can't put a page into its own
    /// subtree.
    private func accepts() -> Bool {
        guard let dragged = Self.dragged else { return true }
        return dragged.spaceId == spaceId && dragged.pageId != page.id && !store.isDescendant(page.id, of: dragged.pageId)
    }

    /// Opens a collapsed page with subpages once the dragged page stayed over it for `openDelay`.
    private func hovering(_ isOver: Bool) {
        opening?.cancel()
        opening = nil
        guard isOver, page.mayHaveChildren, !store.isExpanded(page.id) else { return }
        let store = store, pageId = page.id
        opening = Task { @MainActor in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, !store.isExpanded(pageId) else { return }
            await store.toggle(pageId)
        }
    }
}

private struct TreeDropDelegate: DropDelegate {
    let pageId: String
    let spaceId: String
    let height: () -> CGFloat
    let showsSubpages: () -> Bool
    let accepts: () -> Bool
    let zone: @MainActor (TreeDropZone?) -> Void
    let hovering: @MainActor (Bool) -> Void
    let perform: @MainActor @Sendable (String, TreeDropZone) -> Void

    private func zone(for location: CGPoint) -> TreeDropZone {
        TreeDropZone.at(location.y, height: height(), showsSubpages: showsSubpages())
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: DragPayload.types) && accepts()
    }

    func dropEntered(info: DropInfo) {
        zone(zone(for: info.location))
        hovering(true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone(zone(for: info.location))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone(nil)
        hovering(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        zone(nil)
        hovering(false)
        let target = zone(for: info.location)
        let perform = perform
        let targetId = pageId
        return DragPayload.load(info, prefix: TreeDragModifier.prefix + spaceId + "/") { draggedId in
            guard draggedId != targetId else { return }
            perform(draggedId, target)
        }
    }
}
