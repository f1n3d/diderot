import UIKit

/// UIKit parts SwiftUI has no API for: the "Comment" item in the editor's selection menu. UIKit builds that menu via
/// the responder chain, which ends at this delegate; the open page's model answers it (see `EditorSelectionCommands`).
final class AppDelegate: UIResponder, UIApplicationDelegate {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }
        let comment = UICommand(
            title: String(localized: "Comment"), image: UIImage(systemName: "text.bubble"),
            action: #selector(commentOnSelection(_:))
        )
        // Before Cut/Copy/Paste: after them, the item lands on the menu's second page on narrow screens.
        let menu = UIMenu(options: .displayInline, children: [comment])
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(menu, beforeMenu: .standardEdit)
        } else {
            builder.insertChild(menu, atStartOfMenu: .root)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(commentOnSelection(_:)) {
            return EditorSelectionCommands.model?.canCommentOnSelection == true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func commentOnSelection(_ sender: Any?) {
        EditorSelectionCommands.model?.editsComment = true
    }
}

/// Bridges the selection menu to the open page: it sets `model` on appear and clears it on disappear if still its own.
@MainActor
enum EditorSelectionCommands {
    static weak var model: DocumentModel?
}
