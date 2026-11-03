import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

/// The offline cache is per server, so someone else signing in there must not see the previous user's pages.
struct AppSessionTests {
    @Test func signInOfAnotherUserOrWorkspaceClearsTheCache() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "app-session-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = DiskCache(scope: "server", baseDirectory: base)
        let alice = try user("alice"), bob = try user("bob"), bobElsewhere = try user("bob", workspace: "w2")
        /// Signs `user` in on a cache that holds a page.
        func pageSurvives(signInOf user: CurrentUser) async -> Bool {
            await cache.write(["page"], key: CacheKey.recentlyOpened)
            let removed = await AppSession.storeCurrentUser(user, in: cache)
            let survives = await cache.read([String].self, key: CacheKey.recentlyOpened) != nil
            #expect(removed == !survives, "sign-in also removes the web editor data when the result is true")
            return survives
        }

        // No cached user (iOS purged the cache): the web editor may hold this user's unsynced edits.
        #expect(await pageSurvives(signInOf: alice))
        #expect(await pageSurvives(signInOf: alice))
        #expect(await !pageSurvives(signInOf: bob))
        #expect(await !pageSurvives(signInOf: bobElsewhere))
    }

    /// The app sends its own name, not Docmost's: it isn't Docmost's app.
    @Test func userAgentNamesTheApp() {
        #expect(AppSession.userAgent.hasPrefix("Diderot/"))
        #expect(AppSession.userAgent.contains("CPU iPhone OS"))
    }

    private func user(_ id: String, workspace: String = "w1") throws -> CurrentUser {
        let json = #"{"user": {"id": "\#(id)", "email": "\#(id)@example.com"}, "workspace": {"id": "\#(workspace)", "name": "Docs"}}"#
        return try JSONDecoder().decode(CurrentUser.self, from: Data(json.utf8))
    }
}

/// The bundled editor follows Docmost 0.97 (`Engine/`): newer servers get read-only pages, unknown versions don't.
/// Only known 0.97 servers and newer get the blocks 0.96 doesn't know.
struct ServerVersionTests {
    @Test func versionsNewerThanTheEditor() {
        let versions = [("0.96.0", false), ("0.97.0", false), ("0.97.3", false), ("v0.97.0-beta.1", false),
                        ("0.98.0", true), ("v0.98.0-beta.1", true), ("1.0.0", true), ("", false), ("next", false)]
        for (version, newer) in versions {
            #expect(ReadySession.isNewerThanEditor(version) == newer, "\(version)")
        }
        #expect(!ReadySession.isNewerThanEditor(nil))
    }

    @Test func docmost097Features() throws {
        let versions: [(String?, Bool)] = [("0.96.4", false), ("0.97.0", true), ("v0.97.1", true), ("0.98.0", true),
                                           ("1.0.0", true), (nil, false), ("next", false)]
        for (version, expected) in versions {
            #expect(ReadySession.supportsDocmost097(version) == expected, "\(version ?? "nil")")
        }
    }
}

/// A late network answer must not undo a server switch or sign-out, open a closed editor or show under another view,
/// filter or query; a failed one must not drop the license, leave notifications marked read, make a database look
/// empty or drop a card from its offline copy; an edit or load must not take a card out of its detail sheet or bring a
/// deleted one back; a second window must not restore the session again. Serialized: the tests share `StubURLProtocol`.
@Suite(.serialized)
struct AppSessionRaceTests {}
