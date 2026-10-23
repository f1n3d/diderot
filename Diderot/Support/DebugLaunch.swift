import Foundation

/// Debug-build launch parameters (`Tools/run-sim.sh`, UI tests) for auto sign-in and to jump straight to a view:
/// `DOCMOST_DEBUG_SPACE=<slug|id>`, `DOCMOST_DEBUG_PAGE=<slugId|id>`, `DOCMOST_DEBUG_EXPAND=1`.
nonisolated enum DebugLaunch {
    static var spaceId: String? { value("DOCMOST_DEBUG_SPACE") }
    static var pageId: String? { value("DOCMOST_DEBUG_PAGE") }
    static var expandsTree: Bool { value("DOCMOST_DEBUG_EXPAND") == "1" }
    /// Block the reader scrolls to after loading, as `NodeRef.anchorId`: UniqueID, else index path (`12` = 13th block).
    static var scrollBlockId: String? { value("DOCMOST_DEBUG_SCROLL") }
    static var webLayout: Bool { value("DOCMOST_DEBUG_WEB") == "1" }
    /// Text edited in its block, as with VoiceOver (which doesn't run in the simulator), for UI tests.
    static var editsInBlock: Bool { value("DOCMOST_DEBUG_IN_BLOCK") == "1" }
    /// Start route: `search`, `favorites`, `recent` (MainTabView), `notifications` (HomeView); together with
    /// `DOCMOST_DEBUG_PAGE` also `comments`, `history`, `webeditor` (PageView).
    static var route: String? { value("DOCMOST_DEBUG_ROUTE") }
    /// View of a database (base) page, by name or type (e.g. `kanban`), for screenshots.
    static var baseView: String? { value("DOCMOST_DEBUG_BASE_VIEW") }
    /// Prefilled search query.
    static var query: String? { value("DOCMOST_DEBUG_QUERY") }
    /// Browser sign-in instead of auto sign-in; fills in and submits the web client's form (cookie-capture test).
    static var browserLogin: Bool { value("DOCMOST_DEBUG_BROWSER_LOGIN") == "1" }
    /// After the page's first live sync: focus block `<index>` or list item `<index>#<item>`.
    static var focusTarget: (block: Int, item: Int?)? {
        guard let spec = value("DOCMOST_DEBUG_FOCUS") else { return nil }
        let parts = spec.split(separator: "#").map(String.init)
        guard let block = parts.first.flatMap(Int.init) else { return nil }
        return (block, parts.count > 1 ? Int(parts[1]) : nil)
    }
    /// Text appended to the focused block (simulates typing through the `TextEditor` binding).
    static var typeText: String? { raw("DOCMOST_DEBUG_TYPE") }
    /// Paragraph appended after the page's first live sync (live test of the write path).
    static var editText: String? { raw("DOCMOST_DEBUG_EDIT") }
    static var server: String? { raw("DOCMOST_DEBUG_SERVER") }
    /// In place of the server's version, e.g. `0.97.0` for read-only pages (`ReadySession.newerServerVersion`).
    static var serverVersion: String? { value("DOCMOST_DEBUG_SERVER_VERSION") }
    /// The app reports offline for its first seconds, then the real state (UI tests of going back online).
    static var offlineSeconds: Double? { value("DOCMOST_DEBUG_OFFLINE_SECONDS").flatMap(Double.init) }
    static var email: String? { raw("DOCMOST_DEBUG_EMAIL") }
    static var password: String? { raw("DOCMOST_DEBUG_PASSWORD") }

    private static func value(_ key: String) -> String? {
        let value = raw(key)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    /// Untrimmed (`DOCMOST_DEBUG_TYPE=" (bearbeitet)"` keeps its leading space); `nil` if empty or in release builds.
    private static func raw(_ key: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
        #else
        return nil
        #endif
    }
}
