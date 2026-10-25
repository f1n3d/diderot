import SwiftUI
import UIKit

/// A SwiftUI view in a UIKit wrapper with a long-press menu and dragging on the same view, so iOS combines them as in
/// Photos or Files (hold: menu, move: drag). SwiftUI puts `.contextMenu` and `.draggable` on separate layers; the menu
/// always wins. Drops go through SwiftUI `DropDelegate`s as usual. Used by kanban cards and the tabs of a tabs block.
struct MenuDragHost: UIViewControllerRepresentable {
    let content: AnyView
    /// Drag payload (`DragPayload`); `nil` = not draggable.
    let dragPayload: String?
    /// Width to fit into when the layout proposes none; nil: the content's own width (a tab in a scrolling strip).
    var fallbackWidth: CGFloat?
    var cornerRadius: CGFloat = 12
    let menu: () -> UIMenu
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        controller.sizingOptions = [.intrinsicContentSize]
        controller.view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        controller.view.addInteraction(UIDragInteraction(delegate: context.coordinator))
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        context.coordinator.parent = self
        controller.rootView = content
        for case let drag as UIDragInteraction in controller.view.interactions {
            drag.isEnabled = dragPayload != nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>, context: Context) -> CGSize? {
        let width = proposal.width ?? fallbackWidth ?? .greatestFiniteMagnitude
        return uiViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
        var parent: MenuDragHost

        init(parent: MenuDragHost) {
            self.parent = parent
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let menu = parent.menu
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            return UITargetedPreview(view: view, parameters: rounded(view))
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            guard let payload = parent.dragPayload else { return [] }
            return [UIDragItem(itemProvider: DragPayload.provider(payload))]
        }

        func dragInteraction(
            _ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession
        ) -> UITargetedDragPreview? {
            guard let view = interaction.view else { return nil }
            return UITargetedDragPreview(view: view, parameters: rounded(view))
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
            parent.onDragBegan()
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            parent.onDragEnded()
        }

        private func rounded(_ view: UIView) -> UIDragPreviewParameters {
            let parameters = UIDragPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: parent.cornerRadius)
            parameters.backgroundColor = .clear
            return parameters
        }
    }
}

/// UI test switches of a `MenuDragHost` use, by key (`base.card`, `tabs.tab`). `-<key>Menu NO` turns the menu off:
/// XCUITest doesn't perform the menu-to-drag transition, but without the menu its press-and-drag starts a real drag
/// session. `-<key>Drag NO` turns dragging off for menu tests: while the menu is open, iOS keeps the drag armed, and
/// XCUITest then waits a minute per step for animations to finish.
enum MenuDragTesting {
    static func showsMenu(_ key: String) -> Bool { isOn(key + "Menu") }

    static func allowsDrag(_ key: String) -> Bool { isOn(key + "Drag") }

    private static func isOn(_ name: String) -> Bool {
        #if DEBUG
        // Launch arguments arrive as strings ("NO"): `bool(forKey:)` parses them, `as? Bool` doesn't.
        UserDefaults.standard.object(forKey: name) == nil || UserDefaults.standard.bool(forKey: name)
        #else
        true
        #endif
    }
}
