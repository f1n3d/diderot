import Foundation
import Testing
@testable import DocmostKit

/// Tests on `Tests/DocmostKitTests/Fixtures`; Tools/seed-fixtures.py imports `fixture-*.json` into the dev instance.
struct ContentParserTests {
    private func document(_ fixture: String) throws -> ContentDocument {
        let data = try TestSupport.fixture(fixture)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return ContentDocument(json: json["content"] ?? json["data"]?["content"])
    }

    @Test func parsesRealPageFromDev() throws {
        let doc = try document("page-info")
        #expect(doc.blocks.count == 5)
        guard case .heading(let level, let text) = doc.blocks[0].kind else { Issue.record("expected heading"); return }
        #expect(level == 1)
        #expect(text.plainText == "Handbuch – Abschnitt 1.1")
        guard case .bulletList(let items) = doc.blocks[3].kind else { Issue.record("expected bullet list"); return }
        #expect(items.count == 3)
        #expect(items[1].blocks.first?.plainText == "Zweiter Punkt mit fett und kursiv")
        guard case .blockquote(let quoted) = doc.blocks[4].kind else { Issue.record("expected blockquote"); return }
        #expect(quoted.first?.plainText == "Ein Zitat zum Abschluss.")
        // Real pages carry UniqueID attributes; nodes without one (here bulletList, blockquote) get path IDs.
        #expect(doc.blocks.map(\.id) == ["snsmuxjtbagy", "ifkedjfkipic", "nabcvqgtgina", "p3", "p4"])
    }

    /// Marks on an atom (a bold status, an inline comment only on a mention) reach the reader.
    @Test func keepsMarksOnAtoms() {
        let paragraph = PMNode(type: "paragraph", content: [
            PMNode(type: "status", attrs: ["text": "Done", "color": "green"], marks: [PMMark(type: "bold")]),
            PMNode(type: "mathInline", attrs: ["text": "x"]),
        ])
        var bold = InlineStyle()
        bold.bold = true
        #expect(ContentParser.inlines(of: paragraph) == [.marked(.status(text: "Done", color: "green"), bold), .mathInline("x")])
    }

    @Test func textAndMarks() throws {
        let doc = try document("fixture-text-and-marks")
        #expect(doc.blocks.count == 15)
        #expect(doc.anchors["fixtureheadone"] == "fixtureheadone")
        #expect(doc.anchors["fixtureheadtwo"] == "fixtureheadtwo")

        guard case .paragraph(let marks) = doc.blocks[1].kind else { Issue.record("expected paragraph"); return }
        let styles = marks.inlines.compactMap { inline -> InlineStyle? in
            if case .text(_, let style) = inline { return style }
            return nil
        }
        #expect(styles.contains { $0.bold })
        #expect(styles.contains { $0.italic })
        #expect(styles.contains { $0.underline })
        #expect(styles.contains { $0.strike })
        #expect(styles.contains { $0.code })
        #expect(styles.contains { $0.subscript })
        #expect(styles.contains { $0.superscript })
        #expect(marks.plainText.hasPrefix("Plain text with bold, italic"))

        guard case .paragraph(let combined) = doc.blocks[3].kind else { Issue.record("expected paragraph"); return }
        let combinedStyles = combined.inlines.compactMap { inline -> InlineStyle? in
            if case .text(_, let style) = inline { return style }
            return nil
        }
        #expect(combinedStyles.contains { $0.bold && $0.italic })
        #expect(combinedStyles.contains { $0.highlight?.colorName == "yellow" })
        #expect(combinedStyles.contains { $0.textColor == "#e03131" })
        #expect(combinedStyles.contains { $0.comment?.resolved == false })

        guard case .paragraph(let links) = doc.blocks[5].kind else { Issue.record("expected paragraph"); return }
        let linkStyles = links.inlines.compactMap { inline -> Link? in
            if case .text(_, let style) = inline { return style.link }
            return nil
        }
        #expect(linkStyles.map(\.href) == ["https://docmost.com", "/s/demo/p/{{PAGE_SLUG}}", "#fixtureheadtwo"])

        guard case .paragraph(let atoms) = doc.blocks[6].kind else { Issue.record("expected paragraph"); return }
        let mentions = atoms.inlines.compactMap { inline -> Mention? in
            if case .mention(let mention) = inline { return mention }
            return nil
        }
        #expect(mentions.map(\.entityType) == [.user, .page])
        #expect(atoms.inlines.contains(.status(text: "Blocked", color: "red")))
        #expect(atoms.inlines.contains(.mathInline("E = mc^2")))

        guard case .paragraph(let broken) = doc.blocks[7].kind else { Issue.record("expected paragraph"); return }
        #expect(broken.inlines.contains(.hardBreak))
        #expect(broken.plainText == "Line one\nline two after a hard break.")

        guard case .paragraph(let centered) = doc.blocks[8].kind else { Issue.record("expected paragraph"); return }
        #expect(centered.align == .center)
        guard case .paragraph(let indented) = doc.blocks[11].kind else { Issue.record("expected paragraph"); return }
        #expect(indented.indent == 2)
        guard case .paragraph(let empty) = doc.blocks[13].kind else { Issue.record("expected paragraph"); return }
        #expect(empty.inlines.isEmpty)
        // Blocks without an `id` get path IDs.
        #expect(doc.blocks[13].id == "p13")
    }

    @Test func lists() throws {
        let doc = try document("fixture-lists")
        guard case .bulletList(let bullets) = doc.blocks[1].kind else { Issue.record("expected bullet list"); return }
        #expect(bullets.count == 3)
        #expect(bullets[1].blocks.count == 2)
        guard case .bulletList(let nested) = bullets[1].blocks[1].kind else { Issue.record("expected nested list"); return }
        #expect(nested.count == 2)
        guard case .bulletList(let third) = nested[1].blocks[1].kind else { Issue.record("expected level 3"); return }
        #expect(third.first?.blocks.first?.plainText == "Nested level 3")
        #expect(bullets[2].blocks.count == 2)

        guard case .orderedList(let ordered) = doc.blocks[3].kind else { Issue.record("expected ordered list"); return }
        #expect(ordered.map(\.number) == [1, 2, 3])
        guard case .orderedList(let fromTen) = doc.blocks[5].kind else { Issue.record("expected ordered list"); return }
        #expect(fromTen.map(\.number) == [10, 11])

        guard case .taskList(let tasks) = doc.blocks[7].kind else { Issue.record("expected task list"); return }
        #expect(tasks.map(\.checked) == [true, false, false])
        guard case .taskList(let nestedTasks) = tasks[1].blocks[1].kind else { Issue.record("expected nested tasks"); return }
        #expect(nestedTasks.map(\.checked) == [false, true])

        guard case .bulletList(let mixed) = doc.blocks[9].kind else { Issue.record("expected mixed list"); return }
        let kinds = mixed[0].blocks.map { block -> String in
            switch block.kind {
            case .paragraph: return "paragraph"
            case .orderedList: return "orderedList"
            case .blockquote: return "blockquote"
            case .codeBlock: return "codeBlock"
            default: return "other"
            }
        }
        #expect(kinds == ["paragraph", "orderedList", "blockquote", "codeBlock"])
    }

    @Test func blocks() throws {
        let doc = try document("fixture-blocks")
        guard case .blockquote(let quote) = doc.blocks[1].kind else { Issue.record("expected blockquote"); return }
        #expect(quote.count == 3)

        let codeBlocks = doc.blocks.compactMap { block -> (String?, String)? in
            if case .codeBlock(let language, let code) = block.kind { return (language, code) }
            return nil
        }
        // The fifth code block ("text") sits inside the toggle block, not at the top level.
        #expect(codeBlocks.map(\.0) == ["swift", "json", nil, "mermaid"])
        #expect(codeBlocks[0].1.hasPrefix("struct Greeter {\n    let name: String"))

        let callouts = doc.blocks.compactMap { block -> (CalloutKind, String?)? in
            if case .callout(let kind, let icon, _) = block.kind { return (kind, icon) }
            return nil
        }
        #expect(callouts.map(\.0) == CalloutKind.allCases)
        #expect(callouts.last?.1 == "🔥")
        #expect(callouts.first?.1 == nil)

        let details = doc.blocks.compactMap { block -> (Bool, String, Int)? in
            if case .details(let open, let summary, let content) = block.kind { return (open, summary.plainText, content.count) }
            return nil
        }
        #expect(details.map(\.0) == [true, false])
        #expect(details.map(\.1) == ["Open toggle summary", "Closed toggle summary"])
        #expect(details.map(\.2) == [1, 2])

        #expect(doc.blocks.contains { if case .horizontalRule = $0.kind { return true } else { return false } })
        #expect(doc.blocks.contains { if case .pageBreak = $0.kind { return true } else { return false } })
        #expect(doc.blocks.contains { if case .mathBlock(let latex) = $0.kind { return latex.hasPrefix("\\int_0") } else { return false } })
    }

    @Test func tablesAndColumns() throws {
        let doc = try document("fixture-tables-and-columns")
        guard case .table(let simple) = doc.blocks[1].kind else { Issue.record("expected table"); return }
        #expect(simple.rows.count == 3)
        #expect(simple.columnCount == 3)
        #expect(simple.rows[0].cells.allSatisfy { $0.isHeader })
        #expect(simple.rows[1].cells[2].backgroundColorName == "green")

        guard case .table(let merged) = doc.blocks[3].kind else { Issue.record("expected table"); return }
        #expect(merged.rows[0].cells[0].colspan == 2)
        #expect(merged.rows[0].cells[0].colwidth == [150, 150])
        #expect(merged.columnCount == 3)

        guard case .columns(let columns, let weights) = doc.blocks[5].kind else { Issue.record("expected columns"); return }
        #expect(columns.count == 2)
        #expect(columns[1].count == 2)
        #expect(weights == [1, 1])
        // Width shares reach the reader too (layout "three_left_wide", widths 2/1/1).
        guard case .columns(let three, let threeWeights) = doc.blocks[7].kind else { Issue.record("expected columns"); return }
        #expect(three.count == 3)
        #expect(threeWeights == [2, 1, 1])
    }

    @Test func media() throws {
        // Like Tools/seed-fixtures.py, put a number in place of the quoted size placeholder.
        let text = try String(decoding: TestSupport.fixture("fixture-media"), as: UTF8.self)
            .replacingOccurrences(of: "\"{{FILE_SIZE}}\"", with: "41")
        let doc = ContentDocument(json: try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))["content"])

        let images = doc.blocks.compactMap { block -> ImageBlock? in
            if case .image(let image) = block.kind { return image }
            return nil
        }
        #expect(images.map(\.src) == ["{{IMAGE_SRC}}", "{{IMAGE_SRC}}", "{{IMAGE_SRC}}", "/api/files/00000000-0000-0000-0000-000000000000/missing.png"])
        #expect(images.map(\.alt) == ["Gradient test image", nil, nil, nil])
        #expect(images.map(\.width) == [nil, .points(240), .percent(50), .points(200)])
        #expect(images.map(\.aspectRatio) == [nil, 1.5, 1.5, 1])
        #expect(images.map(\.align) == [.center, .left, .right, .center])

        let media = doc.blocks.compactMap { block -> MediaBlock? in
            if case .media(let media) = block.kind { return media }
            return nil
        }
        try #require(media.map(\.kind) == [.attachment, .embed, .youtube, .embed, .video, .audio, .pdf, .drawio, .excalidraw])
        // `url` stands in for a missing `src`, `title` for a missing `name`.
        #expect(media[0].src == "{{FILE_URL}}")
        #expect(media[4].src == "/api/files/00000000-0000-0000-0000-000000000001/clip.mp4")
        #expect(media.map(\.name) == ["notes.txt", nil, nil, nil, nil, nil, "manual.pdf", "Architecture", "Sketch"])
        #expect(media.map(\.size) == [41, nil, nil, nil, nil, nil, nil, nil, nil])
        #expect(media[0].attachmentId == "{{FILE_ID}}")
        #expect(media[4].attachmentId == "00000000-0000-0000-0000-000000000001")
        #expect(media.map(\.provider) == [nil, "youtube", nil, "figma", nil, nil, nil, nil, nil])
    }

    @Test func advancedNodesAndFallbacks() throws {
        let doc = try document("fixture-advanced")
        #expect(doc.footnotes.count == 2)
        #expect(doc.anchors["fixturefnone"] == "fn:1")
        #expect(doc.anchors["fixturefntwo"] == "fn:2")
        #expect(!doc.blocks.contains { if case .unknown(let type, _) = $0.kind { return type == "footnotes" } else { return false } })

        guard case .paragraph(let refs) = doc.blocks[1].kind else { Issue.record("expected paragraph"); return }
        #expect(refs.inlines.contains(.footnoteReference(number: "1", dataId: "fixturefnone")))

        #expect(doc.blocks.contains { if case .subpages = $0.kind { return true } else { return false } })
        #expect(doc.anchors["fixturesyncsrc"] == "fixturesyncsrc")
        #expect(doc.blocks.contains {
            if case .transclusionReference(let source, let id) = $0.kind { return source == "{{SELF_ID}}" && id == "fixturesyncsrc" }
            return false
        })

        guard case .unknown(let type, let children) = doc.blocks[9].kind else { Issue.record("expected unknown block"); return }
        #expect(type == "fancyWidget")
        #expect(children.first?.plainText == "Children of an unknown block type should still render.")

        guard case .paragraph(let inlineUnknown) = doc.blocks[10].kind else { Issue.record("expected paragraph"); return }
        #expect(inlineUnknown.inlines.contains(.unknown(type: "sparkle")))
        #expect(inlineUnknown.plainText == "Unknown inline atom here:  end.")
    }

    /// Docmost 0.97: tabs (ids missing or taken get one from their position), integration links, sorted sub-pages.
    @Test func docmost097Content() {
        func tab(_ label: String, _ id: String?, _ text: String) -> JSONValue {
            var tab: [String: JSONValue] = ["type": "tab", "content": [
                ["type": "tabLabel", "content": label.isEmpty ? [] : [["type": "text", "text": .string(label)]]],
                ["type": "tabPanel", "content": [["type": "paragraph", "content": [["type": "text", "text": .string(text)]]]]],
            ]]
            if let id { tab["attrs"] = ["id": .string(id)] }
            return .object(tab)
        }
        let github = "https://github.com/o/r/issues/1"
        let json: JSONValue = ["type": "doc", "content": [
            ["type": "tabs", "content": [tab("One", "ta", "first"), tab("", nil, "second"), tab("Three", "ta", "third")]],
            ["type": "integrationCard", "attrs": ["url": .string(github), "provider": "github"]],
            ["type": "paragraph", "content": [
                ["type": "text", "text": "see "],
                ["type": "integrationMention", "attrs": ["url": "https://linear.app/o/issue/A-1", "provider": "linear"], "marks": [["type": "bold"]]],
                ["type": "text", "text": " and "],
                ["type": "text", "text": "the issue", "marks": [["type": "link", "attrs": ["href": .string(github), "integrationProvider": "github"]]]],
            ]],
            ["type": "subpages", "attrs": ["sortBy": "title-asc"]],
            ["type": "subpages"],
            ["type": "subpages", "attrs": ["sortBy": "upside-down"]],
        ]]
        let doc = ContentDocument(json: json)
        guard case .tabs(let tabs) = doc.blocks[0].kind else { Issue.record("expected tabs"); return }
        #expect(tabs.map(\.label) == ["One", "", "Three"])
        #expect(tabs.map(\.id) == ["ta", "t0.1", "t0.2"])
        #expect(tabs.map { $0.blocks.first?.plainText } == ["first", "second", "third"])
        #expect(doc.blocks[1].kind == .integrationCard(IntegrationLink(url: github, provider: "github")))

        guard case .paragraph(let text) = doc.blocks[2].kind else { Issue.record("expected paragraph"); return }
        var bold = InlineStyle()
        bold.bold = true
        #expect(text.inlines[1] == .marked(.integrationMention(IntegrationLink(url: "https://linear.app/o/issue/A-1", provider: "linear")), bold))
        guard case .text(_, let style) = text.inlines[3] else { Issue.record("expected linked text"); return }
        #expect(style.link == Link(href: github, integrationProvider: "github"))

        #expect(doc.blocks[3].kind == .subpages(sortBy: .titleAscending))
        #expect(doc.blocks[4].kind == .subpages(sortBy: .manual))
        #expect(doc.blocks[5].kind == .subpages(sortBy: .manual))
    }

    @Test func emptyAndStringContent() {
        #expect(ContentDocument(json: nil).isEmpty)
        #expect(ContentDocument(json: .string("# markdown")).isEmpty)
        #expect(ContentDocument(json: ["type": "doc"]).isEmpty)
    }

    @Test func parsesLargeDocumentQuickly() throws {
        var blocks: [JSONValue] = []
        for index in 0..<1000 {
            blocks.append(["type": "paragraph", "content": [["type": "text", "text": .string("Paragraph \(index) with ")], ["type": "text", "text": "bold", "marks": [["type": "bold"]]]]])
        }
        let json: JSONValue = ["type": "doc", "content": .array(blocks)]
        let started = ContinuousClock.now
        let doc = ContentDocument(json: json)
        let elapsed = started.duration(to: .now)
        #expect(doc.blocks.count == 1000)
        #expect(elapsed < .milliseconds(500))
    }
}
