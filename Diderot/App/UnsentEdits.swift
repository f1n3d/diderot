import Foundation
import DocmostKit

/// Page titles and database fields the server didn't get, kept in a session's unsent changes (`UnsentChanges`) until it
/// answers: `AppSession` sends them going online, back in the app and opening a page. The last save wins, as typing on
/// the web does.
@MainActor
final class UnsentEdits {
    /// A kept title or field that can never go (`UnsentChanges.isFinal`), dropped by `sendTitles` or `sendCells`: `name`
    /// is what the user typed.
    struct DroppedChange: Sendable {
        let name: String
        let reason: String

        /// The notice for changes dropped: the page or entry was deleted, access to it removed or the input refused, and
        /// the user expects them saved.
        static func notice(for dropped: [DroppedChange]) -> String? {
            guard let first = dropped.first else { return nil }
            return dropped.count == 1
                ? String(localized: "“\(first.name)” not saved: \(first.reason)")
                : String(localized: "\(dropped.count) changes not saved, among them “\(first.name)”: \(first.reason)")
        }
    }

    private var isSendingTitles = false
    private var isSendingCells = false

    /// Keeps a page title for `sendTitles`. False if it couldn't be kept (the kept titles can't be read, or not written):
    /// then nothing may promise it a later try.
    static func keepTitle(_ title: String, pageId: String, spaceId: String?, in store: DiskCache) async -> Bool {
        do {
            // In one step: a title kept or sent meanwhile (another window) isn't lost.
            try await store.update([String: UnsentTitle].self, key: CacheKey.unsentTitles, initial: [:]) {
                $0[pageId] = UnsentTitle(title: title, spaceId: spaceId)
            }
            return true
        } catch {
            AppLog.session.error("Title not kept: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The page's kept title, if it still waits for the server.
    static func title(pageId: String, in store: DiskCache) async -> String? {
        await store.read([String: UnsentTitle].self, key: CacheKey.unsentTitles)?[pageId]?.title
    }

    /// Drops the page's kept title: it, or a newer one, reached the server. With `title`, only while it is still that one:
    /// a newer title kept meanwhile stays.
    static func forgetTitle(pageId: String, title: String?, in store: DiskCache) async {
        do {
            try await store.update([String: UnsentTitle].self, key: CacheKey.unsentTitles, initial: [:]) { titles in
                if let kept = titles[pageId], title == nil || kept.title == title { titles[pageId] = nil }
            }
        } catch {
            AppLog.session.error("Kept title not dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends the titles kept in `store` with `send` (page id, title). Returns the spaces whose pages got theirs, and the
    /// titles that can never go, which it dropped; after another error the rest waits for the next try.
    func sendTitles(in store: DiskCache, send: (String, String) async throws -> Void) async -> (spaces: [String], dropped: [DroppedChange]) {
        guard !isSendingTitles else { return ([], []) }
        isSendingTitles = true
        defer { isSendingTitles = false }
        let titles: [String: UnsentTitle]
        do {
            titles = try await store.readThrowing([String: UnsentTitle].self, key: CacheKey.unsentTitles) ?? [:]
        } catch {
            AppLog.session.error("Kept titles unreadable: \(error.localizedDescription, privacy: .public)")
            return ([], [])
        }
        var spaces: [String] = [], dropped: [DroppedChange] = []
        for (pageId, kept) in titles {
            // A newer title saved meanwhile replaced or dropped this one.
            guard (try? await store.readThrowing([String: UnsentTitle].self, key: CacheKey.unsentTitles))?[pageId]?.title == kept.title
            else { continue }
            do {
                try await send(pageId, kept.title)
                if let spaceId = kept.spaceId { spaces.append(spaceId) }
            } catch let error where UnsentChanges.isFinal(error) {
                AppLog.session.error("Kept title dropped: \(error.userMessage, privacy: .public)")
                dropped.append(DroppedChange(name: kept.title, reason: error.userMessage))
            } catch {
                break
            }
            // A title kept for the page meanwhile stays.
            try? await store.update([String: UnsentTitle].self, key: CacheKey.unsentTitles, initial: [:]) { titles in
                if titles[pageId]?.title == kept.title { titles[pageId] = nil }
            }
        }
        return (spaces, dropped)
    }

    /// Sends the database fields kept in `store` (`UnsentCell`) with `send`, as `sendTitles` does titles. Returns the ones
    /// that can never go (entry deleted, access gone, value refused), which it dropped.
    func sendCells(in store: DiskCache, send: (UnsentCell) async throws -> Void) async -> [DroppedChange] {
        guard !isSendingCells else { return [] }
        isSendingCells = true
        defer { isSendingCells = false }
        let cells: [String: UnsentCell]
        do {
            cells = try await store.readThrowing([String: UnsentCell].self, key: CacheKey.unsentCells) ?? [:]
        } catch {
            AppLog.session.error("Kept fields unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var dropped: [DroppedChange] = []
        for (key, kept) in cells {
            // A newer input saved or kept meanwhile replaced or dropped this one.
            guard (try? await store.readThrowing([String: UnsentCell].self, key: CacheKey.unsentCells))?[key] == kept else { continue }
            do {
                try await send(kept)
            } catch let error where UnsentChanges.isFinal(error) {
                AppLog.session.error("Kept field dropped: \(error.userMessage, privacy: .public)")
                dropped.append(DroppedChange(name: kept.typed.isEmpty ? kept.propertyName : kept.typed, reason: error.userMessage))
            } catch {
                break
            }
            try? await store.update([String: UnsentCell].self, key: CacheKey.unsentCells, initial: [:]) { cells in
                if cells[key] == kept { cells[key] = nil }
            }
        }
        return dropped
    }
}
