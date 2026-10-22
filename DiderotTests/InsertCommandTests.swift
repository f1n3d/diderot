import Foundation
import Testing
@testable import Diderot

/// Slash commands: the web editor's order, search, embed link checks, the web's clipboard format.
@MainActor
struct InsertCommandTests {
    @Test func listsTheWebCommandsInOrder() {
        let ids = InsertCommand.all.map(\.id)
        #expect(ids.first == "block-paragraph")
        #expect(ids.last == "embed-gsheets")
        for id in ["block-divider", "page-break", "footnote", "subpages", "synced-block", "columns-5", "mermaid", "drawio",
                   "excalidraw", "base", "kanban", "status", "emoji", "date", "time", "math-inline", "math-block"] {
            #expect(ids.contains(id), "\(id) missing")
        }
        // Web parity: divider after code block, date before time, columns after synced block.
        #expect(ids.contains(["block-codeBlock", "block-divider"]))
        #expect(ids.contains(["date", "time"]))
        #expect(ids.contains(["synced-block", "columns-2"]))
    }

    @Test func filtersByTitleAndSearchWords() {
        let ids = { (query: String) in InsertCommand.filtered(InsertCommand.all, query: query).map(\.id) }
        // English title matches as a subsequence; German search terms match as substrings.
        #expect(ids("trenn").first == "block-divider")
        #expect(ids("hr").contains("block-divider"))
        #expect(ids("unterseiten").first == "subpages")
        #expect(ids("youtube").contains("embed-youtube"))
        #expect(ids("fussn").contains("footnote"))
        #expect(ids("matheb").contains("math-block"))
        #expect(!ids("matheb").contains("math-inline"))
        // Title matches come first.
        #expect(ids("tab").first == "block-table")
        #expect(ids("xyzzy").isEmpty)
        #expect(ids("").count == InsertCommand.all.count)
    }

    @Test func classifiesCommands() {
        #expect(InsertCommand.date.isInline)
        #expect(InsertCommand.footnote.isInline)
        #expect(!InsertCommand.subpages.isInline)
        #expect(InsertCommand.block(.heading2).conversionTemplate == .heading2)
        #expect(InsertCommand.block(.table).conversionTemplate == nil)
        #expect(InsertCommand.block(.divider).conversionTemplate == nil)
    }

    @Test func validatesEmbedLinks() {
        #expect(EmbedProvider.youtube.validated("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(EmbedProvider.youtube.validated("youtu.be/dQw4w9WgXcQ") == "https://youtu.be/dQw4w9WgXcQ")
        // Accepted: the services' share and embed links.
        for (provider, link) in [
            (EmbedProvider.youtube, "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=10"),
            (.youtube, "https://www.youtube.com/embed/dQw4w9WgXcQ"),
            (.youtube, "https://www.youtube.com/shorts/abc123"),
            (.vimeo, "https://vimeo.com/123456"),
            (.vimeo, "https://player.vimeo.com/video/123456"),
            (.vimeo, "https://vimeo.com/channels/staffpicks/123456"),
            (.loom, "https://www.loom.com/share/abc123"),
            (.loom, "https://loom.com/embed/abc123"),
            (.figma, "https://www.figma.com/design/ABCDEFGHIJKLMNOPQRSTUV/Datei"),
            (.gsheets, "https://docs.google.com/spreadsheets/d/1abc_DEF/edit"),
            (.gdrive, "https://drive.google.com/file/d/1abc/view"),
            (.miro, "https://miro.com/app/board/uXjVabc=/"),
            (.miro, "https://www.miro.com/app/board/o9J_lXYZ=/?share_link_id=1"),
            (.typeform, "https://form.typeform.com/to/abc"),
            (.framer, "https://framer.com/embed/abc-def"),
            (.airtable, "https://airtable.com/appXYZ/shr123"),
        ] {
            #expect(provider.validated(link) == link, "\(provider): \(link)")
        }
        // Refused: other services, other pages of the service, wrong forms.
        for (provider, link) in [
            (EmbedProvider.youtube, "https://example.com/video"),
            (.youtube, "https://www.youtube.com/channel/UCxyz"),
            (.youtube, "https://www.youtube.com/"),
            (.vimeo, "https://vimeo.com/user/abc"),
            (.vimeo, "http://vimeo.com/123456"),
            (.loom, "https://www.loom.com/looms/videos"),
            (.figma, "https://www.figma.com/design/kurz"),
            (.figma, "https://www.figma.com/community/file/ABCDEFGHIJKLMNOPQRSTUV"),
            (.gsheets, "https://docs.google.com/document/d/1abc/edit"),
            (.gdrive, "https://drive.google.com/drive/folders/1abc"),
            (.miro, "https://miro.com/app/board/uXjVabc/"),
            (.typeform, "https://typeform.com/to/abc"),
            (.framer, "https://framer.com/projects/abc"),
            (.airtable, "http://airtable.com/appXYZ/shr123"),
            (.airtable, "https://airtable.com/a/b"),
        ] {
            #expect(provider.validated(link) == nil, "\(provider): \(link)")
        }
        // Iframe: any link, but only http(s).
        #expect(EmbedProvider.iframe.validated("example.com/widget") == "https://example.com/widget")
        #expect(EmbedProvider.iframe.validated("javascript:alert(1)") == nil)
        #expect(EmbedProvider.iframe.validated("kein link") == nil)
        #expect(EmbedProvider.iframe.validated("   ") == nil)
    }

    @Test func readsSyncedBlocksInTheWebFormat() {
        let reference = SyncedBlockClipboard.Reference(sourcePageId: "page-1", transclusionId: "abcdefghijkl")
        let html = SyncedBlockClipboard.html(for: reference)
        #expect(html == #"<div data-type="transclusionReference" data-source-page-id="page-1" data-transclusion-id="abcdefghijkl"></div>"#)
        #expect(SyncedBlockClipboard.parse(html) == reference)
        #expect(SyncedBlockClipboard.parse("<meta charset='utf-8'>" + html) == reference)
        #expect(SyncedBlockClipboard.parse("<p>Nur Text</p>") == nil)
        #expect(SyncedBlockClipboard.parse(#"<div data-type="transclusionReference"></div>"#) == nil)
    }

    @Test func atomLinksRoundTrip() throws {
        let url = try #require(AtomLink.url(block: "path:3.0", type: "status", index: 2))
        let parsed = try #require(AtomLink.parse(url))
        #expect(parsed.block == "path:3.0")
        #expect(parsed.type == "status")
        #expect(parsed.index == 2)
        #expect(AtomLink.parse(URL(string: "https://example.com")!) == nil)
    }
}
