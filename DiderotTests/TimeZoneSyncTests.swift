import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The user's time zone (Docmost 0.98) follows the device's, as the web sets it from the browser's on each load.
    @Suite struct TimeZoneSync: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A server that keeps another zone gets the device's once while the app runs; one that keeps it gets nothing.
        /// The user keeps the test machine's zone, so the sync after signing in sends nothing of its own.
        @Test func anotherZoneIsSentOnce() async throws {
            let kept = TimeZone.current
            let session = try await signedIn(version: "0.98.0", keeps: kept.identifier)
            let ready = try #require(session.ready)
            let other = try #require(TimeZone(identifier: kept.identifier == "Asia/Tokyo" ? "Europe/Berlin" : "Asia/Tokyo"))
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.syncTimeZone(of: ready, zone: other)
            await session.syncTimeZone(of: ready, zone: other)
            #expect(updates() == 1)
            await session.syncTimeZone(of: ready, zone: kept)
            #expect(updates() == 1)
            await removeCaches()
        }

        /// Docmost keeps the zone with each user: another user signing in on that server while the app runs gets the
        /// device's zone as well. Kept once per server, it went only to the first user there until the next launch.
        @Test func anotherUserThereGetsTheirOwn() async throws {
            let kept = TimeZone.current
            let session = try await signedIn(version: "0.98.0", keeps: kept.identifier)
            let other = try #require(TimeZone(identifier: kept.identifier == "Asia/Tokyo" ? "Europe/Berlin" : "Asia/Tokyo"))
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.syncTimeZone(of: try #require(session.ready), zone: other)
            #expect(updates() == 1)
            // u1's session ends there, and u2 signs in through the in-app browser, also in the test machine's zone.
            session.handleUnauthorized()
            let server = try #require(session.server)
            StubURLProtocol.body.withLock { $0 = Self.answer(user: "u2", version: "0.98.0", keeps: kept.identifier) }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            let payload = Data(#"{"type":"access","exp":4102444800}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            try await session.signIn(withToken: "e30.\(payload).sig", at: server)
            let second = try #require(session.ready)
            try #require(second.currentUser.user.id == "u2" && second.hasDocmost098Features)
            await session.syncTimeZone(of: second, zone: other)
            #expect(updates() == 2, "u2 got no zone of their own")
            await removeCaches()
        }

        /// Older servers know no time zone of a user (0.97 refuses the field), so nothing goes there.
        @Test func olderServersGetNone() async throws {
            let session = try await signedIn(version: "0.97.0", keeps: nil)
            let ready = try #require(session.ready)
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.syncTimeZone(of: ready, zone: try #require(TimeZone(identifier: "Europe/Berlin")))
            #expect(updates() == 0)
            await removeCaches()
        }

        @Test func updateSendsTheZoneAlone() throws {
            let body = try JSONEncoder().encode(Endpoints.Users.TimeZoneBody(timezone: "Europe/Berlin"))
            #expect(String(decoding: body, as: UTF8.self) == #"{"timezone":"Europe\/Berlin"}"#)
        }

        /// Signed in to a on Docmost `version`, whose user keeps the zone `keeps`.
        private func signedIn(version: String, keeps zone: String?) async throws -> AppSession {
            StubURLProtocol.body.withLock { $0 = Self.answer(user: "u1", version: version, keeps: zone) }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            let session = try await sessionOnA()
            try #require(session.ready?.serverVersion == version && session.ready?.currentUser.user.timezone == zone)
            return session
        }

        /// One answer for users/me, workspace/entitlements and version alike: `user` on Docmost `version`, keeping the
        /// zone `zone`.
        private static func answer(user: String, version: String, keeps zone: String?) -> String {
            let timezone = zone.map { #", "timezone": "\#($0)""# } ?? ""
            return #"{"data": {"user": {"id": "\#(user)", "email": "\#(user)@example.com"\#(timezone)}, "workspace": {"id": "w1", "name": "Docs"}, "currentVersion": "\#(version)", "tier": "free", "features": []}}"#
        }

        private func updates() -> Int {
            StubURLProtocol.requests.withLock { $0 }.filter { $0 == "a.example.com/api/users/update" }.count
        }
    }
}
