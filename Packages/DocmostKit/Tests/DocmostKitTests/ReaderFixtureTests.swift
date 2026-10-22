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
