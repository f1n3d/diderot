import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Exports turned off (license feature `export:controls`, Docmost 0.98), read as the web reads them: the workspace's
/// setting first, then the space's.
struct ExportPolicyTests {
    @Test func workspaceComesBeforeSpace() throws {
        let off: Workspace = try Self.decode(["id": "w", "name": "W", "settings": ["export": ["disabled": true]]])
        let on: Workspace = try Self.decode(["id": "w", "name": "W"])
        let closed: Space = try Self.decode(["id": "s", "name": "S", "slug": "s", "settings": ["export": ["disabled": true]]])
        let open: Space = try Self.decode(["id": "s", "name": "S", "slug": "s", "settings": ["comments": ["allowViewerComments": true]]])
        let workspaceOff = String(localized: "Export has been disabled at the workspace level.")
        #expect(ExportPolicy.offReason(workspace: off, space: open) == workspaceOff)
        #expect(ExportPolicy.offReason(workspace: off, space: closed) == workspaceOff)
        #expect(ExportPolicy.offReason(workspace: on, space: closed) == String(localized: "Export has been disabled for this space."))
        #expect(ExportPolicy.offReason(workspace: on, space: open) == nil)
        #expect(ExportPolicy.offReason(workspace: nil, space: nil) == nil)
    }

    /// `users/me` as Docmost 0.98 answers it, settings and all; older answers without them still decode.
    @Test func currentUserBringsTheWorkspacesSettings() throws {
        let json = #"{"user": {"id": "u1", "name": "Alex", "email": "alex@example.com"}, "workspace": {"id": "w", "name": "W", "settings": {"export": {"disabled": true}, "ai": {"search": false}}}}"#
        let user = try JSONDecoder().decode(CurrentUser.self, from: Data(json.utf8))
        #expect(user.workspace.settings?["export"]?["disabled"]?.boolValue == true)
        let older = try JSONDecoder().decode(CurrentUser.self, from: Data(#"{"user": {"id": "u1", "name": "Alex", "email": "a@b.c"}, "workspace": {"id": "w", "name": "W"}}"#.utf8))
        #expect(older.workspace.settings == nil)
    }

    private static func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }
}
