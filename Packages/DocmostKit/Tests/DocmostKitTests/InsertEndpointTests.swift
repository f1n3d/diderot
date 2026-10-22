import Foundation
import Testing
@testable import DocmostKit

/// Endpoints and nodes behind the slash commands: create a database (base), synced blocks, file attachments.
struct InsertEndpointTests {
    @Test func createBaseAsSubpage() throws {
        let table = Endpoints.Bases.create(parentPageId: "p1")
        #expect(table.path == "bases/create")
        #expect(try body(of: table) == ["parentPageId": "p1"])
        #expect(try body(of: Endpoints.Bases.create(parentPageId: "p1", template: "kanban")) == ["parentPageId": "p1", "template": "kanban"])
    }

    @Test func syncedBlockReferencesAndUnsync() throws {
        let references = Endpoints.Transclusions.references(sourcePageId: "s1", transclusionId: "t1")
        #expect(references.path == "pages/transclusion/references")
        #expect(try body(of: references) == ["sourcePageId": "s1", "transclusionId": "t1"])
        let unsync = Endpoints.Transclusions.unsyncReference(referencePageId: "r1", sourcePageId: "s1", transclusionId: "t1")
        #expect(unsync.path == "pages/transclusion/unsync-reference")
        #expect(try body(of: unsync) == ["referencePageId": "r1", "sourcePageId": "s1", "transclusionId": "t1"])
    }

    @Test func decodesReferencingPagesAndUnsyncedContent() throws {
        let usage = try JSONDecoder().decode(TransclusionReferences.self, from: Data("""
        {"source": {"id": "s1", "slugId": "abc", "title": "Quelle", "icon": "📌", "spaceId": "sp"},
         "references": [{"id": "r1", "slugId": "def", "title": null, "icon": null, "spaceId": "sp"}]}
        """.utf8))
        #expect(usage.source?.displayTitle == "Quelle")
        #expect(usage.references.map(\.id) == ["r1"])

        let unsync = try JSONDecoder().decode(TransclusionUnsync.self, from: Data("""
        {"content": {"type": "doc", "content": [
          {"type": "paragraph", "content": [{"type": "text", "text": "Eins"}]},
          {"type": "horizontalRule"}]}}
        """.utf8))
        #expect(unsync.nodes.map(\.type) == ["paragraph", "horizontalRule"])
        #expect(unsync.nodes.first?.plainText == "Eins")
    }

    @Test func fileAttachmentStaysACard() {
        let image = Attachment(id: "a1", fileName: "Bild.png", fileSize: 42, mimeType: "image/png")
        #expect(image.contentNode.type == "image")
        let card = image.contentNode(asAttachment: true)
        #expect(card.type == "attachment")
        #expect(card.string("url") == "/api/files/a1/Bild.png")
        #expect(card.string("mime") == "image/png")
        #expect(Attachment(id: "a2", fileName: "Plan.pdf", mimeType: "application/pdf").contentNode(asAttachment: true).type == "attachment")
    }
}
