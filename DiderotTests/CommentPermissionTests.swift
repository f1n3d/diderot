import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Like the server's `validateCanComment`: editors, readers if the space allows it; nobody in the trash or signed out.
/// Resolving as the web offers it.
struct CommentPermissionTests {
    @Test func editorsAndReadersWhereTheSpaceAllowsIt() throws {
        let editor = try page(canEdit: true), reader = try page(canEdit: false), trashed = try page(canEdit: true, inTrash: true)
        let allows = try space(allowViewerComments: true), denies = try space(allowViewerComments: false)

        #expect(PageView.canComment(on: editor, in: denies, signedIn: true))
        #expect(PageView.canComment(on: editor, in: nil, signedIn: true))
        #expect(PageView.canComment(on: reader, in: allows, signedIn: true))
        #expect(!PageView.canComment(on: reader, in: denies, signedIn: true))
        #expect(!PageView.canComment(on: reader, in: nil, signedIn: true), "space not loaded yet")
        #expect(!PageView.canComment(on: trashed, in: allows, signedIn: true))
        #expect(!PageView.canComment(on: editor, in: allows, signedIn: false))
    }

    /// Docmost 0.98 resolves without a license and lists no `comment:resolution` any more; before, the license had to
    /// have it, as it must where the version isn't known (Docmost Cloud).
    @Test func resolvingIsFreeFromDocmost098() throws {
        let licensed: Entitlements = try decode(["tier": "enterprise", "features": ["comment:resolution"]])
        let unlicensed: Entitlements = try decode(["tier": "free", "features": []])
        for version in ["0.98.0", "v0.98.1", "0.99.0", "1.0.0"] {
            #expect(PageComments.canResolve(serverVersion: version, entitlements: unlicensed), "\(version)")
        }
        for version in ["0.96.4", "0.97.0", nil] {
            #expect(PageComments.canResolve(serverVersion: version, entitlements: licensed), "\(version ?? "nil")")
            #expect(!PageComments.canResolve(serverVersion: version, entitlements: unlicensed), "\(version ?? "nil")")
        }
    }

    private func page(canEdit: Bool, inTrash: Bool = false) throws -> Page {
        // A plain JSONDecoder reads dates as seconds since 2001.
        try decode(["id": "p", "spaceId": "s", "permissions": ["canEdit": .bool(canEdit)], "deletedAt": inTrash ? 0 : nil])
    }

    private func space(allowViewerComments: Bool) throws -> Space {
        try decode(["id": "s", "name": "Space", "slug": "space", "settings": ["comments": ["allowViewerComments": .bool(allowViewerComments)]]])
    }

    /// The models have no public initializers; build them as the server sends them.
    private func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }
}
