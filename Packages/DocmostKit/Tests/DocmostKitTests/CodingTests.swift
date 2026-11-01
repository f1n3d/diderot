import Foundation
import Testing
@testable import DocmostKit

struct JSONValueTests {
    @Test func decodesMixedDocument() throws {
        let json = #"{"a":"x","n":1.5,"i":3,"b":true,"z":null,"l":[1,"two"],"o":{"k":"v"}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["a"]?.stringValue == "x")
        #expect(value["n"]?.doubleValue == 1.5)
        #expect(value["n"]?.intValue == nil)
        #expect(value["i"]?.intValue == 3)
        #expect(value["b"]?.boolValue == true)
        #expect(value["z"]?.isNull == true)
        #expect(value["l"]?[1]?.stringValue == "two")
        #expect(value["o"]?["k"]?.stringValue == "v")
        #expect(value["missing"] == nil)
    }

    @Test func roundTripsThroughEncoder() throws {
        let value: JSONValue = ["width": "50%", "level": 2, "attrs": ["checked": true, "icon": nil]]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    /// Values deeper than `maxDepth` decode as null: JSON as deep as JSONDecoder takes ran out of a thread's stack, as
    /// decoding goes a level deeper in it per level (code review R35).
    @Test func deepValuesDecodeAsNull() async throws {
        let data = Data((String(repeating: "[", count: 500) + String(repeating: "]", count: 500)).utf8)
        // Off the main thread, as the API client decodes, where a thread's stack is smaller.
        var value = try await Task.detached { try JSONDecoder().decode(JSONValue.self, from: data) }.value
        var depth = 0
        while case .array(let values) = value, let first = values.first {
            value = first
            depth += 1
        }
        #expect(depth == JSONValue.maxDepth)
        #expect(value == .null)
    }
}

struct DateParsingTests {
    @Test func parsesServerFormats() throws {
        let withMillis = try #require(JSONDecoding.parseDate("2026-10-08T09:23:11.123Z"))
        let withoutMillis = try #require(JSONDecoding.parseDate("2026-10-08T09:23:11Z"))
        #expect(abs(withMillis.timeIntervalSince(withoutMillis) - 0.123) < 0.001)
        #expect(JSONDecoding.parseDate("2026-10-08T09:23:11.123456") == nil)
        #expect(JSONDecoding.parseDate("not a date") == nil)
    }

    @Test func decoderUsesFallbackChain() throws {
        struct Row: Decodable { let a: Date; let b: Date? }
        let row = try JSONDecoding.makeDecoder().decode(Row.self, from: Data(#"{"a":"2026-01-02T03:04:05Z","b":null}"#.utf8))
        #expect(row.b == nil)
        #expect(Calendar(identifier: .gregorian).component(.year, from: row.a) == 2026)
    }
}

struct JWTClaimsTests {
    @Test func parsesClaims() throws {
        let token = try TestSupport.jwt(claims: [
            "sub": "user-1", "email": "a@b.c", "workspaceId": "ws-1", "type": "access", "sessionId": "s-1",
            "iat": 1_700_000_000, "exp": 1_700_086_400,
        ])
        let claims = try #require(JWTClaims(token: token))
        #expect(claims.isAccessToken)
        #expect(claims.isExpired(at: Date(timeIntervalSince1970: 1_700_086_401)))
        #expect(!claims.isExpired(at: Date(timeIntervalSince1970: 1_700_000_001)))
        #expect(claims.remainingLifetime(at: Date(timeIntervalSince1970: 1_700_000_000)) == 86_400)
    }

    @Test func rejectsGarbage() {
        #expect(JWTClaims(token: "nope") == nil)
        #expect(JWTClaims(token: "a.b.c") == nil)
    }

    @Test func parsesRealTokenFromFixture() throws {
        let token = try TestSupport.decodeFixture(Endpoints.Auth.CollabToken.self, "collab-token").token
        let claims = try #require(JWTClaims(token: token))
        #expect(claims.type == "collab")
        #expect(claims.expiresAt != nil)
    }
}

struct FixtureDecodingTests {
    @Test func entitlementsFixtureIsCommunity() throws {
        let entitlements = try TestSupport.decodeFixture(Entitlements.self, "entitlements")
        #expect(entitlements == .community)
        #expect(!entitlements.has("mfa"))
    }

    @Test func workspaceInfoFixtureDecodes() throws {
        let workspace = try TestSupport.decodeFixture(Workspace.self, "workspace-info")
        #expect(workspace.name == "Docmost Dev")
        #expect(workspace.id == "01a11a90-f71d-748b-b589-2d4dd2aa3240")
    }

    @Test func imageURLResolution() {
        let base = URL(string: "https://wiki.example.com")!
        #expect(ImageURL.resolve("abc.png", kind: .avatar, baseURL: base)?.absoluteString == "https://wiki.example.com/api/attachments/img/avatar/abc.png")
        #expect(ImageURL.resolve("https://cdn.example.com/x.png", kind: .avatar, baseURL: base)?.absoluteString == "https://cdn.example.com/x.png")
        #expect(ImageURL.resolve(nil, kind: .spaceIcon, baseURL: base) == nil)
        #expect(ImageURL.resolveContentMedia("/api/files/id1/cat.png", baseURL: base)?.absoluteString == "https://wiki.example.com/api/files/id1/cat.png")
        #expect(ImageURL.resolveContentMedia("/files/id1/cat.png", baseURL: base)?.absoluteString == "https://wiki.example.com/api/files/id1/cat.png")
    }
}

struct PaginatedTests {
    /// Follows the cursor and stops at the last page, whether it still names a cursor or says "more" without one.
    @Test(arguments: [PaginationMeta(hasNextPage: false, nextCursor: "c3"), PaginationMeta(hasNextPage: true, nextCursor: nil)])
    func allStopsAtTheLastPage(last: PaginationMeta) async throws {
        var cursors: [String?] = []
        let items = try await Paginated.all { cursor in
            cursors.append(cursor)
            try #require(cursors.count <= 2, "requested a page after the last one")
            return cursor == nil
                ? Paginated(items: [1, 2], meta: PaginationMeta(hasNextPage: true, nextCursor: "c2"))
                : Paginated(items: [3], meta: last)
        }
        #expect(items == [1, 2, 3])
        #expect(cursors == [nil, "c2"])
    }

    /// A server answering the same cursor again would page forever; paging stops at the first repeat.
    @Test func pagingStopsAtARepeatedCursor() async throws {
        var calls = 0
        let items = try await Paginated<String>.all { _ in
            calls += 1
            return Paginated(items: ["x"], meta: PaginationMeta(hasNextPage: true, nextCursor: "same"))
        }
        #expect(calls == 2 && items == ["x", "x"])
    }
}
