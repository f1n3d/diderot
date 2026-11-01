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
        engine.sendDocument()
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

    /// "Get started with" fills only a blank page (one empty line, as the web's `editor.isEmpty`): a template's blocks
    /// replace that line; on a page someone typed into meanwhile nothing changes.
    @Test func templateFillsOnlyABlankPage() async throws {
        let template = [PMNode(type: "heading", attrs: ["level": 2], content: [PMNode(type: "text", text: "Agenda")]),
                        PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Punkt")])]
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        #expect(model.isBlank)
        #expect(await model.fill(with: template))
        #expect(engine.replaced == [.path([0], type: "paragraph")])
        #expect(engine.replacedWith == [template])

        engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "x")])])
        engine.sendDocument()
        #expect(!model.isBlank)
        #expect(await model.fill(with: template) == false)
        #expect(engine.replacedWith.count == 1)
    }

    /// Switching the list type with input pending: the input goes first, as typing sends it (with its base, so a
    /// collaborator's edit of the item stays), and the new list is built from the engine's document after it. Nothing
    /// stays pending (it would hide a collaborator's later edit and overwrite it on leaving), and the item reopens with
    /// the text despite older events.
    @Test(.timeLimit(.minutes(1))) func listTypeSwitchSendsPendingInputFirst() async throws {
        func list(_ type: String, _ text: String) -> PMNode {
            PMNode(type: type, content: [PMNode(type: "listItem", content: [
                PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: text)]),
            ])])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list("bulletList", "Eins")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let item = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: item), node: item)

        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        engine.whileInserting = {
            engine.sendDocument()  // an event from before the change
            let saved = engine.saved.last
            engine.document = PMNode(type: "doc", content: [saved?.type == "paragraph" ? list("bulletList", "Eins!") : saved].compactMap { $0 })
        }
        await model.convertList(itemPath: [0, 0], to: .orderedList)
        #expect(engine.saved.map(\.type) == ["paragraph", "orderedList"])
        #expect(engine.bases.first??.plainText == "Eins")
        #expect(engine.expectations.last == list("bulletList", "Eins!"))
        #expect(model.active?.ref.path == [0, 0, 0])
        #expect(String(model.activeText.characters) == "Eins!")

        engine.whileInserting = nil
        engine.document = PMNode(type: "doc", content: [list("orderedList", "Eins! Zwei")])  // a collaborator's edit
        engine.sendDocument()
        await model.flush()  // leaving the page

        #expect(model.node(at: [0, 0, 0])?.plainText == "Eins! Zwei")
        #expect(engine.saved.count == 2)
    }

    /// Return mid-title in a toggle keeps the title whole and adds an empty paragraph atop the content, as on the web.
    @Test(.timeLimit(.minutes(1))) func returnInToggleTitleKeepsTitleWhole() async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "TiTel")])
        let content = PMNode(type: "detailsContent", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Inhalt")])])
        let details = PMNode(type: "details", attrs: ["open": .bool(true)], content: [title, content])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [details]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
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
        engine.sendDocument()

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
        engine.sendDocument()
        let first = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: first), node: first)
        engine.whileInserting = {
            // The commit's document event is handled first; then the engine holds the new paragraph.
            engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins!"), paragraph("b", "Zwei")])
            engine.sendDocument()
            engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins!"), paragraph("c", nil), paragraph("b", "Zwei")])
        }

        model.activeText.append(AttributedString("!\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.sendDocument()  // the insert's own document event

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
        let engine = FakeDocumentEngine(document: document)
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
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
        engine.sendDocument()
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
        engine.sendDocument()
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
        engine.sendDocument()
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

    /// A page title starting with a combining mark merges with the character before its mention, so the text gets shorter
    /// than both parts: the cursor after the mention stays inside it (it trapped).
    @Test(.timeLimit(.minutes(1))) func mentionOfTitleWithCombiningMarkKeepsTheCursorInside() async throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "see ")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.serverURL = URL(string: "https://wiki.example.com")
        let target = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p2","slugId":"Ab12","title":"́Spec"}"#.utf8))
        model.lookUpPage = { _ in target }
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)

        #expect(model.pasteLink("https://wiki.example.com/p/spec-Ab12"))
        // By its text: the merged mark leaves no clean run for the mention to be read back from.
        while !String(model.activeText.characters).hasSuffix("Spec") { try await Task.sleep(for: .milliseconds(10)) }
        guard case .insertionPoint(let cursor) = model.activeSelection.indices(in: model.activeText) else {
            Issue.record("no insertion point")
            return
        }
        #expect(cursor == model.activeText.endIndex)
    }

    /// While the link sheet holds the text, a pasted page link stays a link: the sheet keeps its range in that text, which
    /// the shorter mention would end before.
    @Test(.timeLimit(.minutes(1))) func pastedPageLinkStaysALinkWhileTheLinkSheetIsOpen() async throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Hallo ")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.serverURL = URL(string: "https://wiki.example.com")
        let target = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p2","slugId":"Ab12","title":"Ziel"}"#.utf8))
        var answer: CheckedContinuation<Page?, Never>?
        model.lookUpPage = { _ in await withCheckedContinuation { answer = $0 } }
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)

        let url = "https://wiki.example.com/p/ziel-Ab12"
        #expect(model.pasteLink(url))
        while answer == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.editsLink = true
        answer?.resume(returning: target)
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.activeText.runs.contains { $0.link?.absoluteString == url })
        #expect(!DocumentModel.inlines(from: model.activeText, base: .body).contains { $0.type == "mention" })
    }

    /// "/bild" → Image drops the query before the picker opens, as on the web: gone on cancel, replaced by the uploads.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func mediaCommandRemovesSlashQuery(uploads: Bool) async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let paragraph = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        /// Waits for the `count`-th save, then delivers the engine's document event for it.
        func waitForSave(_ count: Int) async throws {
            while engine.saved.count < count { try await Task.sleep(for: .milliseconds(10)) }
            engine.document = PMNode(type: "doc", content: Array(engine.saved.suffix(1)))
            engine.sendDocument()
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
        engine.sendDocument()

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
        engine.sendDocument()

        model.performAtEnd(.image)
        let first = model.takeMediaTarget()  // its picker closed, the upload runs
        model.performAtEnd(.attachment)
        await model.insertUploads([Attachment(id: "i", fileName: "i.png", mimeType: "image/png")], to: first)

        #expect(engine.inserted.map(\.node.type) == ["image"])
        #expect(model.pendingMedia?.action == .attachment)
    }

    /// A math block or embed from its sheet goes in only after the sheet has closed (switching editors while it slides
    /// away can leave a UIKit animation running), and only once: a later cancelled sheet adds nothing.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func sheetBlockWaitsForDismissal(embed: Bool) async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
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
        while engine.replaced.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
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
        engine.sendDocument()
        engine.whileInserting = {
            engine.sendDocument()  // an event from before the insert
            engine.document = PMNode(type: "doc", content: [paragraph("a", "Eins"), PMNode(type: "heading", attrs: ["id": "c", "level": 2]), paragraph("b", nil)])
        }

        await model.insertTemplate(.heading2, placement: .end)
        engine.sendDocument()  // the insert's own document event

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
        engine.sendDocument()
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
        engine.sendDocument()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        engine.whileInserting = {
            engine.sendDocument()  // an event from before the wrap
            engine.document = PMNode(type: "doc", content: [PMNode(type: "transclusionSource", content: [paragraph])])
        }

        await model.wrapActiveInSyncedBlock()
        engine.sendDocument()  // the wrap's own document event

        #expect(model.active?.ref == NodeRef(path: [0, 0], id: "a"))
    }

    /// Return in an empty list item: an older document event arrives while the list makes way for the paragraph, with the
    /// list still at its path. The new paragraph still gets the cursor.
    @Test(.timeLimit(.minutes(1))) func listExitFocusesNewParagraphDespiteOlderEvent() async throws {
        func paragraph(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let list = PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [paragraph("a", nil)])])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list, paragraph("b", "Zwei")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let item = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: item), node: item)
        engine.whileInserting = {
            engine.sendDocument()  // an event from before the batch
            engine.document = PMNode(type: "doc", content: [paragraph("c", nil), paragraph("b", "Zwei")])
        }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.sendDocument()  // the batch's own document event

        #expect(model.active?.ref == NodeRef(path: [0], id: "c"))
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
        engine.sendDocument()
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
        engine.sendDocument()
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

    /// Row below in a table: an older document event arrives while the engine adds the row, with the next row still at
    /// the new row's path. The new row still gets the cursor.
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
        engine.sendDocument()
        let cell = try #require(model.node(at: [0, 0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0, 0], node: cell), node: cell)
        engine.tableFocus = [1, 0]
        engine.whileInserting = {
            engine.sendDocument()  // an event from before the new row
            engine.document = table([("a", "Eins"), ("c", nil), ("b", "Zwei")])
        }

        await model.editTable(.insertRowBelow)
        engine.sendDocument()  // the new row's own document event

        let command = try #require(engine.tableCommands.first)
        #expect(command.target == .path([0], type: "table") && command.cell == [0, 0] && command.command == ["name": "addRowAfter"])
        #expect(model.active?.ref == NodeRef(path: [0, 1, 0, 0], id: "c"))
    }

    /// A table action never leaves the cursor on a list (quote, image …) that starts a cell: typing rewrote that block
    /// from the editor's text, and each Backspace took a list item. A header row keeps the cursor in its paragraph; a
    /// deleted row moves it into the list of the next one.
    @Test(.timeLimit(.minutes(1)), arguments: [DocumentModel.TableEdit.toggleHeaderRow, .deleteRow])
    func tableEditFocusesOnlyText(edit: DocumentModel.TableEdit) async throws {
        func row(_ id: String, _ text: String, header: Bool = false) -> PMNode {
            PMNode(type: "tableRow", content: [PMNode(type: header ? "tableHeader" : "tableCell", content: [PMNode(type: "bulletList", content: [
                PMNode(type: "listItem", content: [PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: text)])]),
            ])])])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "table", content: [row("a", "Eins"), row("b", "Zwei")])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let line = try #require(model.node(at: [0, 0, 0, 0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0, 0, 0, 0], node: line), node: line)
        let rows = edit == .deleteRow ? [row("b", "Zwei")] : [row("a", "Eins", header: true), row("b", "Zwei")]
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [PMNode(type: "table", content: rows)]) }

        await model.editTable(edit)

        #expect(model.active?.type == "paragraph")
        #expect(model.active?.ref.id == (edit == .deleteRow ? "b" : "a"))
        model.activeText.append(AttributedString("x"))
        model.activeTextChanged()
        await model.flush()
        #expect(!engine.saved.contains { $0.type == "bulletList" })
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
        engine.sendDocument()

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

    /// A change the engine refuses without a reason (e.g. at a block a collaborator just deleted): the page says it
    /// wasn't applied until the next change goes through.
    @Test func failedChangeShowsMessageUntilOneApplies() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        engine.failsNextInsert = true
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()

        await model.insertBlocks([PMNode(type: "horizontalRule")], placement: .end, focus: nil)
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
        await model.insertBlocks([PMNode(type: "horizontalRule")], placement: .end, focus: nil)
        #expect(model.errorMessage == nil)
    }

    /// The engine goes while a block just left is saved (its web process ended): the block keeps its input, which goes
    /// in once the engine is back, and nothing says "could not be applied". It counted as refused, and the text was gone.
    @Test(.timeLimit(.minutes(1))) func unavailableEngineKeepsTheInputOfALeftBlock() async throws {
        func paragraph(_ id: String, _ text: String) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: text)])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", "Zwei")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let first = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: first), node: first)
        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()

        engine.savesUnavailable = true
        let second = try #require(model.node(at: [1]))
        model.activate(NodeRef(path: [1], node: second), node: second)
        while engine.saved.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.node(at: [0])?.plainText == "Eins!")
        #expect(model.errorMessage == nil)

        engine.savesUnavailable = false
        engine.sendDocument()  // the reopened engine's first document
        while engine.saved.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.saved.map(\.plainText) == ["Eins!", "Eins!"])
        #expect(engine.bases.last??.plainText == "Eins")
    }

    /// Undo with nothing to undo says so; the button did nothing without a word. No engine says nothing (its restart
    /// shows in the status).
    @Test func refusedUndoSaysSo() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph")]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()

        engine.historyResult = .refused
        await model.undo()
        #expect(model.notice == String(localized: "Nothing to undo."))
        model.notice = nil
        await model.redo()
        #expect(model.notice == String(localized: "Nothing to redo."))
        model.notice = nil
        engine.historyResult = .unavailable
        await model.undo()
        #expect(model.notice == nil)
    }

    /// Checking a task reaches a task item only (by path alone it set `checked` on whatever block a collaborator moved
    /// there), and a refusal is said; it used to go unanswered.
    @Test func refusedTaskCheckSaysSo() async throws {
        let item = PMNode(type: "taskItem", attrs: ["checked": false], content: [PMNode(type: "paragraph", attrs: ["id": "a"])])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "taskList", content: [item])]))
        let model = try Self.model(engine)
        engine.attributesResult = .refused

        await model.toggleTask(itemPath: [0, 0])

        #expect(engine.attributeTargets == [.path([0, 0], type: "taskItem")])
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
    }

    /// A list converted while a collaborator types in it: the new list comes from the engine's document, which has their
    /// text, not from the app's copy, which lags behind while someone types. Built from that copy, it dropped what they
    /// typed meanwhile, without notice. The list read goes with it as the expected state.
    @Test func listConversionKeepsWhatACollaboratorTyped() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list("bulletList", ["Eins", "Zwei"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        engine.document = PMNode(type: "doc", content: [Self.list("bulletList", ["Eins", "Zwei und drei"])])

        await model.convertList(itemPath: [0, 1], to: .orderedList)

        let converted = try #require(engine.saved.last)
        #expect(converted.type == "orderedList")
        #expect(converted.children.map(\.plainText) == ["Eins", "Zwei und drei"])
        #expect(engine.expectations.last == engine.document?.children.first)
        #expect(model.errorMessage == nil)
    }

    /// A collaborator's edit that lands between reading a block and replacing it: the engine refuses the replacement, and
    /// the page says so instead of overwriting the edit.
    @Test func structuralEditIsRefusedWhenTheBlockChanged() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list("bulletList", ["Eins", "Zwei"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        engine.collaboratorEdit = { engine.document = PMNode(type: "doc", content: [Self.list("bulletList", ["Eins", "Zwei!"])]) }

        await model.convertList(itemPath: [0, 1], to: .orderedList)

        #expect(engine.expectations.last == Self.list("bulletList", ["Eins", "Zwei"]))
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
    }

    private static func list(_ type: String, _ items: [String]) -> PMNode {
        PMNode(type: type, content: items.enumerated().map { index, text in
            PMNode(type: "listItem", content: [
                PMNode(type: "paragraph", attrs: ["id": .string("i\(index)")], content: [PMNode(type: "text", text: text)]),
            ])
        })
    }

    /// An inline item lands at the cursor, also at the very start of a block: "/datum" typed before "Hallo", or the "+"
    /// menu with the cursor there. Up to 1.0 it went after the first character, as if each text still began with the
    /// invisible character the editor had before it became one editor for the whole page.
    @Test(arguments: [false, true]) func inlineItemAtTheStartOfABlock(fromSlash: Bool) throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Hallo")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
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
        engine.sendDocument()
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
        engine.sendDocument()

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
        while model.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }

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
        while model.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }

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
        // The web process ends: the engine is closed and takes nothing, also not the save on leaving the block.
        engine.status = .idle
        engine.document = nil
        engine.savesUnavailable = true
        engine.onTerminated?()
        while engine.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        engine.savesUnavailable = false
        engine.sendDocument(document)  // the reopened engine's first document
        while engine.saved.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.saved.map(\.plainText) == ["Eins neu", "Eins neu"])
    }

    /// "Open Link" on an integration mention opens only web addresses: Safari's view threw on any other, ending the app.
    @Test func mentionOpensOnlyWebAddresses() {
        func target(_ url: String) -> DocumentModel.MentionTarget {
            DocumentModel.MentionTarget(ref: NodeRef(path: [0], id: "a"), index: 0, url: url, provider: "github")
        }
        #expect(target("https://github.com/o/r/issues/1").webURL != nil)
        for url in ["mailto:a@b.c", "tel:1", "ftp://github.com/x", "javascript:alert(1)", "file:///x", "github.com/o/r", ""] {
            #expect(target(url).webURL == nil, "\(url)")
        }
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

    /// Changes the server hasn't confirmed go into the store for unsent changes without leaving the page, 2 s after the
    /// last one: they lived only in the engine's web process until the page left or the app reached the background.
    /// Offline, and on a connection that died without notice, where the engine still says "synced" until it notices (it
    /// was saved only offline). Confirmed, nothing is saved.
    @Test(.timeLimit(.minutes(1)), arguments: [(EngineStatus.disconnected, 1), (.synced, 1), (.synced, 0)])
    func unconfirmedChangesAreKeptWhileThePageStaysOpen(status: EngineStatus, unconfirmed: Int) async throws {
        func doc(_ text: String) -> PMNode {
            PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: text)])])
        }
        let engine = FakeDocumentEngine(document: doc("Hello"))
        engine.status = status
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: line), node: line)
        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        await model.flush()
        engine.unconfirmedChanges = unconfirmed
        engine.sendDocument(doc("Hello!"))  // the engine's document event for the change

        try await Task.sleep(for: .seconds(3))
        // A busy main actor (a full parallel run) can hold the save back longer.
        while unconfirmed > 0, engine.lifecycle.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.lifecycle == (unconfirmed == 0 ? [] : ["save after 1"]))
    }

    /// Reopening after a refused live connection closes the engine first, as leaving does: its unsent changes (e.g.
    /// made offline) are kept for the reopened engine, where the reopen threw them away.
    @Test(.timeLimit(.minutes(1))) func reopeningAfterARefusedConnectionClosesFirst() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        engine.status = .failed("permission-denied")
        engine.onFailure?(.connectionRefused)

        model.resume()
        await model.suspend().value

        #expect(engine.lifecycle == ["close", "open", "close"])
    }

    /// Leaving the page while an upload runs keeps its engine open for the upload's insert and closes it after the last
    /// one: the uploads used to end up only in the page's attachments. Back on the page, it stays open.
    @Test(.timeLimit(.minutes(1))) func leavingDuringAnUploadClosesAfterIt() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        let uploads = HeldUploads(model)

        uploads.start()
        uploads.start()
        model.leave()
        #expect(model.isLive)
        try await uploads.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!engine.lifecycle.contains("close"))
        try await uploads.finish()
        while !engine.lifecycle.contains("close") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.inserted.count == 2)

        engine.status = .idle  // closed, as the real engine is then
        model.resume()
        while !engine.lifecycle.contains("open") { try await Task.sleep(for: .milliseconds(10)) }
        engine.status = .synced
        uploads.start()
        model.leave()
        model.resume()
        try await uploads.finish()
        while !engine.lifecycle.contains("open") { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.lifecycle == ["close", "open"])
    }

    /// Lost write access (Docmost 0.97's `page.permissions`, or a connection the server lets only read) ends editing and
    /// makes the page read-only with a notice, for good: the page stayed editable and showed "Saved" while the server
    /// ignored every edit.
    @Test func lostWriteAccessMakesThePageReadOnly() throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Hallo")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        #expect(model.isEditable)

        engine.onFailure?(.readOnly)

        #expect(!model.isEditable)
        #expect(model.active == nil)
        #expect(model.readOnlyReason == .noPermission)
        #expect(model.errorMessage == String(localized: "You can no longer edit this page. Changes the server didn't take stay on this device until you can edit it again."))
    }

    /// A collaborator's change of the block being edited shows in the editor once nothing of the user's is pending, and
    /// the next key builds on it: the old text used to be written back over their sentence.
    @Test(.timeLimit(.minutes(1))) func collaboratorsChangeOfTheActiveBlockShowsAndStays() async throws {
        func paragraph(_ text: String) -> PMNode { PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: text)]) }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("Hello")]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: line), node: line)
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)

        engine.document = PMNode(type: "doc", content: [paragraph("Hello world")])
        engine.sendDocument()
        while String(model.activeText.characters) != "Hello world" { try await Task.sleep(for: .milliseconds(10)) }
        // The cursor stays before their words, which came after it.
        guard case .insertionPoint(let cursor) = model.activeSelection.indices(in: model.activeText) else {
            Issue.record("no insertion point")
            return
        }
        #expect(model.activeText.characters.distance(from: model.activeText.startIndex, to: cursor) == 5)

        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        await model.flush()
        #expect(engine.saved.map(\.plainText) == ["Hello world!"])
    }

    /// Input still pending when a collaborator's change arrives goes out with the block it was typed on as its base, so
    /// the engine keeps their change (`rebase`); once the engine has both, the editor shows them.
    @Test(.timeLimit(.minutes(1))) func inputPendingDuringACollaboratorsChangeIsSavedOnItsBase() async throws {
        func paragraph(_ text: String) -> PMNode { PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: text)]) }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("Hello")]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: line), node: line)

        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        engine.document = PMNode(type: "doc", content: [paragraph("Hello world")])
        engine.sendDocument()
        #expect(String(model.activeText.characters) == "Hello!")
        await model.flush()
        #expect(engine.saved.map(\.plainText) == ["Hello!"])
        #expect(engine.bases.map { $0?.plainText } == ["Hello"])

        engine.document = PMNode(type: "doc", content: [paragraph("Hello world!")])  // what the engine made of both
        engine.sendDocument()
        while String(model.activeText.characters) != "Hello world!" { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Moving the cursor to another block writes nothing back when nothing was typed: the untouched block overwrote
    /// what a collaborator typed there in the next 400 ms.
    @Test(.timeLimit(.minutes(1))) func switchingBlocksWritesNothingBack() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: [PMNode(type: "text", text: "Zwei")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
        let model = try Self.model(engine)

        model.activate(NodeRef(path: [0], node: first), node: first)
        model.activeTextChanged()  // the editor reporting the text it was given
        model.activate(NodeRef(path: [1], node: second), node: second)
        model.activeTextChanged()
        try await Task.sleep(for: .milliseconds(600))

        #expect(engine.saved.isEmpty)
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
        engine.sendDocument()
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
        engine.sendDocument()
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
        engine.sendDocument()
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
        engine.sendDocument()
        model.activate(NodeRef(path: [1], node: code), node: code)

        model.activeCode += "2"
        model.activeCodeChanged()
        engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"]), divider, code])
        engine.sendDocument()
        try await Task.sleep(for: .milliseconds(600))  // longer than a save waits for more input

        #expect(model.active == nil)
        #expect(engine.saved.isEmpty)
    }

    /// Backspace joins a list item to the one above in one batch with removing its item, which is found in the engine's
    /// document as it is now and sent as expected: a collaborator's list arrived above, not yet in the page's copy, and
    /// moved it down. Removed separately afterwards, by its old path, the item used to be theirs.
    @Test(.timeLimit(.minutes(1))) func joinedItemGoesWhereTheEngineHasIt() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", "Zwei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        engine.document = PMNode(type: "doc", content: [Self.list([("x", "Ihre"), ("y", "Liste")]), Self.list([("a", "Eins"), ("b", "Zwei")])])

        #expect(model.backspaceAtStart())
        while engine.saved.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.saved.map(\.plainText) == ["EinsZwei"])
        #expect(engine.batches.count == 1)
        #expect(engine.batches.first?.last == .delete(.path([1, 1], type: "listItem"), expected: PMNode(type: "listItem", content: [line])))
    }

    /// A join the engine refuses (the joined block changed meanwhile) applies neither half and says so; editing ends
    /// instead of showing the joined text. As separate calls, the text was then there twice.
    @Test(.timeLimit(.minutes(1))) func refusedJoinSaysSo() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: [PMNode(type: "text", text: "Zwei")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [1], node: second), node: second)
        engine.nextBatchResult = .refused

        #expect(model.backspaceAtStart())
        while engine.batches.isEmpty && engine.saved.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.batches.count == 1)
        #expect(engine.saved.isEmpty && engine.deleted.isEmpty)
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
        #expect(model.active == nil)
    }

    /// Backspace at a block's start puts the cursor where the two texts meet, counted in the editor's characters: a
    /// mention ("@Alice") or a line break isn't its plain text, and typing landed inside the sentence before.
    @Test(.timeLimit(.minutes(1))) func joinPutsTheCursorWhereTheTextsMeet() async throws {
        let alice = PMNode(type: "mention", attrs: ["id": "m1", "label": "Alice", "entityType": "user", "entityId": "u1"])
        let bob = PMNode(type: "mention", attrs: ["id": "m2", "label": "Bob", "entityType": "user", "entityId": "u2"])
        func text(_ value: String) -> PMNode { PMNode(type: "text", text: value) }
        let cases: [(previous: [PMNode], current: [PMNode], offset: Int)] = [
            ([text("Call "), alice, text(" about")], [text("the budget")], 17),
            ([text("a"), PMNode(type: "hardBreak"), text("b")], [text("c")], 3),
            ([text("Call "), alice, text(" and "), bob], [], 20),
        ]
        for (previous, current, offset) in cases {
            let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: previous)
            let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: current.isEmpty ? nil : current)
            let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
            let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
            let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
            engine.sendDocument()
            model.activate(NodeRef(path: [1], node: second), node: second)

            #expect(model.backspaceAtStart())
            while model.active?.ref.path != [0] { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.cursorRequest == .offset(offset))
        }
    }

    /// Text ↔ code keeps line breaks, as the web's setBlockType does: Shift-Return lines become the code's lines and
    /// back, and the converted text doesn't split into blocks on the next key.
    @Test(.timeLimit(.minutes(1))) func convertingBetweenTextAndCodeKeepsLines() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [
            PMNode(type: "text", text: "SELECT *"), PMNode(type: "hardBreak"), PMNode(type: "text", text: "FROM t"),
        ])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: Array(engine.saved.suffix(1))) }

        await model.convert(NodeRef(path: [0], node: paragraph), to: .codeBlock)
        let code = try #require(engine.saved.last)
        #expect(code.type == "codeBlock")
        #expect(code.plainText == "SELECT *\nFROM t")

        await model.convert(NodeRef(path: [0], node: code), to: .paragraph)
        let text = try #require(engine.saved.last)
        #expect(text.children.map(\.type) == ["text", "hardBreak", "text"])

        #expect(model.active?.type == "paragraph")
        model.activeText.append(AttributedString("x"))
        model.activeTextChanged()
        await model.flush()
        #expect(engine.inserted.isEmpty)
    }

    /// A formula written with Shift-Return stays whole while its paragraph is edited: its line break read as Return split
    /// the paragraph and turned the formula into text.
    @Test(.timeLimit(.minutes(1))) func formulaWithLineBreakSurvivesEditing() async throws {
        let formula = PMNode(type: "mathInline", attrs: ["text": "a \\\\\nb"])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "p"], content: [
            PMNode(type: "text", text: "x "), formula, PMNode(type: "text", text: " y"),
        ])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)

        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        await model.flush()

        #expect(engine.inserted.isEmpty)
        #expect(engine.saved.last?.children.contains(formula) == true)
    }

    /// Return in a list's only item, empty: one batch puts a paragraph after the list and removes the list, found in the
    /// engine's document as it is now (below a collaborator's paragraph the page's copy doesn't have yet) and sent as
    /// expected. The paragraph takes the list's place and gets the cursor.
    @Test(.timeLimit(.minutes(1))) func leavingAListIsOneBatch() async throws {
        let list = Self.list([("a", nil)])
        let theirs = PMNode(type: "paragraph", attrs: ["id": "x"], content: [PMNode(type: "text", text: "Ihrer")])
        let new = PMNode(type: "paragraph", attrs: ["id": "b"])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        engine.document = PMNode(type: "doc", content: [theirs, list])
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [theirs, new]) }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.batches == [[
            .insert([PMNode(type: "paragraph")], relativeTo: .path([1], type: "bulletList"), position: .after),
            .delete(.path([1], type: "bulletList"), expected: list),
        ]])
        #expect(model.active?.ref == NodeRef(path: [1], id: "b"))
    }

    /// Leaving a list that the engine refuses (the item changed meanwhile) applies none of its steps and says so; the
    /// cursor stays in the item.
    @Test(.timeLimit(.minutes(1))) func refusedLiftSaysSo() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", nil), ("c", "Drei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        engine.nextBatchResult = .refused

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.batches.isEmpty && engine.splitAfter.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.batches.count == 1)
        #expect(engine.splitAfter.isEmpty && engine.inserted.isEmpty && engine.deleted.isEmpty)
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
        #expect(model.active?.ref.id == "b")
    }

    /// Return in an empty item that holds more in the engine by now (a collaborator added a nested list) keeps it in the
    /// list and says so: removing the item would take their list along.
    @Test(.timeLimit(.minutes(1))) func itemGrownMeanwhileStays() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "a"])
        let nested = Self.list([("y", "Ihrer")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [line])])]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        engine.document = PMNode(type: "doc", content: [PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [line, nested])])])

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while model.errorMessage == nil && engine.inserted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.batches.isEmpty && engine.inserted.isEmpty)
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
    }

    /// Return in an empty item in the middle of a list splits the list there, as the web does: the paragraph goes
    /// between the halves, and the item goes once that paragraph has focus.
    @Test(.timeLimit(.minutes(1))) func emptyMiddleItemSplitsTheList() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", nil), ("c", "Drei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        // The engine after the batch.
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [
                Self.list([("a", "Eins")]), PMNode(type: "paragraph", attrs: ["id": "n"]), Self.list([("c", "Drei")]),
            ])
        }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.deleted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.splitAfter == [.path([0, 1], type: "listItem")])
        #expect(engine.inserted.map(\.position) == [.after] && engine.inserted.first?.target == .path([0], type: "bulletList"))
        #expect(model.active?.ref == NodeRef(path: [1], id: "n"))
        #expect(engine.deleted == [.path([0, 1], type: "listItem")])
        #expect(engine.batches.count == 1)
        #expect(engine.batches.first?.last == .delete(.path([0, 1], type: "listItem"), expected: PMNode(type: "listItem", content: [line])))
    }

    /// Return or Backspace in an empty first item puts the paragraph before the list, as the web lifts the item there.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func emptyFirstItemGoesBeforeTheList(backspace: Bool) async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", nil), ("b", "Zwei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "n"]), Self.list([("b", "Zwei")])])
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
                Self.list([("a", "Eins")]),
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
            (blocks, after, linePath) = ([quote], [PMNode(type: "blockquote", content: [line("a", "Zitat")]), new], [0, 1])
            (split, insertTarget, deleted) = ([], .path([0], type: "blockquote"), .path([0, 1], type: "paragraph"))
        case "item":
            let first = PMNode(type: "listItem", content: [line("a", "Eins"), line("b", nil)])
            let second = PMNode(type: "listItem", content: [line("c", "Zwei")])
            (blocks, linePath) = ([PMNode(type: "bulletList", content: [first, second])], [0, 0, 1])
            after = [PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [line("a", "Eins")])]), new, PMNode(type: "bulletList", content: [second])]
            (split, insertTarget, deleted) = ([.path([0, 0], type: "listItem")], .path([0], type: "bulletList"), .path([0, 0, 1], type: "paragraph"))
        default:
            let summary = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")])
            let toggle = PMNode(type: "details", content: [summary, PMNode(type: "detailsContent", content: [line("a", "Inhalt"), line("b", nil)])])
            let left = PMNode(type: "details", content: [summary, PMNode(type: "detailsContent", content: [line("a", "Inhalt")])])
            (blocks, after, linePath) = ([toggle], [left, new], [0, 1, 1])
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
        engine.sendDocument()
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
        engine.sendDocument()
        let ref = NodeRef(path: [1], node: reference)
        let above = PMNode(type: "paragraph", attrs: ["id": "b"])
        let content = [PMNode(type: "paragraph", attrs: ["id": "c"], content: [PMNode(type: "text", text: "Inhalt")])]

        engine.document = PMNode(type: "doc", content: [above, paragraph, reference])
        engine.sendDocument()
        await model.unsyncReference(reference, at: ref, content: content)
        engine.document = PMNode(type: "doc", content: [above, paragraph] + content)
        engine.sendDocument()
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
        engine.sendDocument()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)

        // As the web engine does: it closes, then reports it.
        engine.status = .idle
        engine.document = nil
        engine.onTerminated?()
        #expect(model.active == nil)
        #expect(!model.isEditable)
        while engine.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.document = document
        engine.sendDocument()

        #expect(engine.opened == ["p"])
        #expect(model.isEditable)
    }

    /// An error in the engine once loaded: it closes, keeping what the server hadn't confirmed, and opens again, and the
    /// input it hadn't saved goes in when it is back. The error used to be only logged.
    @Test(.timeLimit(.minutes(1))) func engineErrorOpensTheEngineAgainWithTheInput() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let document = PMNode(type: "doc", content: [paragraph])
        let engine = FakeDocumentEngine(document: document)
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeText.append(AttributedString(" neu"))
        model.activeTextChanged()

        // As the web engine does: it closes, then reports it, and takes nothing meanwhile.
        engine.status = .idle
        engine.document = nil
        engine.savesUnavailable = true
        engine.onFailure?(.engineError)
        #expect(model.active == nil)
        #expect(!model.isEditable)
        while engine.saved.isEmpty || engine.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.savesUnavailable = false
        engine.document = document
        engine.sendDocument()

        #expect(engine.opened == ["p"])
        #expect(model.isEditable)
        while engine.saved.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.saved.map(\.plainText) == ["Eins neu", "Eins neu"])
    }

    /// A second engine error on the page leaves it read-only with a message; the engine opens again only on a refresh.
    @Test(.timeLimit(.minutes(1))) func secondEngineErrorLeavesThePageReadOnly() async throws {
        let document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])])
        let engine = FakeDocumentEngine(document: document)
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        engine.status = .idle
        engine.document = nil
        engine.onFailure?(.engineError)
        while engine.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.document = document
        engine.sendDocument()
        #expect(model.isEditable)

        engine.status = .idle
        engine.document = nil
        engine.onFailure?(.engineError)
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.opened == ["p"])
        #expect(!model.isEditable)
        #expect(model.errorMessage == String(localized: "The editor stopped after an error. The page is read-only; pull down to try again."))
    }

    /// A document event that arrives after the page left keeps it read-only, as does the closing engine's last document:
    /// each made the page count as live again, editable while its engine closed.
    @Test(.timeLimit(.minutes(1))) func documentAfterLeavingKeepsThePageReadOnly() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        let closing = model.suspend()
        engine.sendDocument()  // an event still on its way
        #expect(!model.isEditable)
        await closing.value
        engine.sendDocument()  // the closing engine's last document
        #expect(!model.isEditable)
    }

    /// Leaving the page while its engine opens: a document the opening engine sends before the close that follows keeps
    /// the page read-only.
    @Test(.timeLimit(.minutes(1))) func documentFromAnOpenBeforeItsCloseKeepsThePageReadOnly() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.status = .idle
        var editableWhileOpening: Bool?
        engine.whileOpening = {
            engine.sendDocument()
            editableWhileOpening = model.isEditable
        }

        model.resume()
        await model.suspend().value

        #expect(engine.lifecycle == ["open", "close"])
        #expect(editableWhileOpening == false)
        #expect(!model.isEditable)
    }

    /// A save refused after the page left, for the block it edited, keeps the page read-only, also when the refusal
    /// arrives once the engine is closed: showing the engine's block again counted the page as live, editable with its
    /// engine closed.
    @Test(.timeLimit(.minutes(1))) func refusedSaveAfterLeavingKeepsThePageReadOnly() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeText.append(AttributedString(" neu"))
        model.activeTextChanged()
        engine.refusesSaves = true
        engine.holdsNextSave = true

        await model.suspend().value
        while engine.heldSave == nil { try await Task.sleep(for: .milliseconds(10)) }
        engine.heldSave?.resume()
        while model.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.lifecycle == ["close"])
        #expect(!model.isEditable)
    }

    /// An upload's error goes to the whole app, where it shows also once the page has closed: it went to the page's toast,
    /// which closed with it.
    @Test(.timeLimit(.minutes(1))) func uploadErrorIsToldAppWide() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        var notices: [String] = []
        model.postAppNotice = { notices.append($0) }
        let uploads = HeldUploads(model)
        let error = APIError.server(status: 413, message: "Too large")
        uploads.nextError = error

        uploads.start()
        #expect(model.uploads == 1)
        model.leave()
        while !engine.lifecycle.contains("close") { try await Task.sleep(for: .milliseconds(10)) }

        #expect(notices == [String(localized: "Not uploaded: \(error.userMessage)")])
        #expect(engine.inserted.isEmpty)
        #expect(model.uploads == 0)
    }

    /// An upload the page can no longer take (refused, the page went to the trash or became a database meanwhile) is told
    /// to the whole app: the file reached the server, but not the page, without a word.
    @Test(.timeLimit(.minutes(1))) func uploadThePageCannotTakeIsToldAppWide() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p","title":"Notizen"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        var notices: [String] = []
        model.postAppNotice = { notices.append($0) }
        let uploads = HeldUploads(model)
        engine.failsNextInsert = true

        uploads.start()
        try await uploads.finish()
        while notices.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        let title = try #require(page.title)
        #expect(notices == [String(localized: "The upload couldn't be added to “\(title)”.")])
    }
}

/// Uploads through a model's `upload` that wait, as on their way to the server, until the test finishes them in order.
final class HeldUploads {
    private let model: DocumentModel
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// What the next upload throws instead of reaching the server.
    var nextError: Error?

    init(_ model: DocumentModel) {
        self.model = model
        model.serverURL = URL(string: "https://docs.example.com")!
        model.sendUpload = { [self] file in
            if let error = nextError {
                nextError = nil
                throw error
            }
            await withCheckedContinuation { waiting.append($0) }
            return Attachment(id: UUID().uuidString, fileName: file.fileName, mimeType: file.mimeType)
        }
    }

    /// One file, to the end of the page.
    func start() {
        model.upload(1, to: MediaTarget(placement: .end, asAttachment: true)) { _, _ in
            UploadFile(fileURL: FileManager.default.temporaryDirectory.appending(path: "held-upload-\(UUID().uuidString)/file"),
                       fileName: "a.pdf", mimeType: "application/pdf")
        }
    }

    /// Lets the oldest upload finish, once it is on its way.
    func finish() async throws {
        while waiting.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        waiting.removeFirst().resume()
    }
}

/// Stand-in for the web engine: changes nothing and records what it is asked to open, save, insert, replace, delete or
/// do to a table.
final class FakeDocumentEngine: DocumentEngine {
    var status = EngineStatus.synced
    var unconfirmedChanges = 0
    /// What the engine holds now (`currentDocument`); `sendDocument` sends it.
    var document: PMNode?
    var participants: [EngineParticipant] = []
    var onDocument: (@MainActor (PMNode) -> Void)?
    var onFailure: (@MainActor (EngineFailure) -> Void)?
    var onTerminated: (@MainActor () -> Void)?
    private(set) var opened: [String] = []
    /// "open" and "close" in order.
    private(set) var lifecycle: [String] = []
    /// Blocks written with `replaceBlock(_:with:base:expected:)` or a batch's replace step, and the bases passed with them.
    private(set) var saved: [PMNode] = []
    private(set) var bases: [PMNode?] = []
    /// The expected state passed with each replacement (either kind), in order.
    private(set) var expectations: [PMNode?] = []
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
    /// Runs during `open`, e.g. to send the opened engine's first document.
    var whileOpening: (() -> Void)?
    /// The next `insertBlocks` is refused, like one at a block a collaborator just deleted.
    var failsNextInsert = false
    /// Saves fail, like a server refusing them.
    var refusesSaves = false
    /// Saves find no engine, like one whose web process just ended.
    var savesUnavailable = false
    /// Runs once when the next replacement arrives, before it is checked against its expected state: a collaborator's
    /// edit that lands between reading a block and replacing it.
    var collaboratorEdit: (() -> Void)?
    /// What `undo` and `redo` answer.
    var historyResult = EngineResult.applied
    /// The steps of each `batch`.
    private(set) var batches: [[EngineStep]] = []
    /// What the next `batch` answers instead of applying, e.g. refused, as the engine refuses a block that changed.
    var nextBatchResult: EngineResult?
    /// Targets of `setAttributes`, and what it answers.
    private(set) var attributeTargets: [BlockTarget] = []
    var attributesResult = EngineResult.applied
    /// Table commands, with the table and the cell they ran on.
    private(set) var tableCommands: [(target: BlockTarget, cell: [Int], command: [String: JSONValue])] = []
    /// What `tableCommand` returns: the cell for the cursor afterwards; nil refuses the command.
    var tableFocus: [Int]? = [0, 0]

    init(document: PMNode) {
        self.document = document
    }

    /// Sends `document` (set to `next` first, if given), as the engine sends one after a change.
    func sendDocument(_ next: PMNode? = nil) {
        if let next { document = next }
        if let document { onDocument?(document) }
    }

    func replaceBlock(_ target: BlockTarget, with node: PMNode, base: PMNode?, expected: PMNode?) async -> EngineResult {
        saved.append(node)
        bases.append(base)
        if let refusal = check(target, expected) { return refusal }
        whileInserting?()
        if holdsNextSave {
            holdsNextSave = false
            await withCheckedContinuation { heldSave = $0 }
            heldSave = nil
        }
        return savesUnavailable ? .unavailable : refusesSaves ? .refused : .applied
    }

    /// Refused, as the engine refuses it, when the target changed from `expected` (after `collaboratorEdit`).
    private func check(_ target: BlockTarget, _ expected: PMNode?) -> EngineResult? {
        expectations.append(expected)
        collaboratorEdit?()
        collaboratorEdit = nil
        guard let expected else { return nil }
        return block(at: target) == expected ? nil : .refused
    }

    private func block(at target: BlockTarget) -> PMNode? {
        func find(_ node: PMNode, _ id: String) -> PMNode? {
            for child in node.children {
                if child.string("id") == id { return child }
                if let found = find(child, id) { return found }
            }
            return nil
        }
        guard let document else { return nil }
        switch target {
        case .id(let id): return find(document, id)
        case .path(let path, let type):
            var node = document
            for index in path {
                guard node.children.indices.contains(index) else { return nil }
                node = node.children[index]
            }
            return type == nil || node.type == type ? node : nil
        }
    }

    func open(pageId: String) async throws {
        opened.append(pageId)
        lifecycle.append("open")
        whileOpening?()
    }
    func close() { lifecycle.append("close") }
    /// With the number of block saves before it.
    func saveUnsentChanges() async { lifecycle.append("save after \(saved.count)") }
    func currentDocument() async -> PMNode? { document }
    func replaceBlock(_ target: BlockTarget, withNodes nodes: [PMNode], expected: PMNode?) async -> EngineResult {
        replaced.append(target)
        replacedWith.append(nodes)
        if let refusal = check(target, expected) { return refusal }
        whileInserting?()
        return .applied
    }
    func insertBlock(_ node: PMNode, relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> EngineResult {
        inserted.append((node, target, position))
        whileInserting?()
        return .applied
    }
    func insertBlocks(_ nodes: [PMNode], relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> EngineResult {
        if failsNextInsert {
            failsNextInsert = false
            return .refused
        }
        inserted += nodes.map { ($0, target, position) }
        whileInserting?()
        return .applied
    }
    func deleteBlock(_ target: BlockTarget) async -> EngineResult {
        deleted.append(target)
        return .applied
    }
    func moveBlock(_ target: BlockTarget, to destination: BlockTarget, position: BlockInsertPosition) async -> EngineResult { .applied }
    func splitContainer(after child: BlockTarget) async -> EngineResult {
        splitAfter.append(child)
        return .applied
    }
    func setAttributes(_ target: BlockTarget, attributes: [String: JSONValue]) async -> EngineResult {
        attributeTargets.append(target)
        return attributesResult
    }
    func tableCommand(_ target: BlockTarget, cell: [Int], command: [String: JSONValue]) async -> [Int]? {
        tableCommands.append((target, cell, command))
        whileInserting?()
        return tableFocus
    }
    func undo() async -> EngineResult { historyResult }
    func redo() async -> EngineResult { historyResult }
    /// Applied, records the steps as their own calls would (`saved`, `inserted`, `deleted`, `splitAfter`) and runs
    /// `whileInserting`, where a test sets the document the batch leaves.
    func batch(_ steps: [EngineStep]) async -> EngineResult {
        batches.append(steps)
        if let result = nextBatchResult {
            nextBatchResult = nil
            return result
        }
        for step in steps {
            switch step {
            case .replace(_, let node, let base):
                saved.append(node)
                bases.append(base)
            case .insert(let nodes, let target, let position): inserted += nodes.map { ($0, target, position) }
            case .delete(let target, _): deleted.append(target)
            case .split(let child): splitAfter.append(child)
            }
        }
        whileInserting?()
        return .applied
    }
}
