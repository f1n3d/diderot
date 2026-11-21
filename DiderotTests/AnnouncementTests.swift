import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Workspace announcements (license feature `announcements`, Docmost 0.98) as the web picks and shows them.
@MainActor
struct AnnouncementTests {
    /// The bar shows the running announcement with the latest start, by the server's clock, unless it was dismissed.
    @Test func newestRunningAnnouncementShows() throws {
        let now = try Self.date("2026-11-21T10:00:00Z")
        let items: [Announcement] = try [
            Self.announcement("old", starts: "2026-11-01T00:00:00Z"),
            Self.announcement("new", starts: "2026-11-20T00:00:00Z", ends: "2026-11-22T00:00:00Z"),
            Self.announcement("later", starts: "2026-11-21T12:00:00Z"),
            Self.announcement("over", starts: "2026-11-21T00:00:00Z", ends: "2026-11-21T09:00:00Z"),
        ]
        #expect(AnnouncementsStore.current(items, at: now) { _ in false }?.id == "new")
        #expect(AnnouncementsStore.current(items, at: now) { $0.id == "new" }?.id == "old")
        #expect(AnnouncementsStore.current(items, at: try Self.date("2026-11-23T00:00:00Z")) { _ in false }?.id == "later")
        #expect(AnnouncementsStore.current([], at: now) { _ in false } == nil)
    }

    /// A dismissal holds for the announcement as it was: edited since (text, color, type), it shows again.
    @Test func editedAnnouncementShowsAgain() throws {
        let first = try Self.announcement("a", text: "Wartung am Samstag")
        let edited = try Self.announcement("a", text: "Wartung am Sonntag")
        #expect(AnnouncementsStore.fingerprint(of: first) == AnnouncementsStore.fingerprint(of: try Self.announcement("a", text: "Wartung am Samstag")))
        #expect(AnnouncementsStore.fingerprint(of: first) != AnnouncementsStore.fingerprint(of: edited))
    }

    /// Bold, italic, underline and links come along; a link goes to the web, mail or a path on the server only.
    @Test func textKeepsItsMarksAndSafeLinks() throws {
        let server = try #require(URL(string: "https://docs.example.com"))
        let content: JSONValue = ["type": "doc", "content": [["type": "paragraph", "content": [
            ["type": "text", "text": "Neu: "],
            ["type": "text", "text": "Vorlagen", "marks": [["type": "bold"]]],
            ["type": "text", "text": " hier", "marks": [["type": "link", "attrs": ["href": "/s/demo/p/abc"]]]],
        ]]]]
        let text = AnnouncementStyle.text(content, serverURL: server)
        #expect(String(text.characters) == "Neu: Vorlagen hier")
        let bold = try #require(text.range(of: "Vorlagen"))
        #expect(text[bold].inlinePresentationIntent == .stronglyEmphasized)
        let link = try #require(text.range(of: " hier"))
        #expect(text[link].link == URL(string: "https://docs.example.com/s/demo/p/abc"))
        #expect(AnnouncementStyle.link("https://docmost.com/x", serverURL: server) == URL(string: "https://docmost.com/x"))
        #expect(AnnouncementStyle.link("mailto:it@example.com", serverURL: server) != nil)
        #expect(AnnouncementStyle.link("javascript:alert(1)", serverURL: server) == nil)
        #expect(AnnouncementStyle.link("//evil.example.com/x", serverURL: server) == nil)
    }

    private static func announcement(_ id: String, starts: String? = nil, ends: String? = nil, text: String = "Hinweis") throws -> Announcement {
        let json: JSONValue = [
            "id": .string(id), "type": "info", "color": "blue", "isDismissible": true,
            "content": ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": .string(text)]]]]],
            "startsAt": starts.map(JSONValue.string) ?? .null, "endsAt": ends.map(JSONValue.string) ?? .null,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Announcement.self, from: JSONEncoder().encode(json))
    }

    private static func date(_ text: String) throws -> Date {
        try Date(text, strategy: .iso8601)
    }
}

extension AppSessionRaceTests {
    /// Loading the announcements: only with the license feature, and no more once the server says it has none (404).
    @Suite struct Announcements: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        @Test func loadsWithTheLicenseAndStopsAtA404() async throws {
            let session = try await signedIn(features: ["announcements"])
            defer { resetStub() }
            let announcements = AnnouncementsStore(session: session)
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"now": "2026-11-21T10:00:00.000Z", "items": [{"id": "a1", "type": "warning", "color": "yellow", "isDismissible": true, "content": {"type": "doc", "content": []}, "startsAt": null, "endsAt": null}]}}"#
            }
            await announcements.load()
            #expect(announcements.shown?.id == "a1")
            announcements.dismiss(try #require(announcements.shown))
            #expect(announcements.shown == nil)

            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Cannot POST /api/announcements/visible"}"# }
            await announcements.load()
            StubURLProtocol.requests.withLock { $0 = [] }
            await announcements.load()
            #expect(StubURLProtocol.requests.withLock { $0 }.isEmpty)
            UserDefaults.standard.removeObject(forKey: "announcement.dismissed.\(a.absoluteString).a1")
            await removeCaches()
        }

        @Test func withoutTheLicenseNothingIsAsked() async throws {
            let session = try await signedIn(features: ["bases"])
            defer { resetStub() }
            StubURLProtocol.requests.withLock { $0 = [] }
            let announcements = AnnouncementsStore(session: session)
            await announcements.load()
            #expect(announcements.shown == nil)
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/announcements/visible"))
            await removeCaches()
        }

        /// Signed in to a on Docmost 0.98 with `features` in the license.
        private func signedIn(features: [String]) async throws -> AppSession {
            let quoted = features.map { "\"\($0)\"" }.joined(separator: ", ")
            // One answer for users/me, workspace/entitlements and version alike.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}, "currentVersion": "0.98.0", "tier": "enterprise", "features": [\#(quoted)]}}"#
            }
            let session = try await sessionOnA()
            StubURLProtocol.body.withLock { $0 = nil }
            try #require(session.ready?.entitlements.has(features[0]) == true)
            return session
        }

        private func resetStub() {
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
        }
    }
}
