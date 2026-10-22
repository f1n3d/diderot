import SwiftUI
import DocmostKit

/// Where a page dropped onto a tree row goes.
enum TreeDropZone: Equatable {
    case before, after, nest
}

/// Long-press drag of a page: the target row's top/bottom third places it before/after, the middle nests it.
struct TreeDragModifier: ViewModifier {
    let page: SidebarPage
    /// The tree's space: a page dragged in from another space's window (iPad) is ignored, which the server would
    /// refuse ("Parent page not found") or put at its own space's top level.
    let spaceId: String
    let enabled: Bool
    let onDrop: @MainActor @Sendable (_ draggedPageId: String, _ zone: TreeDropZone) -> Void
    @State private var height: CGFloat = 0
    @State private var zone: TreeDropZone?

    static let prefix = "docmost-page:"

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .background {
                    if zone == .nest {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.15))
                    }
                }
                .overlay(alignment: zone == .after ? .bottom : .top) {
                    if zone == .before || zone == .after {
                        Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 12)
                    }
                }
                .onDrag {
                    DragPayload.provider(Self.prefix + spaceId + "/" + page.id)
                }
                .onDrop(of: DragPayload.types, delegate: TreeDropDelegate(
                    pageId: page.id, spaceId: spaceId, height: { height }, zone: { zone = $0 }, perform: onDrop
                ))
        } else {
            content
        }
    }
}

private struct TreeDropDelegate: DropDelegate {
    let pageId: String
    let spaceId: String
    let height: () -> CGFloat
    let zone: @MainActor (TreeDropZone?) -> Void
    let perform: @MainActor @Sendable (String, TreeDropZone) -> Void

    private func zone(for location: CGPoint) -> TreeDropZone {
        let h = max(height(), 1)
        if location.y < h / 3 { return .before }
        if location.y > h * 2 / 3 { return .after }
        return .nest
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: DragPayload.types)
    }

    func dropEntered(info: DropInfo) {
        zone(zone(for: info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone(zone(for: info.location))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        zone(nil)
        let target = zone(for: info.location)
        let perform = perform
        let targetId = pageId
        return DragPayload.load(info, prefix: TreeDragModifier.prefix + spaceId + "/") { draggedId in
            guard draggedId != targetId else { return }
            perform(draggedId, target)
        }
    }
}
