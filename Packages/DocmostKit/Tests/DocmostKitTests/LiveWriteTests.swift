import Foundation
import Testing
@testable import DocmostKit

/// Writes to the dev instance (opt-in like `LiveAPITests`): creates a test page in "Demo", edits, comments, cleans up.
@Suite(.serialized, .enabled(if: LiveEnvironment.isConfigured))
struct LiveWriteTests {
    @Test func createUpdateAppendTrashRestoreAndComment() async throws {
        let client = try await LiveSession.shared.client()
        let space = try await client.send(Endpoints.Spaces.info(spaceId: "demo"))

        // Creating from Markdown produces the content and the Y.Doc together.
        let created = try await client.send(Endpoints.Pages.create(
            spaceId: space.id, title: "Live test \(Int(Date().timeIntervalSince1970))", icon: "🧪", markdown: "# Heading\n\nFirst paragraph."
        ))
        // For failed runs; after the cleanup at the end it finds nothing to delete.
        defer { _ = try? await client.send(Endpoints.Pages.delete(pageId: created.id, permanently: true)) }
        #expect(created.icon == "🧪")
        // The create response has no content; only `pages/info` returns the document.
        let createdInfo = try await client.send(Endpoints.Pages.info(pageId: created.id))
        #expect(ContentDocument(json: createdInfo.content).blocks.count == 2)

        // Change title/icon (not part of the Y.Doc).
        let renamed = try await client.send(Endpoints.Pages.update(pageId: created.id, title: "Live test renamed", icon: "✅"))
        #expect(renamed.title == "Live test renamed")
        #expect(renamed.icon == "✅")

        // Append via Yjs (needs active Redis sync). The response holds the content as Markdown, the requested format;
        // `pages/info` shows the new block immediately.
        let appended = try await client.send(Endpoints.Pages.appendMarkdown(pageId: created.id, "Appended note with **bold**."))
        #expect(appended.content?.stringValue?.contains("Appended note with **bold**.") == true)
        let appendedInfo = try await client.send(Endpoints.Pages.info(pageId: created.id))
        let appendedDocument = ContentDocument(json: appendedInfo.content)
        #expect(appendedDocument.blocks.count == 3)
        #expect(appendedDocument.blocks.last?.plainText == "Appended note with bold.")

        let comment = try await client.send(try Endpoints.Comments.create(pageId: created.id, text: "Live comment"))
        let reply = try await client.send(try Endpoints.Comments.create(pageId: created.id, text: "Live reply", parentCommentId: comment.id))
        #expect(reply.parentCommentId == comment.id)
        let comments = try await client.send(Endpoints.Comments.list(pageId: created.id))
        #expect(comments.items.count == 2)
        _ = try await client.send(Endpoints.Comments.delete(commentId: reply.id))

        _ = try await client.send(Endpoints.Pages.delete(pageId: created.id))
        let trashed = try await client.send(Endpoints.Pages.info(pageId: created.id))
        #expect(trashed.isInTrash)
        let restored = try await client.send(Endpoints.Pages.restore(pageId: created.id))
        #expect(!restored.isInTrash)

        // Cleanup: permanent delete needs space admin.
        _ = try await client.send(Endpoints.Pages.delete(pageId: created.id, permanently: true))
        await #expect(throws: APIError.self) {
            try await client.send(Endpoints.Pages.info(pageId: created.id))
        }
    }
}
