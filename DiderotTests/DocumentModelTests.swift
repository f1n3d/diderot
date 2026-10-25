import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// Editor logic against a fake engine; the web engine's roundtrips are too fast and uneven for UI tests to hit.
struct DocumentModelTests {
    /// A character typed while the debounced save is out is still written on leaving the page or Undo (both flush).
    @Test(.timeLimit(.minutes(1))) func inputTypedDuringASaveIsFlushed() async throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Hello")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        engine.holdsNextSave = true
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)

        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        while engine.heldSave == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.activeText.append(AttributedString("?"))
        model.activeTextChanged()
        engine.heldSave?.resume()
        while engine.heldSave != nil { try await Task.sleep(for: .milliseconds(10)) }
        await model.flush()

        #expect(engine.saved.map(\.plainText) == ["Hello!", "Hello!?"])
    }

    /// Switching the list type before the debounced save drops it, as the new list has the text (pending, it would hide
    /// a collaborator's later edit and overwrite it on leaving); the item reopens with the text despite an older event.
    @Test(.timeLimit(.minutes(1))) func listTypeSwitchDropsPendingSave() async throws {
        func list(_ type: String, _ text: String) -> PMNode {
            PMNode(type: type, content: [PMNode(type: "listItem", content: [
                PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: text)]),
            ])])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list("bulletList", "Eins")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let item = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: item), node: item)

        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        engine.holdsNextSave = true
        let switching = Task { await model.convertList(itemPath: [0, 0], to: .orderedList) }
        while engine.heldSave == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.syncFromEngine()  // an event from before the switch
        engine.document = PMNode(type: "doc", content: [list("orderedList", "Eins!")])
        engine.heldSave?.resume()
        await switching.value
        #expect(model.active?.ref.path == [0, 0, 0])
        #expect(String(model.activeText.characters) == "Eins!")

        engine.document = PMNode(type: "doc", content: [list("orderedList", "Eins! Zwei")])  // a collaborator's edit
        model.syncFromEngine()
        await model.flush()  // leaving the page

        #expect(model.node(at: [0, 0, 0])?.plainText == "Eins! Zwei")
        #expect(engine.saved.map(\.plainText) == ["Eins!"])
    }

    /// Return mid-title in a toggle keeps the title whole and adds an empty paragraph atop the content, as on the web.
    @Test(.timeLimit(.minutes(1))) func returnInToggleTitleKeepsTitleWhole() async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "TiTel")])
        let content = PMNode(type: "detailsContent", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Inhalt")])])
        let details = PMNode(type: "details", attrs: ["open": .bool(true)], content: [title, content])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [details]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0, 0], node: title), node: title)

        model.activeText.insert(AttributedString("\n"), at: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 2))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.saved.map(\.plainText) == ["TiTel"])
        let insert = try #require(engine.inserted.first)
        #expect(insert.node == PMNode(type: "paragraph") && insert.target == .path([0, 1, 0]) && insert.position == .before)
    }

    /// A toggle without `open` is closed, as on the web: Return in its title adds a paragraph after the toggle,
    /// Backspace in the empty line after it goes to its title; neither enters its hidden content.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func toggleWithoutOpenIsClosed(backspace: Bool) async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")])
        let content = PMNode(type: "detailsContent", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Inhalt")])])
        let line = PMNode(type: "paragraph")
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "details", content: [title, content]), line]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()

        if backspace {
            model.activate(NodeRef(path: [1], node: line), node: line)
            #expect(model.backspaceAtStart())
            while model.active?.ref.path == [1] { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.active?.ref.path == [0, 0])
        } else {
            model.activate(NodeRef(path: [0, 0], node: title), node: title)
            model.activeText.append(AttributedString("\n"))
            model.activeTextChanged()
            while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            let insert = try #require(engine.inserted.first)
            #expect(insert.target == .path([0]) && insert.position == .after)
        }
    }

    /// Typing right before Return: the commit's document event can arrive while the new paragraph's insert is in
    /// flight; the cursor still goes into the new paragraph, not the block after it.
    @Test(.timeLimit(.minutes(1))) func returnRightAfterTypingFocusesNewParagraph() async throws {
        func paragraph(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", "Zwei")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let first = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: first), node: first)
        engine.whileInserting = {
            // The commit's document event is handled first; then the engine holds the new paragraph.
            engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins!"), paragraph("b", "Zwei")])
            model.syncFromEngine()
            engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins!"), paragraph("c", nil), paragraph("b", "Zwei")])
        }

        model.activeText.append(AttributedString("!\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        model.syncFromEngine()  // the insert's own document event

        #expect(engine.saved.map(\.plainText) == ["Eins!"])
        #expect(model.active?.ref == NodeRef(path: [1], id: "c"))
    }

    /// "/" and the toolbar share these rules: toggle titles and footnote text keep their type; a list item's first line
    /// can become a heading only if it's all the item holds (it then leaves the list).
    @Test func conversionTemplatesPerLocation() throws {
        func block(_ type: String) -> PMNode { PMNode(type: type, content: [PMNode(type: "text", text: "x")]) }
        let document = PMNode(type: "doc", content: [
            block("paragraph"),
            PMNode(type: "details", content: [block("detailsSummary"), PMNode(type: "detailsContent", content: [block("paragraph")])]),
            PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [block("paragraph"), block("paragraph")])]),
            PMNode(type: "table", content: [PMNode(type: "tableRow", content: [PMNode(type: "tableCell", content: [block("paragraph")])])]),
            PMNode(type: "footnotes", content: [PMNode(type: "footnote", content: [block("paragraph")])]),
            PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [block("paragraph")])]),
        ])
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: FakeDocumentEngine(document: document), readOnlyReason: nil)
        model.syncFromEngine()
        let text: [BlockTemplate] = [.paragraph, .heading1, .heading2, .heading3]
        let lists: [BlockTemplate] = [.bulletList, .orderedList, .taskList]
        let all = text + lists + [.quote, .callout, .toggle, .codeBlock]
        let expected: [(path: [Int], templates: [BlockTemplate])] = [
            ([0], all), ([1, 0], []), ([1, 1, 0], all), ([2, 0, 0], [.paragraph] + lists), ([2, 0, 1], text + lists),
            ([3, 0, 0, 0], text + lists), ([4, 0, 0], []), ([5, 0, 0], text + lists),
        ]
        for (path, templates) in expected {
            let node = try #require(model.node(at: path))
            model.activate(NodeRef(path: path, node: node), node: node)
            #expect(model.conversionTemplates == templates, "at \(path)")
        }
    }

    /// A pasted web link goes in as a link, as on the web (Tiptap's paste rule); over selected text it links that text;
    /// other text, other schemes and code blocks paste as usual.
    @Test func pastedLinkBecomesALink() throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Hallo Welt")])
        let code = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "let x = 1")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph, code]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let url = try #require(URL(string: "https://example.com/a"))

        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        #expect(model.pasteLink(" https://example.com/a\n"))
        #expect(String(model.activeText.characters) == "Hallo Welthttps://example.com/a")
        #expect(model.activeText.runs.contains { $0.link == url && String(model.activeText[$0.range].characters) == url.absoluteString })

        // Over "Welt": the word becomes the link.
        let start = model.activeText.characters.index(model.activeText.startIndex, offsetBy: 6)
        let end = model.activeText.characters.index(start, offsetBy: 4)
        model.activeSelection = AttributedTextSelection(range: start..<end)
        #expect(model.pasteLink(url.absoluteString))
        #expect(String(model.activeText.characters) == "Hallo Welthttps://example.com/a")
        #expect(model.activeText[start..<end].runs.allSatisfy { $0.link == url })

        #expect(!model.pasteLink("two words"))
        #expect(!model.pasteLink("mailto:someone@example.com"))
        model.activate(NodeRef(path: [1], node: code), node: code)
        #expect(!model.pasteLink(url.absoluteString))
    }

    /// A mention shown as a card splits its paragraph there, as on the web: the text before (without its trailing
    /// space), the card, the text after. No card in place of a list item's first line, in a table cell or a heading.
    @Test func mentionAsCardSplitsItsParagraph() async throws {
        let url = "https://github.com/o/r/issues/1"
        let mention = PMNode(type: "integrationMention", attrs: ["url": .string(url), "provider": "github"])
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Siehe "), mention, PMNode(type: "text", text: " danach")])
        let item = PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [PMNode(type: "paragraph", content: [mention])])])
        let cell = PMNode(type: "table", content: [PMNode(type: "tableRow", content: [
            PMNode(type: "tableCell", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "x "), mention])]),
        ])])
        let heading = PMNode(type: "heading", attrs: ["level": 2], content: [PMNode(type: "text", text: "x "), mention])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph, item, cell, heading]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        func target(_ path: [Int]) throws -> DocumentModel.MentionTarget {
            DocumentModel.MentionTarget(ref: NodeRef(path: path, node: try #require(model.node(at: path))), index: 0, url: url, provider: "github")
        }

        #expect(try !model.canShowAsCard(target([1, 0, 0])))
        #expect(try !model.canShowAsCard(target([2, 0, 0, 0])))
        #expect(try !model.canShowAsCard(target([3])))
        let first = try target([0])
        #expect(model.canShowAsCard(first))
        await model.showMention(first, as: .card)
        #expect(engine.replacedWith.last == [
            PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Siehe")]),
            PMNode(type: "integrationCard", attrs: ["url": .string(url), "provider": "github"]),
            PMNode(type: "paragraph", content: [PMNode(type: "text", text: "danach")]),
        ])
    }

    /// A pasted link to a page of this server becomes a mention of it, with the anchor, as on the web; a query such as
    /// `?commentId=` doesn't count, and a page that can't be found stays a link.
    @Test(.timeLimit(.minutes(1))) func pastedPageLinkBecomesAMention() async throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Hallo ")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.serverURL = URL(string: "https://wiki.example.com")
        model.currentUserId = "u1"
        let target = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p2","slugId":"Ab12","title":"Ziel"}"#.utf8))
        model.lookUpPage = { slugId in slugId == "Ab12" ? target : nil }
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        func inlines() -> [PMNode] { DocumentModel.inlines(from: model.activeText, base: .body) }

        #expect(model.pasteLink("https://wiki.example.com/s/demo/p/ziel-Ab12?commentId=c1#abschnitt"))
        while !inlines().contains(where: { $0.type == "mention" }) { try await Task.sleep(for: .milliseconds(10)) }
        let mention = try #require(inlines().first { $0.type == "mention" })
        #expect(mention.string("label") == "Ziel")
        #expect(mention.string("entityType") == "page")
        #expect(mention.string("entityId") == "p2")
        #expect(mention.string("slugId") == "Ab12")
        #expect(mention.string("anchorId") == "abschnitt")
        #expect(mention.string("creatorId") == "u1")

        let missing = "https://wiki.example.com/p/fehlt-Zz99"
        #expect(model.pasteLink(missing))
        while !model.activeText.runs.contains(where: { $0.link?.absoluteString == missing }) { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// "/bild" → Image drops the query before the picker opens, as on the web: gone on cancel, replaced by the uploads.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func mediaCommandRemovesSlashQuery(uploads: Bool) async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let paragraph = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        /// Waits up to a second for the `count`-th save, then delivers the engine's document event for it.
        func waitForSave(_ count: Int) async throws {
            for _ in 0..<100 where engine.saved.count < count { try await Task.sleep(for: .milliseconds(10)) }
            try #require(engine.saved.count >= count)
            engine.document = PMNode(type: "doc", content: Array(engine.saved.suffix(1)))
            model.syncFromEngine()
        }

        model.activeText.append(AttributedString("/bild"))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeTextChanged()
        try await waitForSave(1)  // typing's debounced save, before the command is picked
        model.perform(.image)
        try await waitForSave(2)
        if uploads {
            await model.insertUploads([Attachment(id: "i", fileName: "i.png", mimeType: "image/png")], to: model.takeMediaTarget())
            #expect(engine.replaced == [.id("a")])
        } else {
            model.cancelMedia()
        }
        #expect(engine.saved.map(\.plainText) == ["/bild", ""])
    }

    /// "File attachment" makes every upload an attachment card, even an image; Image embeds it.
    @Test(arguments: [false, true]) func uploadsFollowMediaCommand(attachment: Bool) async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()

        model.performAtEnd(attachment ? .attachment : .image)
        await model.insertUploads([Attachment(id: "i", fileName: "i.png", mimeType: "image/png")], to: model.takeMediaTarget())

        #expect(engine.inserted.map(\.node.type) == [attachment ? "attachment" : "image"])
    }

    /// A second media command during an upload keeps its own placement and kind; the first upload used to take them
    /// over and clear them.
    @Test func secondMediaCommandKeepsItsTarget() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()

        model.performAtEnd(.image)
        let first = model.takeMediaTarget()  // its picker closed, the upload runs
        model.performAtEnd(.attachment)
        await model.insertUploads([Attachment(id: "i", fileName: "i.png", mimeType: "image/png")], to: first)

        #expect(engine.inserted.map(\.node.type) == ["image"])
        #expect(model.pendingMedia?.action == .attachment)
    }

    /// A math block or embed from its sheet goes in only after the sheet has closed (switching editors while it slides
    /// away can leave a UIKit animation running), and only once: a later cancelled sheet adds nothing.
    @Test(arguments: [false, true]) func sheetBlockWaitsForDismissal(embed: Bool) async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let paragraph = try #require(model.node(at: [0]))
        let ref = NodeRef(path: [0], node: paragraph)
        model.activate(ref, node: paragraph)

        if embed {
            model.applyEmbed(provider: .youtube, link: "https://www.youtube.com/watch?v=x", slot: .insert(.replaceOrAfter(ref)))
        } else {
            model.applyMathBlock("x^2", slot: .insert(.replaceOrAfter(ref)))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.replaced.isEmpty)
        model.editorSheetDismissed()
        for _ in 0..<100 where engine.replaced.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        model.editorSheetDismissed()  // a later sheet, cancelled
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.replaced == [.id("a")])
    }

    /// Floating "+" → heading at the page end: an older document event arrives mid-insert, with the empty last line
    /// still at the heading's path. The heading still gets the cursor.
    @Test func endInsertFocusesNewBlockDespiteOlderEvent() async throws {
        func paragraph(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", nil)]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        engine.whileInserting = {
            model.syncFromEngine()  // an event from before the insert
            engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins"), PMNode(type: "heading", attrs: ["id": "c", "level": 2]), paragraph("b", nil)])
        }

        await model.insertTemplate(.heading2, placement: .end)
        model.syncFromEngine()  // the insert's own document event

        #expect(model.active?.ref == NodeRef(path: [1], id: "c"))
    }

    /// Floating "+" at the page end while a collaborator types in the empty last line, their text in the engine, not in
    /// this copy: a heading goes before that line, a paragraph continues in it with their text; neither replaces it.
    @Test(arguments: [BlockTemplate.heading2, .paragraph]) func endInsertKeepsLastLine(template: BlockTemplate) async throws {
        func paragraph(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", nil)]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", "Kollege")])

        await model.insertTemplate(template, placement: .end)

        #expect(engine.replaced.isEmpty)
        if template == .paragraph {
            #expect(engine.inserted.isEmpty)
            #expect(String(model.activeText.characters) == "Kollege")
        } else {
            let insert = try #require(engine.inserted.first)
            #expect(insert.target == .id("b") && insert.position == .before)
        }
    }

    /// "Text ▾" → synced block: an older document event arrives mid-wrap, with the block's text still where the wrapped
    /// block will be. The wrapped block still gets the cursor.
    @Test func syncedBlockWrapFocusesWrappedBlockDespiteOlderEvent() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        engine.whileInserting = {
            model.syncFromEngine()  // an event from before the wrap
            engine.document = PMNode(type: "doc", content: [PMNode(type: "transclusionSource", content: [paragraph])])
        }

        await model.wrapActiveInSyncedBlock()
        model.syncFromEngine()  // the wrap's own document event

        #expect(model.active?.ref == NodeRef(path: [0, 0], id: "a"))
    }

    /// Return in an empty list item: an older document event arrives while the paragraph after the list is inserted,
    /// with the next block still at its path. The new paragraph still gets the cursor.
    @Test(.timeLimit(.minutes(1))) func listExitFocusesNewParagraphDespiteOlderEvent() async throws {
        func paragraph(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let list = PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [paragraph("a", nil)])])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list, paragraph("b", "Zwei")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let item = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: item), node: item)
        engine.whileInserting = {
            model.syncFromEngine()  // an event from before the insert
            engine.document = PMNode(type: "doc", content: [list, paragraph("c", nil), paragraph("b", "Zwei")])
        }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        model.syncFromEngine()  // the insert's own document event

        #expect(model.active?.ref == NodeRef(path: [1], id: "c"))
    }

    /// Return on an empty line in a toggle inside a list item adds a line there; exiting the list would remove the item
    /// with the toggle.
    @Test(.timeLimit(.minutes(1))) func returnInToggleInListItemAddsLineThere() async throws {
        let line = PMNode(type: "paragraph")
        let details = PMNode(type: "details", attrs: ["open": .bool(true)], content: [
            PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")]),
            PMNode(type: "detailsContent", content: [line]),
        ])
        let item = PMNode(type: "listItem", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "x")]), details])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "bulletList", content: [item])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0, 0, 1, 1, 0], node: line), node: line)

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        let insert = try #require(engine.inserted.first)
        #expect(insert.node == PMNode(type: "paragraph") && insert.target == .path([0, 0, 1, 1, 0], type: "paragraph") && insert.position == .after)
    }

    /// Empty first line before a nested list: Return adds an item, Backspace does nothing; leaving the list there would
    /// remove the item with the nested list.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func emptyFirstLineKeepsNestedList(backspace: Bool) async throws {
        let line = PMNode(type: "paragraph")
        let nested = PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "y")])])])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [line, nested])])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)

        if backspace {
            #expect(model.backspaceAtStart())
            try await Task.sleep(for: .milliseconds(50))
            #expect(engine.inserted.isEmpty)
        } else {
            model.activeText.append(AttributedString("\n"))
            model.activeTextChanged()
            while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            let insert = try #require(engine.inserted.first)
            #expect(insert.node == PMNode(type: "listItem", content: [PMNode(type: "paragraph")]) && insert.target == .path([0, 0]) && insert.position == .after)
        }
    }

    /// Row below in a table: an older document event arrives while the new table is on its way, with the next row still
    /// at the new row's path. The new row still gets the cursor.
    @Test func tableRowFocusesNewRowDespiteOlderEvent() async throws {
        func table(_ rows: [(id: String, text: String?)]) -> PMNode {
            PMNode(type: "doc", content: [PMNode(type: "table", content: rows.map { row in
                PMNode(type: "tableRow", content: [PMNode(type: "tableCell", content: [
                    PMNode(type: "paragraph", attrs: ["id": .string(row.id)], content: row.text.map { [PMNode(type: "text", text: $0)] }),
                ])])
            })])
        }
        let engine = FakeDocumentEngine(document: table([("a", "Eins"), ("b", "Zwei")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let cell = try #require(model.node(at: [0, 0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0, 0], node: cell), node: cell)
        engine.whileInserting = {
            model.syncFromEngine()  // an event from before the new table
            engine.document = table([("a", "Eins"), ("c", nil), ("b", "Zwei")])
        }

        await model.editTable(.insertRowBelow)
        model.syncFromEngine()  // the new table's own document event

        #expect(model.active?.ref == NodeRef(path: [0, 1, 0, 0], id: "c"))
    }

    /// Floating "+" → Date when its paragraph at the end can't be inserted: the date must not turn up later in a block
    /// the cursor moves to (here the line after a Return).
    @Test(.timeLimit(.minutes(1))) func failedEndInsertDropsInlineCommand() async throws {
        func paragraph(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("a", "Eins")]))
        engine.failsNextInsert = true
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()

        model.performAtEnd(.date)
        while engine.failsNextInsert { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: first), node: first)
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", nil)]) }
        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(600))  // longer than an inline command waits for the editor's focus

        #expect(model.active?.ref == NodeRef(path: [1], id: "b"))
        #expect(String(model.activeText.characters).isEmpty)
        #expect(engine.saved.map(\.plainText) == ["Eins"])
    }

    /// A change the engine refuses silently (closed engine, block a collaborator just deleted): the page says it wasn't
    /// applied until the next change goes through.
    @Test func failedChangeShowsMessageUntilOneApplies() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        engine.failsNextInsert = true
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()

        await model.insertBlocks([PMNode(type: "horizontalRule")], placement: .end, focus: nil)
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
        await model.insertBlocks([PMNode(type: "horizontalRule")], placement: .end, focus: nil)
        #expect(model.errorMessage == nil)
    }

    /// An inline item lands at the cursor, also at the very start of a block: "/datum" typed before "Hallo", or the "+"
    /// menu with the cursor there. Up to 1.0 it went after the first character, as if each text still began with the
    /// invisible character the editor had before it became one editor for the whole page.
    @Test(arguments: [false, true]) func inlineItemAtTheStartOfABlock(fromSlash: Bool) throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Hallo")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        if fromSlash {
            model.activeText.insert(AttributedString("/datum"), at: model.activeText.startIndex)
            model.activeSelection = AttributedTextSelection(
                insertionPoint: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 6))
            model.activeTextChanged()
            #expect(model.slashQuery == "datum")
        } else {
            model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.startIndex)
        }
        model.perform(.date)
        #expect(String(model.activeText.characters) == Date.now.formatted(.dateTime.day().month(.wide).year()) + "Hallo")
    }

    /// A user mention shows as "@label": with the cursor right after it (its space deleted) the mention list stays
    /// closed, so a pick can't replace the mention; a typed "@" still opens the list.
    @Test func mentionListIgnoresExistingMention() throws {
        let mention = PMNode(type: "mention", attrs: ["id": "m", "label": "Grace", "entityType": "user", "entityId": "u"])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [mention, PMNode(type: "text", text: " ")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)

        model.activeText.characters.removeLast()  // Backspace over the space
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeTextChanged()
        #expect(model.mentionQuery == nil)

        model.activeText.append(AttributedString(" @Ed"))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeTextChanged()
        #expect(model.mentionQuery == "Ed")
    }

    /// Return inserts a paragraph that is gone again at once (a collaborator deleted it): a block that later lands at
    /// that place doesn't jump into editing.
    @Test(.timeLimit(.minutes(1))) func vanishedNewBlockLeavesNoCursorWish() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: first), node: first)
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [first]) }  // the new paragraph is gone

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        engine.document = PMNode(type: "doc", content: [first, PMNode(type: "paragraph", attrs: ["id": "x"])])
        model.syncFromEngine()

        #expect(model.active?.ref != NodeRef(path: [1], id: "x"))
    }

    /// A refused save of a block no longer edited drops its text: it doesn't stay over the saved block, nor go into
    /// another block that takes its place later. The error stays.
    @Test(.timeLimit(.minutes(1))) func refusedSaveOfALeftBlockDropsItsText() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: [PMNode(type: "text", text: "Zwei")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: first), node: first)
        model.activeText.append(AttributedString(" neu"))
        model.activeTextChanged()
        engine.refusesSaves = true
        model.activate(NodeRef(path: [1], node: second), node: second)
        while engine.saved.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.document.children.first?.plainText == "Eins")
        #expect(model.errorMessage != nil)
    }

    /// Return whose save is refused but whose new line applies keeps the error until a later save succeeds; the new
    /// line's success used to hide it at once.
    @Test(.timeLimit(.minutes(1))) func refusedSaveOnReturnKeepsTheError() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: first), node: first)
        engine.refusesSaves = true
        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.errorMessage != nil)

        engine.refusesSaves = false
        model.activeText.append(AttributedString("x"))
        model.activeTextChanged()
        await model.flush()
        #expect(model.errorMessage == nil)
    }

    /// Moving the page to the trash while its engine opens (after pull-to-refresh) closes it after that open; stopped
    /// beside the queue, the open ran afterwards and nothing closed it.
    @Test(.timeLimit(.minutes(1))) func trashWhileOpeningClosesTheEngineLast() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        engine.status = .idle
        model.resume()
        await model.suspend().value
        #expect(engine.lifecycle == ["open", "close"])
    }

    /// Going to the background keeps the unsent changes with the input typed last: iOS may end the app there.
    @Test(.timeLimit(.minutes(1))) func backgroundSaveCommitsInputFirst() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Hello")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        await model.saveUnsentChanges()
        #expect(engine.saved.map(\.plainText) == ["Hello!"])
        #expect(engine.lifecycle == ["save after 1"])
    }

    /// Input the engine hadn't saved when its web process ended goes in once the engine is back; it used to be lost.
    @Test(.timeLimit(.minutes(1))) func inputBeforeTheEngineEndedIsSavedWhenItReturns() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let document = PMNode(type: "doc", content: [first])
        let engine = FakeDocumentEngine(document: document)
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: first), node: first)
        model.activeText.append(AttributedString(" neu"))
        model.activeTextChanged()
        // The web process ends: the engine is closed and refuses the save on leaving the block.
        engine.document = nil
        engine.refusesSaves = true
        engine.onTerminated?()
        try await Task.sleep(for: .milliseconds(100))

        engine.refusesSaves = false
        engine.document = document
        model.syncFromEngine()
        while engine.saved.last?.plainText != "Eins neu" { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A refused live connection makes the page read-only with a message; it used to stay at "Connecting…".
    @Test func refusedLiveConnectionMakesThePageReadOnly() throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        #expect(model.isEditable)
        engine.onFailure?(.connectionRefused)
        #expect(!model.isEditable)
        #expect(model.errorMessage == String(localized: "The server refused the live connection. The page is read-only."))
    }

    /// The mention list follows the cursor: set elsewhere without typing, the list closes, and a pick from a list still
    /// showing replaces nothing.
    @Test func mentionListClosesWhenTheCursorMoves() throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Hallo")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeText.append(AttributedString(" @An"))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeTextChanged()
        #expect(model.mentionQuery == "An")
        let suggestion = MentionSuggestion(kind: .user, entityId: "u", title: "Ann", subtitle: nil, icon: nil, avatarUrl: nil, slugId: nil)
        let typed = model.activeText

        // Moved without the selection callback: the list still shows.
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 4))
        model.insertMention(suggestion)
        #expect(model.activeText == typed && model.mentionQuery == nil)

        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeSelectionChanged()
        #expect(model.mentionQuery == "An")
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.startIndex)
        model.activeSelectionChanged()
        #expect(model.mentionQuery == nil)
    }

    /// "@" or "/" typed right before a page mention, the cursor after the mention: the mention isn't a query, so no
    /// list opens whose pick would replace it.
    @Test(arguments: ["@", "/"]) func markBeforeMentionOpensNoList(mark: String) throws {
        let mention = PMNode(type: "mention", attrs: ["id": "m", "label": "Editor-Test", "entityType": "page", "entityId": "e"])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "see "), mention])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)

        let beforeMention = model.activeText.characters.index(model.activeText.startIndex, offsetBy: 4)  // "see "
        model.activeText.insert(AttributedString(mark), at: beforeMention)
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeTextChanged()
        #expect(model.mentionQuery == nil)
        #expect(model.slashQuery == nil)
    }

    /// The editor types with the selection's typing attributes, which carry on the link before the cursor: at a link's
    /// end typing continues outside it with the other formats, as on the web; inside the link it stays.
    @Test func typingAtTheEndOfALinkLeavesIt() throws {
        let link = PMMark(type: "link", attrs: ["href": "https://example.com"])
        let paragraph = PMNode(type: "paragraph", content: [
            PMNode(type: "text", marks: [PMMark(type: "bold"), link], text: "site"), PMNode(type: "text", text: " to "),
            PMNode(type: "text", marks: [link], text: "end"),
        ])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        let opened = model.activeText

        // Types "X" at a character offset and returns the marks it is saved with.
        func marks(typingAt offset: Int) throws -> [String] {
            model.activeText = opened
            model.activeSelection = AttributedTextSelection(insertionPoint: opened.characters.index(opened.startIndex, offsetBy: offset))
            model.activeSelectionChanged()
            model.activeText.replaceSelection(&model.activeSelection, withCharacters: "X")
            let saved = DocumentModel.inlines(from: model.activeText, base: .body)
            return try #require(saved.first { $0.text?.contains("X") == true }).marks?.map(\.type) ?? []
        }
        #expect(try marks(typingAt: 2) == ["bold", "link"])  // inside the link
        #expect(try marks(typingAt: 4) == ["bold"])  // at its end, before more text
        #expect(try marks(typingAt: 11) == [])  // at its end, at the end of the paragraph
    }

    /// No `type` (the server snapshot lacks schema defaults) or one the app doesn't know (newer server): both show as
    /// info, as on the web and in the reader, not as the gray "Default".
    @Test func calloutWithoutKnownTypeShowsInfo() throws {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: nil, readOnlyReason: nil)
        func kind(_ attrs: [String: JSONValue]?) -> CalloutKind {
            let callout = PMNode(type: "callout", attrs: attrs)
            return CalloutNodeView(model: model, node: callout, ref: NodeRef(path: [0], node: callout)).kind
        }
        #expect(kind(nil) == .info)
        #expect(kind(["type": "future"]) == .info)
        #expect(kind(["type": "default"]) == .default)
    }

    /// The heading hands its bold font to the model: Cmd-I in its editor (heading font plus italic, as probed in the
    /// editor) saves italic without a bold mark.
    @Test(.timeLimit(.minutes(1))) func headingItalicSavesNoBold() async throws {
        let heading = PMNode(type: "heading", attrs: ["level": 1], content: [PMNode(type: "text", text: "Titel")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [heading]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let ref = NodeRef(path: [0], node: heading)
        model.activate(ref, node: heading)
        let window = UIWindow(windowScene: try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.rootViewController = UIHostingController(rootView: TextNodeView(model: model, node: heading, ref: ref, isEditing: true))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        while model.activeFont != Font.title.bold() { try await Task.sleep(for: .milliseconds(10)) }

        model.activeText.font = Font.title.bold().italic()
        model.activeTextChanged()
        await model.flush()

        #expect(engine.saved.last?.children.first?.marks == [PMMark(type: "italic")])
    }

    /// A collaborator adds a block above the code block being edited; code blocks have no id, so its old path now names
    /// the divider: editing ends unsaved, since the save would replace the divider.
    @Test(.timeLimit(.minutes(1))) func codeBlockMovedByCollaboratorEndsEditingUnsaved() async throws {
        let divider = PMNode(type: "horizontalRule")
        let code = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "let x = 1")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [divider, code]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [1], node: code), node: code)

        model.activeCode += "2"
        model.activeCodeChanged()
        engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"]), divider, code])
        model.syncFromEngine()
        try await Task.sleep(for: .milliseconds(600))  // longer than a save waits for more input

        #expect(model.active == nil)
        #expect(engine.saved.isEmpty)
    }

    /// Backspace joins a list item to the one above, removing it once the cursor has moved. A collaborator's list
    /// arriving above meanwhile puts their item at its old path: that item stays, and the joined line goes by its id.
    @Test(.timeLimit(.minutes(1))) func joinedItemIsRemovedOnlyWhereItWas() async throws {
        func list(_ lines: [(id: String, text: String)]) -> PMNode {
            PMNode(type: "bulletList", content: lines.map { line in
                PMNode(type: "listItem", content: [PMNode(type: "paragraph", attrs: ["id": .string(line.id)], content: [PMNode(type: "text", text: line.text)])])
            })
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list([("a", "Eins"), ("b", "Zwei")])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [list([("x", "Ihre"), ("y", "Liste")]), list([("a", "EinsZwei"), ("b", "Zwei")])])
            model.syncFromEngine()
        }

        #expect(model.backspaceAtStart())
        while engine.saved.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))

        #expect(engine.saved.map(\.plainText) == ["EinsZwei"])
        #expect(engine.deleted == [.id("b")])
    }

    /// Return in an empty list item continues after the list and removes the item (here its whole list) once the cursor
    /// has moved, which with the page's one editor is right away. A collaborator's list arriving above afterwards stays.
    @Test(.timeLimit(.minutes(1))) func leftListIsRemovedOnlyWhereItWas() async throws {
        func list(_ id: String) -> PMNode {
            PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [PMNode(type: "paragraph", attrs: ["id": .string(id)])])])
        }
        let after = PMNode(type: "paragraph", attrs: ["id": "b"])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list("a")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let line = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [list("a"), after]) }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while model.active?.ref.id != "b" { try await Task.sleep(for: .milliseconds(10)) }
        while engine.deleted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.document = PMNode(type: "doc", content: [list("x"), after])
        model.syncFromEngine()
        try await Task.sleep(for: .milliseconds(200))

        #expect(engine.deleted == [.path([0], type: "bulletList")])
    }

    /// Return in an empty item in the middle of a list splits the list there, as the web does: the paragraph goes
    /// between the halves, and the item goes once that paragraph has focus.
    @Test(.timeLimit(.minutes(1))) func emptyMiddleItemSplitsTheList() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", nil), ("c", "Drei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        // The engine after the split and the insert.
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [
                Self.list([("a", "Eins"), ("b", nil)]), PMNode(type: "paragraph", attrs: ["id": "n"]), Self.list([("c", "Drei")]),
            ])
        }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.deleted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.splitAfter == [.path([0, 1], type: "listItem")])
        #expect(engine.inserted.map(\.position) == [.after] && engine.inserted.first?.target == .path([0], type: "bulletList"))
        #expect(model.active?.ref == NodeRef(path: [1], id: "n"))
        #expect(engine.deleted == [.path([0, 1], type: "listItem")])
    }

    /// Return or Backspace in an empty first item puts the paragraph before the list, as the web lifts the item there.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func emptyFirstItemGoesBeforeTheList(backspace: Bool) async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", nil), ("b", "Zwei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "n"]), Self.list([("a", nil), ("b", "Zwei")])])
        }

        if backspace {
            #expect(model.backspaceAtStart())
        } else {
            model.activeText.append(AttributedString("\n"))
            model.activeTextChanged()
        }
        while engine.deleted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.splitAfter.isEmpty)
        #expect(engine.inserted.map(\.position) == [.before] && engine.inserted.first?.target == .path([0], type: "bulletList"))
        #expect(model.active?.ref == NodeRef(path: [0], id: "n"))
        #expect(engine.deleted == [.path([1, 0], type: "listItem")])
    }

    /// "/Heading" in an item's only line takes the line out of the list as the heading, as on the web; here the last
    /// item, so after the list.
    @Test(.timeLimit(.minutes(1))) func headingTakesLineOutOfList() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", "Zwei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [
                Self.list([("a", "Eins"), ("b", "Zwei")]),
                PMNode(type: "heading", attrs: ["id": "h", "level": 2], content: [PMNode(type: "text", text: "Zwei")]),
            ])
        }

        model.convertActive(to: .heading2)
        while engine.deleted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        let insert = try #require(engine.inserted.first)
        #expect(insert.node == PMNode(type: "heading", attrs: ["level": 2], content: [PMNode(type: "text", text: "Zwei")]))
        #expect(insert.target == .path([0], type: "bulletList") && insert.position == .after)
        #expect(model.active?.ref == NodeRef(path: [1], id: "h"))
        #expect(engine.deleted == [.path([0, 1], type: "listItem")])
    }

    /// Return on an empty line in a quote (top level or in a list item), on a toggle's last line or on an item's last
    /// line below its first: as on the web, a paragraph continues outside, where the line is lifted to, and the line goes.
    @Test(.timeLimit(.minutes(1)), arguments: ["quote", "item", "toggle"]) func emptyLineLeavesItsContainer(kind: String) async throws {
        func line(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let new = line("n", nil)
        let (blocks, after, linePath, split, insertTarget, deleted): ([PMNode], [PMNode], [Int], [BlockTarget], BlockTarget, BlockTarget)
        switch kind {
        case "quote":
            let quote = PMNode(type: "blockquote", content: [line("a", "Zitat"), line("b", nil)])
            (blocks, after, linePath) = ([quote], [quote, new], [0, 1])
            (split, insertTarget, deleted) = ([], .path([0], type: "blockquote"), .path([0, 1], type: "paragraph"))
        case "item":
            let first = PMNode(type: "listItem", content: [line("a", "Eins"), line("b", nil)])
            let second = PMNode(type: "listItem", content: [line("c", "Zwei")])
            (blocks, linePath) = ([PMNode(type: "bulletList", content: [first, second])], [0, 0, 1])
            after = [PMNode(type: "bulletList", content: [first]), new, PMNode(type: "bulletList", content: [second])]
            (split, insertTarget, deleted) = ([.path([0, 0], type: "listItem")], .path([0], type: "bulletList"), .path([0, 0, 1], type: "paragraph"))
        default:
            let toggle = PMNode(type: "details", content: [
                PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")]),
                PMNode(type: "detailsContent", content: [line("a", "Inhalt"), line("b", nil)]),
            ])
            (blocks, after, linePath) = ([toggle], [toggle, new], [0, 1, 1])
            (split, insertTarget, deleted) = ([], .path([0], type: "details"), .path([0, 1, 1], type: "paragraph"))
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: blocks))
        let model = try Self.model(engine)
        let empty = try #require(model.node(at: linePath))
        model.activate(NodeRef(path: linePath, node: empty), node: empty)
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: after) }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.deleted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.splitAfter == split)
        #expect(engine.inserted.first?.target == insertTarget && engine.inserted.first?.position == .after)
        #expect(model.active?.ref == NodeRef(path: [after.firstIndex(of: new)!], id: "n"))
        #expect(engine.deleted == [deleted])
    }

    /// A bullet list of single-paragraph items (id, text).
    private static func list(_ items: [(String, String?)]) -> PMNode {
        PMNode(type: "bulletList", content: items.map { id, text in
            PMNode(type: "listItem", content: [PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })])
        })
    }

    private static func model(_ engine: FakeDocumentEngine) throws -> DocumentModel {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        return model
    }

    /// Unsync of a synced block embedded from another page: once the server answers, its content replaces it where it
    /// is now (a collaborator added a block above meanwhile); a second tap's late answer finds it gone.
    @Test func unsyncFindsTheEmbedAgain() async throws {
        let reference = PMNode(type: "transclusionReference", attrs: ["sourcePageId": "s", "transclusionId": "t"])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph, reference]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        let ref = NodeRef(path: [1], node: reference)
        let above = PMNode(type: "paragraph", attrs: ["id": "b"])
        let content = [PMNode(type: "paragraph", attrs: ["id": "c"], content: [PMNode(type: "text", text: "Inhalt")])]

        engine.document = PMNode(type: "doc", content: [above, paragraph, reference])
        model.syncFromEngine()
        await model.unsyncReference(reference, at: ref, content: content)
        engine.document = PMNode(type: "doc", content: [above, paragraph] + content)
        model.syncFromEngine()
        await model.unsyncReference(reference, at: ref, content: content)

        #expect(engine.replaced == [.path([2], type: "transclusionReference")])
    }

    /// iOS ends the engine's web process mid-edit: editing ends, the page goes read-only, and the engine reopens it.
    @Test(.timeLimit(.minutes(1))) func endedEngineOpensAgain() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let document = PMNode(type: "doc", content: [paragraph])
        let engine = FakeDocumentEngine(document: document)
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        model.syncFromEngine()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)

        // As the web engine does: it closes, then reports it.
        engine.status = .idle
        engine.document = nil
        engine.onTerminated?()
        #expect(model.active == nil)
        #expect(!model.isEditable)
        while engine.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.document = document
        model.syncFromEngine()

        #expect(engine.opened == ["p"])
        #expect(model.isEditable)
    }
}

/// Stand-in for the web engine: changes nothing and records what it is asked to open, save, insert, replace or delete.
final class FakeDocumentEngine: DocumentEngine {
    var status = EngineStatus.synced
    var document: PMNode?
    var participants: [EngineParticipant] = []
    var onFailure: (@MainActor (EngineFailure) -> Void)?
    var onTerminated: (@MainActor () -> Void)?
    private(set) var opened: [String] = []
    /// "open" and "close" in order.
    private(set) var lifecycle: [String] = []
    /// Blocks written with `replaceBlock(_:with:)`.
    private(set) var saved: [PMNode] = []
    /// Blocks added with `insertBlock` or `insertBlocks`.
    private(set) var inserted: [(node: PMNode, target: BlockTarget?, position: BlockInsertPosition)] = []
    /// Targets of `replaceBlock(_:withNodes:)`.
    private(set) var replaced: [BlockTarget] = []
    /// The blocks of each `replaceBlock(_:withNodes:)`.
    private(set) var replacedWith: [[PMNode]] = []
    private(set) var deleted: [BlockTarget] = []
    /// Children that `splitContainer(after:)` split their container after.
    private(set) var splitAfter: [BlockTarget] = []
    /// The next save waits until the test resumes `heldSave`, like a slow engine roundtrip.
    var holdsNextSave = false
    private(set) var heldSave: CheckedContinuation<Void, Never>?
    /// Runs mid-insert or mid-replace (saves too): the test changes `document` and delivers events there.
    var whileInserting: (() -> Void)?
    /// The next `insertBlocks` fails, like a closed engine.
    var failsNextInsert = false
    /// Saves fail, like a server refusing them.
    var refusesSaves = false

    init(document: PMNode) {
        self.document = document
    }

    func replaceBlock(_ target: BlockTarget, with node: PMNode) async -> Bool {
        saved.append(node)
        whileInserting?()
        if holdsNextSave {
            holdsNextSave = false
            await withCheckedContinuation { heldSave = $0 }
            heldSave = nil
        }
        return !refusesSaves
    }

    func open(pageId: String) async throws {
        opened.append(pageId)
        lifecycle.append("open")
    }
    func close() { lifecycle.append("close") }
    /// With the number of block saves before it.
    func saveUnsentChanges() async { lifecycle.append("save after \(saved.count)") }
    func currentDocument() async -> PMNode? { document }
    func replaceBlock(_ target: BlockTarget, withNodes nodes: [PMNode]) async -> Bool {
        replaced.append(target)
        replacedWith.append(nodes)
        whileInserting?()
        return true
    }
    func insertBlock(_ node: PMNode, relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> Bool {
        inserted.append((node, target, position))
        whileInserting?()
        return true
    }
    func insertBlocks(_ nodes: [PMNode], relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> Bool {
        if failsNextInsert {
            failsNextInsert = false
            return false
        }
        inserted += nodes.map { ($0, target, position) }
        whileInserting?()
        return true
    }
    func deleteBlock(_ target: BlockTarget) async -> Bool {
        deleted.append(target)
        return true
    }
    func moveBlock(_ target: BlockTarget, to destination: BlockTarget, position: BlockInsertPosition) async -> Bool { true }
    func splitContainer(after child: BlockTarget) async -> Bool {
        splitAfter.append(child)
        return true
    }
    func setAttributes(_ target: BlockTarget, attributes: [String: JSONValue]) async -> Bool { true }
    func undo() async {}
    func redo() async {}
}
