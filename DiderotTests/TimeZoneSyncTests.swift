import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The user's time zone (Docmost 0.98) follows the device's, as the web sets it from the browser's on each load.
    @Suite struct TimeZoneSync: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A server that keeps another zone gets the device's once while the app runs; one that keeps it gets nothing.
        @Test func anotherZoneIsSentOnce() async throws {
            let session = try await signedIn(version: "0.98.0", keeps: "America/New_York")
            let ready = try #require(session.ready)
            let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
            StubURLProtocol.requests.withLock { $0 = [] }
            await session.syncTimeZone(of: ready, zone: berlin)
            await session.syncTimeZone(of: ready, zone: berlin)
            #expect(updates() == 1)
            await session.syncTimeZone(of: ready, zone: try #require(TimeZone(identifier: "America/New_York")))
            #expect(updates() == 1)
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
            let timezone = zone.map { #", "timezone": "\#($0)""# } ?? ""
            // One answer for users/me, workspace/entitlements and version alike.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com"\#(timezone)}, "workspace": {"id": "w1", "name": "Docs"}, "currentVersion": "\#(version)", "tier": "free", "features": []}}"#
            }
            defer { StubURLProtocol.body.withLock { $0 = nil } }
            let session = try await sessionOnA()
            try #require(session.ready?.serverVersion == version && session.ready?.currentUser.user.timezone == zone)
            return session
        }

        private func updates() -> Int {
            StubURLProtocol.requests.withLock { $0 }.filter { $0 == "a.example.com/api/users/update" }.count
        }
    }
}
