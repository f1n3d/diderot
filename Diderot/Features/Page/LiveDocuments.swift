import Foundation
import DocmostKit

/// The engine's last document of each editable page opened online, in memory for 90 s: the server persists `content`
/// only ~10 s after the last change, so a page reopened meanwhile shows the engine's state.
@MainActor
enum LiveDocuments {
    private struct Entry {
        let document: PMNode
        let storedAt: Date
    }

    private static var entries: [String: Entry] = [:]
    private static let maxAge: TimeInterval = 90

    static func store(_ document: PMNode, for pageId: String) {
        entries = entries.filter { Date.now.timeIntervalSince($0.value.storedAt) < maxAge }
        entries[pageId] = Entry(document: document, storedAt: .now)
    }

    /// The cached document if newer than the server state; `serverClockOffset` maps the server's `updatedAt` to the
    /// device clock.
    static func document(for pageId: String, newerThan updatedAt: Date?, serverClockOffset: TimeInterval) -> PMNode? {
        guard let entry = entries[pageId], Date.now.timeIntervalSince(entry.storedAt) < maxAge else {
            entries[pageId] = nil
            return nil
        }
        if let updatedAt, updatedAt - serverClockOffset > entry.storedAt { return nil }
        return entry.document
    }
}
