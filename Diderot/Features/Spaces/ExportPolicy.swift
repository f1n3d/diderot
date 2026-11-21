import Foundation
import DocmostKit

/// Exports turned off (license feature `export:controls`, Docmost 0.98): the workspace's setting first, then the space's,
/// as the web's `useExportDisabled` reads them. The server then refuses `pages/export` with its message, and the web
/// turns off Export, Copy as Markdown and printing with the reason as their tooltip; the app turns off its two. Its
/// Copy as Markdown goes through `pages/info`, which the server doesn't block.
enum ExportPolicy {
    /// Why exports are off for pages of `space`, nil where they aren't.
    static func offReason(workspace: Workspace?, space: Space?) -> String? {
        if workspace?.settings?["export"]?["disabled"]?.boolValue == true {
            return String(localized: "Export has been disabled at the workspace level.")
        }
        if space?.settings?["export"]?["disabled"]?.boolValue == true {
            return String(localized: "Export has been disabled for this space.")
        }
        return nil
    }
}
