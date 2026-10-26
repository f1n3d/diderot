import Foundation
import Testing
@testable import DocmostKit

struct ReaderFixtureTests {
    @Test func commentsWithReplyAndInlineSelection() throws {
        let comments = try TestSupport.decodeFixture(Paginated<PageComment>.self, "comments")
        #expect(comments.items.count == 3)
        let topLevel = comments.items.filter { !$0.isReply }
        let replies = comments.items.filter(\.isReply)
        #expect(topLevel.count == 2)
        #expect(replies.count == 1)
        #expect(replies.first?.parentCommentId == topLevel.first?.id)

        let inline = try #require(comments.items.first { $0.isInline })
        #expect(inline.selection == "Plain text with bold")
        #expect(!inline.isResolved)
        #expect(inline.creator?.name == "Dev Admin")

        let document = ContentDocument(json: topLevel.first?.content)
        #expect(document.blocks.count == 1)
        #expect(document.blocks.first?.plainText == "First page-level comment with bold")
    }

    @Test func historyListAndDetail() throws {
        let history = try TestSupport.decodeFixture(Paginated<PageHistoryEntry>.self, "page-history")
        #expect(history.items.count == 1)
        let entry = try #require(history.items.first)
        #expect(entry.displayTitle == "Fixture: Text & Marks")
        #expect(entry.lastUpdatedBy?.name == "Dev Admin")
        #expect(entry.content == nil)

        let detail = try TestSupport.decodeFixture(PageHistoryEntry.self, "page-history-info")
        #expect(detail.id == entry.id)
        let document = ContentDocument(json: detail.content)
        #expect(document.blocks.count == 15)
    }

    /// Docmost 0.96's list of a page's files: newest first, with who uploaded them and when.
    @Test func pageAttachmentsWithUploader() throws {
        let attachments = try TestSupport.decodeFixture(Paginated<DocmostKit.Attachment>.self, "page-attachments")
        #expect(attachments.items.count == 2)
        #expect(attachments.meta.hasNextPage)
        let newest = try #require(attachments.items.first)
        #expect(newest.fileName == "Bild-20261023-191048.jpeg")
        #expect(newest.fileSize == 9482)
        #expect(newest.isImage)
        #expect(newest.creator?.name == "Dev Admin")
        let createdAt = try #require(newest.createdAt)
        #expect(createdAt > (attachments.items.last?.createdAt ?? .distantFuture))
        #expect(newest.fileURLPath == "/api/files/01a169be-693a-746b-b8ee-df5955f261b3/Bild-20261023-191048.jpeg")
    }

    /// Templates (Enterprise feature `templates`): the list leaves the content out, `templates/info` brings it.
    @Test func templatesListAndInfo() throws {
        let templates = try TestSupport.decodeFixture(Paginated<PageTemplate>.self, "templates")
        #expect(templates.items.map(\.displayTitle) == ["Besprechung", "Projekt"])
        let global = try #require(templates.items.first)
        #expect(global.spaceId == nil)
        #expect(global.icon == "📝")
        #expect(global.description == "Notizen einer Besprechung")
        #expect(global.content == nil)
        #expect(templates.items.last?.spaceId != nil)

        let info = try TestSupport.decodeFixture(PageTemplate.self, "template-info")
        #expect(info.id == global.id)
        let document = ContentDocument(json: info.content)
        #expect(document.blocks.count == 2)
        #expect(document.blocks.first?.plainText == "Agenda")
    }

    @Test func transclusionLookupStatuses() throws {
        let lookup = try TestSupport.decodeFixture(TransclusionLookup.self, "transclusion-lookup")
        #expect(lookup.items.count == 2)
        let found = try #require(lookup.items.first { $0.status == nil })
        let document = ContentDocument(json: found.content)
        #expect(document.blocks.first?.plainText == "This paragraph is a synced block source.")
        let missing = try #require(lookup.items.first { $0.status != nil })
        #expect(missing.status == "not_found")
        #expect(missing.content == nil)
    }
}
