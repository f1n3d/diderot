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
    /// collaborator's edit of the item stays), and the engine switches the list it has then (Engine/tools/
    /// conversions-check.ts). Nothing stays pending (it would hide a collaborator's later edit and overwrite it on leaving),
    /// and the item reopens with the text despite older events.
    @Test(.timeLimit(.minutes(1))) func listTypeSwitchSendsPendingInputFirst() async throws {
        func list(_ type: String, _ text: String) -> PMNode {
            PMNode(type: type, content: [PMNode(type: "listItem", content: [
                PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: text)]),
            ])])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [list("bulletList", "Eins")]))
        let model = try Self.model(engine)
        let item = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: item), node: item)

        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        engine.convertResult = .moved(EngineCursor(path: [0, 0, 0], offset: 5))
        engine.whileInserting = {
            engine.sendDocument()  // an event from before the change
            engine.document = PMNode(type: "doc", content: [list(engine.converted.isEmpty ? "bulletList" : "orderedList", "Eins!")])
        }
        model.convertActive(to: .orderedList)
        while engine.converted.isEmpty || model.active == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.saved.map(\.plainText) == ["Eins!"])
        #expect(engine.bases.first??.plainText == "Eins")
        #expect(engine.converted.first?.target == .id("a") && engine.converted.first?.kind == "orderedList")
        #expect(model.active?.ref.path == [0, 0, 0])
        #expect(String(model.activeText.characters) == "Eins!")

        engine.whileInserting = nil
        engine.document = PMNode(type: "doc", content: [list("orderedList", "Eins! Zwei")])  // a collaborator's edit
        engine.sendDocument()
        await model.flush()  // leaving the page

        #expect(model.node(at: [0, 0, 0])?.plainText == "Eins! Zwei")
        #expect(engine.saved.count == 1)
    }

    /// Return mid-title in a toggle keeps the title whole on screen and sends the engine the text on both sides of the
    /// cursor, which it keeps together (Engine/tools/keys-check.ts); the cursor goes to the line it adds.
    @Test(.timeLimit(.minutes(1))) func returnInToggleTitleKeepsTitleWhole() async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "TiTel")])
        let line = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Inhalt")])
        func toggle(_ lines: [PMNode]) -> PMNode {
            PMNode(type: "doc", content: [PMNode(type: "details", attrs: ["open": .bool(true)], content: [title, PMNode(type: "detailsContent", content: lines)])])
        }
        let engine = FakeDocumentEngine(document: toggle([line]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0, 0], node: title), node: title)
        engine.enterResult = .moved(EngineCursor(path: [0, 1, 0], offset: 0))
        var shown: String?
        engine.whileInserting = {
            shown = String(model.activeText.characters)  // while the engine has the key
            engine.document = toggle([PMNode(type: "paragraph", attrs: ["id": "n"]), line])
        }

        model.activeText.insert(AttributedString("\n"), at: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 2))
        model.activeTextChanged()
        while model.active?.ref.id != "n" { try await Task.sleep(for: .milliseconds(10)) }

        #expect(shown == "TiTel")
        let enter = try #require(engine.enters.first)
        #expect(enter.node.plainText == "Ti" && enter.after.map(\.plainText) == ["Tel"])
    }

    /// Text pasted with line breaks goes in one step of the engine, each line where Return puts it (Engine/tools/
    /// keys-check.ts), and the cursor goes where the paste ends: one Return per line took seconds for 100 lines, the
    /// editor jumping from line to line, and left the cursor at the last line's start.
    @Test(.timeLimit(.minutes(1))) func pastedLinesGoInOneStep() async throws {
        func line(_ id: String, _ text: String) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: text)])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [line("a", "xyz")]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: line("a", "xyz")), node: line("a", "xyz"))
        engine.enterResult = .moved(EngineCursor(path: [2], offset: 0))
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [line("a", "xyA"), line("b", "B"), line("c", "Cz")]) }

        // Pasted after "xy", the cursor after the paste, as the text view leaves them.
        let text = model.activeText.characters
        model.activeText.insert(AttributedString("A\nB\nC"), at: text.index(text.startIndex, offsetBy: 2))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 7))
        model.activeTextChanged()
        while model.active?.ref.id != "c" { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.enters.isEmpty)
        let paste = try #require(engine.enteredLines.first)
        #expect(engine.enteredLines.count == 1)
        #expect(paste.node.plainText == "xyA")
        #expect(paste.lines.map { $0.map(\.plainText).joined() } == ["B", "Cz"])
        #expect(model.cursorRequest == .offset(1))
    }

    /// Two pasted lines are one Return, and the cursor goes where the paste ends too, not to the new line's start.
    @Test(.timeLimit(.minutes(1))) func twoPastedLinesPutTheCursorAtTheirEnd() async throws {
        func line(_ id: String, _ text: String) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: text)])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [line("a", "xyz")]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: line("a", "xyz")), node: line("a", "xyz"))
        engine.enterResult = .moved(EngineCursor(path: [1], offset: 0))
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [line("a", "xyA"), line("b", "Bz")]) }

        let text = model.activeText.characters
        model.activeText.insert(AttributedString("A\nB"), at: text.index(text.startIndex, offsetBy: 2))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 5))
        model.activeTextChanged()
        while model.active?.ref.id != "b" { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.enteredLines.isEmpty)
        #expect(engine.enters.first?.node.plainText == "xyA" && engine.enters.first?.after.map(\.plainText) == ["Bz"])
        #expect(model.cursorRequest == .offset(1))
    }

    /// A toggle's title stays whole as on Return there: pasted lines keep what was after the cursor in the title and go
    /// into its content, also two lines (the paste proxy hands plain text to `pasteLink`). Pasted by the text view, they
    /// all ran together in the title.
    @Test(.timeLimit(.minutes(1))) func pastedLinesKeepAToggleTitleWhole() async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "TiTel")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            PMNode(type: "details", attrs: ["open": .bool(true)], content: [title, PMNode(type: "detailsContent", content: [PMNode(type: "paragraph")])]),
        ]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0, 0], node: title), node: title)
        engine.enterResult = .moved(EngineCursor(path: [0, 1, 0], offset: 0))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 2))

        #expect(model.pasteLink("A\r\nB"))
        while engine.enteredLines.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.enters.isEmpty)
        let paste = try #require(engine.enteredLines.first)
        #expect(paste.node.plainText == "TiATel")
        #expect(paste.lines.map { $0.map(\.plainText).joined() } == ["B"])
    }

    /// Lines dictated into a toggle's title (no paste to say where the cursor was) don't cut the title at a cursor the text
    /// view may not have moved yet: the title keeps the first line, the others go into its content.
    @Test(.timeLimit(.minutes(1))) func dictatedLinesDontCutATitle() async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "TiTel")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            PMNode(type: "details", attrs: ["open": .bool(true)], content: [title, PMNode(type: "detailsContent", content: [PMNode(type: "paragraph")])]),
        ]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0, 0], node: title), node: title)
        engine.enterResult = .moved(EngineCursor(path: [0, 1, 0], offset: 0))

        let text = model.activeText.characters
        model.activeText.insert(AttributedString("A\nB\nC"), at: text.index(text.startIndex, offsetBy: 2))
        model.activeTextChanged()
        while engine.enteredLines.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        let lines = try #require(engine.enteredLines.first)
        #expect(lines.node.plainText == "TiA")
        #expect(lines.lines.map { $0.map(\.plainText).joined() } == ["B", "CTel"])
    }

    /// A typed Return, its cursor right after the break, stays one Return, also in a toggle's title.
    @Test(.timeLimit(.minutes(1))) func typedReturnStaysOneReturn() async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "TiTel")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            PMNode(type: "details", attrs: ["open": .bool(true)], content: [title, PMNode(type: "detailsContent", content: [PMNode(type: "paragraph")])]),
        ]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0, 0], node: title), node: title)
        engine.enterResult = .moved(EngineCursor(path: [0, 1, 0], offset: 0))

        let text = model.activeText.characters
        model.activeText.insert(AttributedString("\n"), at: text.index(text.startIndex, offsetBy: 2))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 3))
        model.activeTextChanged()
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.enteredLines.isEmpty)
        #expect(engine.enters.first?.node.plainText == "Ti")
    }

    /// A toggle without `open` is closed, as on the web: Backspace in the empty line after it, which the engine removes,
    /// goes to its title, not into its hidden content.
    @Test(.timeLimit(.minutes(1))) func toggleWithoutOpenIsClosed() async throws {
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")])
        let content = PMNode(type: "detailsContent", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Inhalt")])])
        let line = PMNode(type: "paragraph")
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "details", content: [title, content]), line]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [1], node: line), node: line)
        engine.backspaceResult = .done(.remove, cursor: nil)

        #expect(model.backspaceAtStart())
        while model.active?.ref.path == [1] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.active?.ref.path == [0, 0])
    }

    /// Typing right before Return: the save's document event can arrive while Return is in flight; the cursor still goes
    /// into the new paragraph, not the block after it.
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
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.sendDocument()  // Return's own document event

        #expect(engine.enters.map(\.node.plainText) == ["Eins!"])
        #expect(model.active?.ref == NodeRef(path: [1], id: "c"))
    }

    /// "/" and the toolbar offer what the engine says the line can turn into, in the menus' order: none for a toggle's
    /// title or a footnote's text, a heading for an item's only line (Engine/tools/conversions-check.ts has the rules).
    /// Until the engine has answered, everything but in a toggle's title or a footnote's text, and it refuses what
    /// doesn't fit.
    @Test(.timeLimit(.minutes(1))) func conversionsAreTheEngines() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "x")])
        let title = PMNode(type: "detailsSummary", content: [PMNode(type: "text", text: "Titel")])
        let toggle = PMNode(type: "details", attrs: ["open": .bool(true)], content: [title, PMNode(type: "detailsContent", content: [PMNode(type: "paragraph")])])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [line, toggle]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [1, 0], node: title), node: title)
        #expect(model.conversionTemplates.isEmpty)
        model.activate(NodeRef(path: [0], node: line), node: line)
        #expect(model.conversionTemplates == [.paragraph, .heading1, .heading2, .heading3, .bulletList, .orderedList, .taskList, .quote, .callout, .toggle, .codeBlock])

        engine.conversionKinds = ["quote", "paragraph", "taskList", "syncedBlock"]
        engine.sendDocument()
        while model.answers?.conversions == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.conversionTemplates == [.paragraph, .taskList, .quote])

        engine.conversionKinds = []
        engine.sendDocument()
        while model.answers?.conversions != [] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.conversionTemplates.isEmpty)
    }

    /// The kind of the item's list already does nothing: editing goes on in the line, and the engine isn't asked.
    @Test func itsOwnListKindDoesNothing() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [line])]),
        ]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        model.convertActive(to: .bulletList)
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.converted.isEmpty)
        #expect(model.active?.ref.id == "a")
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
    /// space), the card, the text after. Whether the card fits there is the engine's to say, asked with those blocks in
    /// the paragraph's place, as the web asks its schema (not in place of a list item's first line, nor in a table
    /// cell); a heading is no paragraph to split.
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

        let refused: [BlockTarget] = [.path([1, 0, 0], type: "paragraph"), .path([2, 0, 0, 0], type: "paragraph")]
        engine.fitting = { place, _ in !refused.contains { $0 == place.target } }
        #expect(try await !model.canShowAsCard(target([1, 0, 0])))
        #expect(try await !model.canShowAsCard(target([2, 0, 0, 0])))
        #expect(try await !model.canShowAsCard(target([3])))
        #expect(engine.fitQuestions.count == 2)
        let first = try target([0])
        #expect(await model.canShowAsCard(first))
        let card = [
            PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Siehe")]),
            PMNode(type: "integrationCard", attrs: ["url": .string(url), "provider": "github"]),
            PMNode(type: "paragraph", content: [PMNode(type: "text", text: "danach")]),
        ]
        #expect(engine.fitQuestions.last?.place == BlockPlace(target: .path([0], type: "paragraph"), position: .replace))
        #expect(engine.fitQuestions.last?.candidates == [card])
        await model.showMention(first, as: .card)
        #expect(engine.replacedWith.last == [
            PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Siehe")]),
            PMNode(type: "integrationCard", attrs: ["url": .string(url), "provider": "github"]),
            PMNode(type: "paragraph", content: [PMNode(type: "text", text: "danach")]),
        ])
    }

    /// A mention shown as a card is made from its paragraph as the engine holds it, which a collaborator typed into while
    /// the page's copy lagged behind: their words stay. A mention that went in before it since isn't the one shown.
    @Test func mentionAsCardKeepsACollaboratorsWords() async throws {
        let url = "https://github.com/o/r/issues/1"
        let mention = PMNode(type: "integrationMention", attrs: ["url": .string(url), "provider": "github"])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "p1"], content: [PMNode(type: "text", text: "Siehe "), mention])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let model = try Self.model(engine)
        let target = DocumentModel.MentionTarget(ref: NodeRef(path: [0], node: paragraph), index: 0, url: url, provider: "github")

        let typed = PMNode(type: "paragraph", attrs: ["id": "p1"], content: [PMNode(type: "text", text: "Siehe auch "), mention])
        engine.document = PMNode(type: "doc", content: [typed])
        await model.showMention(target, as: .card)
        #expect(engine.replacedWith.last == [
            PMNode(type: "paragraph", attrs: ["id": "p1"], content: [PMNode(type: "text", text: "Siehe auch")]),
            PMNode(type: "integrationCard", attrs: ["url": .string(url), "provider": "github"]),
        ])
        #expect(engine.expectations.last == typed)

        let other = PMNode(type: "integrationMention", attrs: ["url": "https://github.com/o/r/issues/2", "provider": "github"])
        engine.document = PMNode(type: "doc", content: [
            PMNode(type: "paragraph", attrs: ["id": "p1"], content: [other, PMNode(type: "text", text: " "), mention]),
        ])
        await model.showMention(target, as: .card)
        #expect(engine.replacedWith.count == 1)
        #expect(model.errorMessage != nil)
    }

    /// A link shown as a card in the line being edited: the line's input goes in first, with its base, and the card's
    /// blocks take the line's place only while it is what they were made from. A collaborator's words in it since make
    /// the engine refuse them; written over the line unchecked, they were gone.
    @Test(.timeLimit(.minutes(1))) func cardInTheActiveLineKeepsACollaboratorsWords() async throws {
        let url = "https://github.com/o/r/issues/1"
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "p1"], content: [
            PMNode(type: "text", text: "Siehe "), PMNode(type: "text", marks: [PMMark(type: "link", attrs: ["href": .string(url)])], text: url),
        ])
        func editing() async throws -> (FakeDocumentEngine, DocumentModel) {
            let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
            let model = try Self.model(engine)
            model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
            while model.answers == nil { try await Task.sleep(for: .milliseconds(10)) }
            return (engine, model)
        }
        func showCard(_ engine: FakeDocumentEngine, _ model: DocumentModel) async throws {
            let link = try #require(model.activeText.runs.first { $0.link != nil }?.range)
            model.showLink(in: link, provider: "github", as: .card)
            while engine.replacedWith.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }

        // Nobody else in the line: the card goes in, against the line as the editor showed it.
        var (engine, model) = try await editing()
        try await showCard(engine, model)
        #expect(engine.replacedWith.last == [
            PMNode(type: "paragraph", attrs: ["id": "p1"], content: [PMNode(type: "text", text: "Siehe")]),
            PMNode(type: "integrationCard", attrs: ["url": .string(url), "provider": "github"]),
            PMNode(type: "paragraph"),
        ])
        #expect(engine.expectations.last == paragraph)

        // Typed on while a collaborator typed in the line: the input is saved, and the card refused.
        (engine, model) = try await editing()
        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        engine.collaboratorEdit = {
            engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "p1"], content: [
                PMNode(type: "text", text: "Siehe auch "), PMNode(type: "text", marks: [PMMark(type: "link", attrs: ["href": .string(url)])], text: url),
            ])])
        }
        try await showCard(engine, model)
        #expect(engine.saved.last?.plainText == "Siehe \(url)!")
        #expect(engine.expectations.last == engine.saved.last)
        #expect(model.errorMessage != nil)
    }

    /// A pasted link to a page of this server becomes a mention of it, with the anchor, as on the web; a query such as
    /// `?commentId=` doesn't count, and a page that can't be found stays a link.
    @Test(.timeLimit(.minutes(1))) func pastedPageLinkBecomesAMention() async throws {
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Hallo ")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.dependencies.serverURL = URL(string: "https://wiki.example.com")
        model.dependencies.currentUserId = "u1"
        let target = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p2","slugId":"Ab12","title":"Ziel"}"#.utf8))
        model.dependencies.lookUpPage = { slugId in slugId == "Ab12" ? target : nil }
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
        model.dependencies.serverURL = URL(string: "https://wiki.example.com")
        let target = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p2","slugId":"Ab12","title":"́Spec"}"#.utf8))
        model.dependencies.lookUpPage = { _ in target }
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
        model.dependencies.serverURL = URL(string: "https://wiki.example.com")
        let target = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p2","slugId":"Ab12","title":"Ziel"}"#.utf8))
        var answer: CheckedContinuation<Page?, Never>?
        model.dependencies.lookUpPage = { _ in await withCheckedContinuation { answer = $0 } }
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

        engine.convertResult = .moved(EngineCursor(path: [0, 0], offset: 4))

        await model.wrapActiveInSyncedBlock()
        engine.sendDocument()  // the wrap's own document event

        #expect(engine.converted.first?.kind == "syncedBlock")
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
        engine.enterResult = .moved(EngineCursor(path: [0], offset: 0))
        engine.whileInserting = {
            engine.sendDocument()  // an event from before Return
            engine.document = PMNode(type: "doc", content: [paragraph("c", nil), paragraph("b", "Zwei")])
        }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.sendDocument()  // Return's own document event

        #expect(model.active?.ref == NodeRef(path: [0], id: "c"))
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
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let new = try #require(model.active?.ref)
        model.editorFocusChanged(true, instance: UUID(), ref: new)  // when an inline command would run

        #expect(new == NodeRef(path: [1], id: "b"))
        #expect(String(model.activeText.characters).isEmpty)
        #expect(engine.enters.map(\.node.plainText) == ["Eins"])
    }

    /// Floating "+" → Date: the date goes into the new paragraph at the end once its editor has focus, not before (an
    /// emoji keyboard or sheet opened sooner would take that focus away), and only into that paragraph.
    @Test(.timeLimit(.minutes(1))) func endInlineCommandWaitsForItsEditorsFocus() async throws {
        func paragraph(_ id: String, _ text: String?) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.map { [PMNode(type: "text", text: $0)] })
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", nil)]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()

        model.performAtEnd(.date)
        while model.active == nil { try await Task.sleep(for: .milliseconds(10)) }
        let end = NodeRef(path: [1], id: "b")
        #expect(model.active?.ref == end)
        try await Task.sleep(for: .milliseconds(100))
        #expect(String(model.activeText.characters).isEmpty)

        model.editorFocusChanged(true, instance: UUID(), ref: NodeRef(path: [0], id: "a"))
        #expect(String(model.activeText.characters).isEmpty)
        model.editorFocusChanged(true, instance: UUID(), ref: end)
        let date = String(model.activeText.characters)
        #expect(!date.isEmpty)
        // Once only: focus coming back (after a sheet) adds nothing.
        model.editorFocusChanged(true, instance: UUID(), ref: end)
        #expect(String(model.activeText.characters) == date)
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

    /// The cursor after an insert goes where the engine put the new blocks. The page's copy lags behind a collaborator who
    /// removed a block above meanwhile: counted there, the cursor went into the paragraph after the new one, and the next
    /// words with it.
    @Test func insertFocusesWhereTheEnginePutTheBlocks() async throws {
        func paragraph(_ id: String, _ text: String = "") -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.isEmpty ? nil : [PMNode(type: "text", text: text)])
        }
        let line = paragraph("a", "Zeile")
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("z", "Weg"), line]))
        let model = try Self.model(engine)
        // The engine's page once the divider is in: the block above gone, a paragraph a collaborator added below.
        engine.document = PMNode(type: "doc", content: [line, PMNode(type: "horizontalRule"), paragraph("new"), paragraph("y", "Danach")])
        await model.insertBlocks([PMNode(type: "horizontalRule")], placement: .replaceOrAfter(NodeRef(path: [1], node: line)), focus: .after)
        #expect(engine.inserted.map(\.node.type) == ["horizontalRule", "paragraph"])
        #expect(model.active?.ref.id == "new")
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

    /// A conversion the engine refuses (the line is gone, or what it turns into doesn't fit there by now): the page says
    /// so. Converting ends editing the line first, as it did.
    @Test func refusedConversionSaysSo() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [line]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: line), node: line)

        await model.convert(NodeRef(path: [0], node: line), to: .quote)

        #expect(engine.converted.first?.target == .id("a") && engine.converted.first?.kind == "quote")
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
        #expect(model.active == nil)
    }

    /// A collaborator's edit that lands between reading a block and replacing it (a card or mention in a line's place):
    /// the engine refuses the replacement, and the page says so instead of overwriting the edit.
    @Test func structuralEditIsRefusedWhenTheBlockChanged() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list("bulletList", ["Eins", "Zwei"])]))
        let model = try Self.model(engine)
        engine.collaboratorEdit = { engine.document = PMNode(type: "doc", content: [Self.list("bulletList", ["Eins", "Zwei!"])]) }
        let list = try #require(model.node(at: [0]))

        await model.replace(NodeRef(path: [0], node: list), withNodes: [PMNode(type: "paragraph")])

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

    /// The menus offer blocks where the engine says they fit, where they'd go. "/" in a synced block puts them after its
    /// line, inside it, which holds no page breaks, databases or synced blocks; "+" after the synced block, where they all
    /// fit. The app's own copy of the rules offered page breaks and databases there.
    @Test(.timeLimit(.minutes(1))) func menusOfferBlocksWhereTheEngineSaysTheyFit() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "s"], content: [PMNode(type: "text", text: "Synced")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            PMNode(type: "transclusionSource", attrs: ["id": "t"], content: [line]),
        ]))
        let notInSyncedBlocks: Set<String> = ["pageBreak", "base", "transclusionSource", "transclusionReference"]
        engine.fitting = { place, nodes in place.target != .id("s") || !nodes.contains { notInSyncedBlocks.contains($0.type) } }
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        model.activate(NodeRef(path: [0, 0], node: line), node: line)
        while model.answers == nil { try await Task.sleep(for: .milliseconds(10)) }

        model.togglePlusMenu()
        #expect(model.insertMatches.contains(.pageBreak) && model.insertMatches.contains(.base))
        model.togglePlusMenu()
        model.activeText.append(AttributedString(" /"))
        model.activeSelection = AttributedTextSelection(insertionPoint: model.activeText.endIndex)
        model.activeTextChanged()
        #expect(model.slashQuery == "")
        let offered = model.insertMatches
        #expect(!offered.contains(.pageBreak) && !offered.contains(.base) && !offered.contains(.kanban) && !offered.contains(.syncedBlock))
        #expect(offered.contains(.block(.table)) && offered.contains(.block(.divider)) && offered.contains(.date))
        let places = engine.fitQuestions.map(\.place)
        #expect(places.contains(BlockPlace(target: .id("s"), position: .after)) && places.contains(BlockPlace(target: .id("t"), position: .after)))
    }

    /// "/Database" where a database doesn't fit creates no database page on the server (it did, before its block
    /// failed to go in) and says why.
    @Test(.timeLimit(.minutes(1))) func databaseIsCreatedOnlyWhereItFits() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "s"])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [
            PMNode(type: "transclusionSource", attrs: ["id": "t"], content: [line]),
        ]))
        engine.fitting = { _, nodes in !nodes.contains { $0.type == "base" } }
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        var created = 0
        model.dependencies.canCreateBases = true
        model.dependencies.createBase = { _ in
            created += 1
            return "base"
        }
        engine.sendDocument()
        model.activate(NodeRef(path: [0, 0], node: line), node: line)
        model.perform(.base)
        while model.notice == nil && created == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(created == 0 && model.notice == String(localized: "This can't be placed there."))
        #expect(engine.inserted.isEmpty && engine.replacedWith.isEmpty)
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
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
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

    /// Return the engine refuses (its line is gone or changed meanwhile) leaves the line as typed, without the line break,
    /// and says so until a later save succeeds; saved at once, the line hid the message.
    @Test(.timeLimit(.minutes(1))) func refusedReturnKeepsTheLineAndSaysSo() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "EinsZwei")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: first), node: first)
        engine.enterResult = .refused
        model.activeText.insert(AttributedString("\n"), at: model.activeText.characters.index(model.activeText.startIndex, offsetBy: 4))
        model.activeTextChanged()
        while model.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.errorMessage != nil)
        #expect(String(model.activeText.characters) == "EinsZwei" && model.active?.ref.id == "a")

        model.activeText.append(AttributedString("x"))
        model.activeTextChanged()
        await model.flush()
        #expect(model.errorMessage == nil)
        #expect(engine.saved.last?.plainText == "EinsZweix")
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

    /// A page with content the bundled editor would change on opening it (the engine's `bindingChanges`, checked in
    /// `pnpm run check`): the engine closes it, and the page is read-only, saying the web editor can edit it.
    @Test func contentTheEditorWouldChangeMakesThePageReadOnly() throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        #expect(model.isEditable)
        engine.onFailure?(.unsupportedContent)
        #expect(!model.isEditable)
        #expect(model.errorMessage == String(localized: "This page has content that this version of the app can't edit yet. You can edit it in the web editor."))
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
        let clock = TestClock()
        model.dependencies.clock = clock
        let line = try #require(model.node(at: [0]))
        model.activate(NodeRef(path: [0], node: line), node: line)
        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        await model.flush()
        engine.unconfirmedChanges = unconfirmed
        engine.sendDocument(doc("Hello!"))  // the engine's document event for the change

        await clock.advance(by: .seconds(2))
        // Writing the unsent changes can take longer than the clock's turns of the main actor.
        while unconfirmed > 0, engine.lifecycle.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.lifecycle == (unconfirmed == 0 ? [] : ["save after 1"]))
    }

    /// A deleted inline comment's passage loses its mark on the whole page (the engine's `unsetComment`), and first in
    /// the text being edited, saved: its input would bring the mark back with its next save.
    @Test(.timeLimit(.minutes(1))) func deletedCommentLosesItsMark() async throws {
        let marked = PMNode(type: "paragraph", attrs: ["id": "a"], content: [
            PMNode(type: "text", text: "Vor "),
            PMNode(type: "text", marks: [PMMark(type: "comment", attrs: ["commentId": "c1"])], text: "markiert"),
        ])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [marked]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: marked), node: marked)
        #expect(model.activeText.runs[DocmostAttributes.CommentAttribute.self].contains { $0.0 == "c1" })

        await model.removeMarks(ofComment: "c1")
        #expect(!model.activeText.runs[DocmostAttributes.CommentAttribute.self].contains { $0.0 != nil })
        #expect(engine.saved.last?.plainText == "Vor markiert")
        #expect(engine.saved.last?.children.allSatisfy { $0.marks?.contains { $0.type == "comment" } != true } == true)
        #expect(engine.unsetComments == ["c1"])

        // Not editing: only the engine's.
        model.deactivate()
        let saves = engine.saved.count
        await model.removeMarks(ofComment: "c2")
        #expect(engine.saved.count == saves)
        #expect(engine.unsetComments == ["c1", "c2"])
    }

    /// Typing on doesn't push the save of unconfirmed changes back: it comes 2 s after the first change not kept, with
    /// the later ones. Pushed back by each document event, typing with pauses under 2 s kept nothing until a longer pause,
    /// and an ended web process or app lost all of it.
    @Test(.timeLimit(.minutes(1))) func typingOnDoesntPushTheUnsentSaveBack() async throws {
        func doc(_ text: String) -> PMNode {
            PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: text)])])
        }
        let engine = FakeDocumentEngine(document: doc("Hello"))
        engine.status = .disconnected
        let model = try Self.model(engine)
        let clock = TestClock()
        model.dependencies.clock = clock
        engine.unconfirmedChanges = 1
        engine.sendDocument(doc("Hello!"))
        await clock.advance(by: .milliseconds(1500))
        engine.unconfirmedChanges = 2
        engine.sendDocument(doc("Hello!!"))
        #expect(engine.lifecycle.isEmpty)

        await clock.advance(by: .milliseconds(500))
        for _ in 0..<100 where engine.lifecycle.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.lifecycle == ["save after 0"])
        // The next change schedules the next save.
        engine.unconfirmedChanges = 3
        engine.sendDocument(doc("Hello!!!"))
        await clock.advance(by: .seconds(2))
        for _ in 0..<100 where engine.lifecycle.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.lifecycle == ["save after 0", "save after 0"])
    }

    /// Unsent changes the device can't keep (a full disk) put a banner on the page while the server hasn't confirmed
    /// them: they live only in the engine then, lost if the app ends. Only the log said so. It goes once the server has
    /// everything, and for good once a save keeps them.
    @Test(.timeLimit(.minutes(1))) func unsentChangesTheDeviceCantKeepShowABanner() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        engine.unconfirmedChanges = 1
        engine.unsentChangesError = CocoaError(.fileWriteOutOfSpace)
        await model.saveUnsentChanges()
        #expect(model.unsentWarning == String(localized: "Changes can't be kept on this device: its storage is full. Until the server has them, they're lost if the app ends."))

        engine.unconfirmedChanges = 0
        #expect(model.unsentWarning == nil)
        engine.unconfirmedChanges = 1
        #expect(model.unsentWarning != nil)
        engine.unsentChangesError = nil
        await model.saveUnsentChanges()
        #expect(model.unsentWarning == nil)
    }

    /// Unsent changes not kept as their page closes tell the whole app, naming the page: what the server didn't get
    /// went with the engine, and the page's banner is gone with it.
    @Test(.timeLimit(.minutes(1))) func unsentChangesNotKeptOnLeavingTellTheApp() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p","title":"Projektplan"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        var notices: [String] = []
        model.dependencies.postAppNotice = { notices.append($0) }
        engine.unconfirmedChanges = 1
        engine.unsentChangesError = POSIXError(.ENOSPC)
        await model.saveUnsentChanges()
        #expect(model.unsentNotKept != nil)
        model.leave()
        while engine.lifecycle.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.lifecycle == ["save after 0", "close"])
        let title = "Projektplan"
        #expect(notices == [String(localized: "Changes to “\(title)” may be lost: this device's storage is full.")])
        #expect(model.unsentNotKept == nil)
    }

    /// A full disk is said in words, also behind another error; other failures get the general sentence. Foundation's
    /// own message names the store's file.
    @Test func fullStorageIsSaidInWords() {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                 userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC) as NSError])
        for error: any Error in [CocoaError(.fileWriteOutOfSpace), POSIXError(.ENOSPC), POSIXError(.EDQUOT), underlying] {
            #expect(UnsentChanges.isOutOfSpace(error), "\(error)")
        }
        for error: any Error in [CocoaError(.fileWriteNoPermission), POSIXError(.EACCES), URLError(.notConnectedToInternet)] {
            #expect(!UnsentChanges.isOutOfSpace(error), "\(error)")
        }
        #expect(UnsentChanges.notKeptWarning(CocoaError(.fileWriteNoPermission))
                == String(localized: "Changes can't be kept on this device. Until the server has them, they're lost if the app ends."))
        let title = "Projektplan"
        #expect(UnsentChanges.mayBeLostNotice(title: title, CocoaError(.fileWriteNoPermission))
                == String(localized: "Changes to “\(title)” may be lost: they couldn't be kept on this device."))
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

    /// A save waits for more input on the model's clock: not before the wait has passed, at once after it. Tests of a save,
    /// or of none, need no real time with it (`TestClock`), and don't pass while the main actor is busy elsewhere.
    @Test(.timeLimit(.minutes(1))) func aSaveWaitsForMoreInputOnTheModelsClock() async throws {
        let line = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [line]))
        let model = try Self.model(engine)
        let clock = TestClock()
        model.dependencies.clock = clock
        model.activate(NodeRef(path: [0], node: line), node: line)
        model.activeText.append(AttributedString("!"))
        model.activeTextChanged()
        await clock.advance(by: .milliseconds(399))
        #expect(engine.saved.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(engine.saved.map(\.plainText) == ["Eins!"])
    }

    /// Moving the cursor to another block writes nothing back when nothing was typed: the untouched block overwrote
    /// what a collaborator typed there in the next 400 ms.
    @Test(.timeLimit(.minutes(1))) func switchingBlocksWritesNothingBack() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: [PMNode(type: "text", text: "Zwei")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
        let model = try Self.model(engine)
        let clock = TestClock()
        model.dependencies.clock = clock

        model.activate(NodeRef(path: [0], node: first), node: first)
        model.activeTextChanged()  // the editor reporting the text it was given
        model.activate(NodeRef(path: [1], node: second), node: second)
        model.activeTextChanged()
        await clock.advance(by: .milliseconds(400))

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
        let clock = TestClock()
        model.dependencies.clock = clock
        model.activate(NodeRef(path: [1], node: code), node: code)

        model.activeCode += "2"
        model.activeCodeChanged()
        engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"]), divider, code])
        engine.sendDocument()
        await clock.advance(by: .milliseconds(400))  // as long as a save waits for more input

        #expect(model.active == nil)
        #expect(engine.saved.isEmpty)
    }

    /// A join the engine refuses (the block before changed meanwhile), shown at once: editing ends without saving the
    /// shown text, which would put the line's text into the block before a second time, and the page says so.
    @Test(.timeLimit(.minutes(1))) func refusedJoinSaysSo() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: [PMNode(type: "text", text: "Zwei")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
        let model = try Self.model(engine)
        engine.plans = BackspacePlans(empty: .join([0]), text: .join([0]))
        model.activate(NodeRef(path: [1], node: second), node: second)
        while model.answers?.backspace == nil { try await Task.sleep(for: .milliseconds(10)) }
        engine.backspaceResult = .refused

        #expect(model.backspaceAtStart())
        while engine.backspaces.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.backspaces.first?.node.plainText == "Zwei")
        #expect(engine.saved.isEmpty)
        #expect(model.errorMessage == String(localized: "The change could not be applied."))
        #expect(model.active == nil)
    }

    /// A join shown at once that the engine doesn't do (a collaborator changed the page around the line meanwhile, and
    /// Backspace does nothing there now): editing ends without saving the shown text, as for a refused one.
    @Test(.timeLimit(.minutes(1))) func joinTheEngineDoesOtherwiseEndsEditing() async throws {
        let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: [PMNode(type: "text", text: "Zwei")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
        let model = try Self.model(engine)
        let clock = TestClock()
        model.dependencies.clock = clock
        engine.plans = BackspacePlans(empty: .join([0]), text: .join([0]))
        model.activate(NodeRef(path: [1], node: second), node: second)
        while model.answers?.backspace == nil { try await Task.sleep(for: .milliseconds(10)) }
        engine.backspaceResult = .done(.nothing, cursor: nil)

        #expect(model.backspaceAtStart())
        while engine.backspaces.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await clock.advance(by: .milliseconds(400))  // as long as a save waits for more input

        #expect(model.active == nil)
        #expect(engine.saved.isEmpty)
    }

    /// Backspace at a block's start puts the cursor where the two texts meet, counted in the editor's characters: a
    /// mention ("@Alice") or a line break isn't its plain text, and typing landed inside the sentence before. The same
    /// shown at once (the engine said where Backspace goes) and once the engine joined them (it hadn't said yet), where
    /// the engine's place counts as it does.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false]) func joinPutsTheCursorWhereTheTextsMeet(shownAtOnce: Bool) async throws {
        let alice = PMNode(type: "mention", attrs: ["id": "m1", "label": "Alice", "entityType": "user", "entityId": "u1"])
        let bob = PMNode(type: "mention", attrs: ["id": "m2", "label": "Bob", "entityType": "user", "entityId": "u2"])
        func text(_ value: String) -> PMNode { PMNode(type: "text", text: value) }
        let cases: [(previous: [PMNode], current: [PMNode], offset: Int)] = [
            ([text("Call "), alice, text(" about")], [text("the budget")], 17),
            ([text("a"), PMNode(type: "hardBreak"), text("b")], [text("c")], 3),
            ([text("Call "), alice, text(" and "), bob], [], 20),
            ([text("Grüße 👋🏽")], [text("!")], 7),
        ]
        for (previous, current, offset) in cases {
            let first = PMNode(type: "paragraph", attrs: ["id": "a"], content: previous)
            let second = PMNode(type: "paragraph", attrs: ["id": "b"], content: current.isEmpty ? nil : current)
            let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [first, second]))
            let model = try Self.model(engine)
            if shownAtOnce { engine.plans = BackspacePlans(empty: .join([0]), text: .join([0])) }
            let size = previous.reduce(0) { $0 + ($1.text?.utf16.count ?? 1) }
            engine.backspaceResult = .done(.join([0]), cursor: EngineCursor(path: [0], offset: size))
            engine.whileInserting = { engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"], content: previous + current)]) }
            model.activate(NodeRef(path: [1], node: second), node: second)
            if shownAtOnce { while model.answers?.backspace == nil { try await Task.sleep(for: .milliseconds(10)) } }

            #expect(model.backspaceAtStart())
            while model.active?.ref.path != [0] { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.cursorRequest == .offset(offset))
        }
    }

    /// Backspace's join shows at once only where the page shows the block the engine names right before the line, as the
    /// engine's answers can come from a document the page doesn't show yet: a collaborator removed the first line, so the
    /// engine's first line is the page's second. The model waits for the engine and puts the cursor where it says.
    @Test(.timeLimit(.minutes(1))) func joinShowsAtOnceOnlyWhereThePageAgrees() async throws {
        func paragraph(_ id: String, _ text: String) -> PMNode {
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: text)])
        }
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph("a", "Eins"), paragraph("b", "Zwei"), paragraph("c", "Drei")]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [2]))
        engine.plans = BackspacePlans(empty: .join([0]), text: .join([0]))  // in the engine's document without "Eins"
        model.activate(NodeRef(path: [2], node: line), node: line)
        while model.answers?.backspace == nil { try await Task.sleep(for: .milliseconds(10)) }
        engine.backspaceResult = .done(.join([0]), cursor: EngineCursor(path: [0], offset: 4))
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [paragraph("b", "ZweiDrei")]) }

        #expect(model.backspaceAtStart())
        while engine.backspaces.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.active?.ref.id == "b")
        #expect(String(model.activeText.characters) == "ZweiDrei")
        #expect(model.cursorRequest == .offset(4))
    }

    /// Code turned into text keeps its lines as line breaks (Engine/tools/conversions-check.ts), and the text doesn't
    /// split into blocks on the next key: its line breaks aren't Return.
    @Test(.timeLimit(.minutes(1))) func textFromCodeKeepsItsLineBreaks() async throws {
        let code = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "SELECT *\nFROM t")])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [
            PMNode(type: "text", text: "SELECT *"), PMNode(type: "hardBreak"), PMNode(type: "text", text: "FROM t"),
        ])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [code]))
        let model = try Self.model(engine)
        engine.convertResult = .moved(EngineCursor(path: [0], offset: 15))
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [paragraph]) }

        await model.convert(NodeRef(path: [0], node: code), to: .paragraph)
        #expect(engine.converted.map(\.kind) == ["paragraph"])
        #expect(model.active?.type == "paragraph")
        model.activeText.append(AttributedString("x"))
        model.activeTextChanged()
        await model.flush()

        #expect(engine.enters.isEmpty)
        #expect(engine.saved.last?.children.map(\.type) == ["text", "hardBreak", "text"])
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

    /// The engine's event for the change can come before the cursor moves (it follows the read the cursor waits for,
    /// and the system pauses the engine at times): editing goes on meanwhile, although the item went. It ended there, and
    /// the keyboard hid and showed again (EditorUITests' test16 on a busy simulator).
    @Test(.timeLimit(.minutes(1))) func editingGoesOnWhileLeavingAList() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", nil)])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        var editsMeanwhile: Bool?
        engine.whileInserting = {
            engine.sendDocument(PMNode(type: "doc", content: [Self.list([("a", "Eins")]), PMNode(type: "paragraph", attrs: ["id": "n"])]))
            editsMeanwhile = model.active != nil
        }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(editsMeanwhile == true, "Editing ended while the cursor moved")
        #expect(model.active?.ref == NodeRef(path: [1], id: "n"))
    }

    /// Return whose cursor finds no place (the new item isn't in the engine's document) ends editing once it's done, if
    /// a collaborator removed the block meanwhile, as a collaborator's removal does otherwise.
    @Test(.timeLimit(.minutes(1))) func returnWithoutAPlaceEndsEditingInARemovedBlock() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", "Zwei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        engine.enterResult = .moved(EngineCursor(path: [0, 1, 0], offset: 0))
        engine.whileInserting = {
            engine.whileInserting = nil
            engine.sendDocument(PMNode(type: "doc", content: [Self.list([("b", "Zwei")])]))
        }

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.active == nil)
    }

    /// Leaving a list that the engine refuses changes nothing and says so; the cursor stays in the item.
    @Test(.timeLimit(.minutes(1))) func refusedLiftSaysSo() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", nil), ("c", "Drei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        engine.enterResult = .refused

        model.activeText.append(AttributedString("\n"))
        model.activeTextChanged()
        while engine.enters.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.errorMessage == String(localized: "The change could not be applied."))
        #expect(model.active?.ref.id == "b")
    }

    /// Backspace in an empty first item leaves the list, as the engine decides (Engine/tools/keys-check.ts): the cursor
    /// goes into the line it puts before the list, once the engine's document holds it.
    @Test(.timeLimit(.minutes(1))) func backspaceLeavingAListFocusesTheNewLine() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", nil), ("b", "Zwei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 0, 0]))
        model.activate(NodeRef(path: [0, 0, 0], node: line), node: line)
        engine.backspaceResult = .done(.leave, cursor: EngineCursor(path: [0], offset: 0))
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "n"]), Self.list([("b", "Zwei")])])
        }

        #expect(model.backspaceAtStart())
        while model.active?.ref.id != "n" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.active?.ref == NodeRef(path: [0], id: "n"))
    }

    /// "/Heading" in an item's only line goes to the engine as a conversion, which takes the line out of the list as the
    /// heading, as on the web (Engine/tools/conversions-check.ts); the cursor goes to its end.
    @Test(.timeLimit(.minutes(1))) func headingTakesLineOutOfList() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [Self.list([("a", "Eins"), ("b", "Zwei")])]))
        let model = try Self.model(engine)
        let line = try #require(model.node(at: [0, 1, 0]))
        model.activate(NodeRef(path: [0, 1, 0], node: line), node: line)
        engine.convertResult = .moved(EngineCursor(path: [1], offset: 4))
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [
                Self.list([("a", "Eins")]),
                PMNode(type: "heading", attrs: ["id": "h", "level": 2], content: [PMNode(type: "text", text: "Zwei")]),
            ])
        }

        model.convertActive(to: .heading2)
        while model.active?.ref.id != "h" { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.converted.first?.target == .id("b") && engine.converted.first?.kind == "heading2")
        #expect(model.active?.ref == NodeRef(path: [1], id: "h"))
        #expect(model.cursorRequest == .end)
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

    /// Unsync of a synced block embedded from another page: once the server answers, the engine finds the embed where it
    /// is by then (Engine/tools/conversions-check.ts), from where the page showed it and its source. A second tap's late
    /// answer, with the embed gone from the page, sends nothing.
    @Test func unsyncSendsTheEmbedsSource() async throws {
        let reference = PMNode(type: "transclusionReference", attrs: ["sourcePageId": "s", "transclusionId": "t"])
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph, reference]))
        let model = try Self.model(engine)
        let ref = NodeRef(path: [1], node: reference)
        let content = [PMNode(type: "paragraph", attrs: ["id": "c"], content: [PMNode(type: "text", text: "Inhalt")])]

        await model.unsyncReference(reference, at: ref, content: content)
        engine.document = PMNode(type: "doc", content: [paragraph] + content)
        engine.sendDocument()
        await model.unsyncReference(reference, at: ref, content: content)

        #expect(engine.replacedReferences.count == 1)
        let replaced = try #require(engine.replacedReferences.first)
        #expect(replaced.path == [1] && replaced.sourcePageId == "s" && replaced.transclusionId == "t" && replaced.nodes == content)
    }

    /// The column count goes to the engine as one command (Engine/tools/conversions-check.ts), the input typed in the
    /// columns first; editing in a column that merges into another ends. A synced block's source unsyncs the same way.
    @Test(.timeLimit(.minutes(1))) func columnsAndUnsyncGoToTheEngine() async throws {
        let lines = ["Links", "Mitte", "Rechts"].enumerated().map { index, text in
            PMNode(type: "paragraph", attrs: ["id": .string("l\(index)")], content: [PMNode(type: "text", text: text)])
        }
        let columns = PMNode(type: "columns", attrs: ["layout": "three_equal"], content: lines.map { PMNode(type: "column", content: [$0]) })
        let synced = PMNode(type: "paragraph", attrs: ["id": "q"], content: [PMNode(type: "text", text: "Quelle")])
        let source = PMNode(type: "transclusionSource", attrs: ["id": "s"], content: [synced])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [columns, source]))
        let model = try Self.model(engine)
        func typing(at path: [Int], _ line: PMNode) {
            model.activate(NodeRef(path: path, node: line), node: line)
            model.activeText.append(AttributedString("!"))
            model.activeTextChanged()
        }

        typing(at: [0, 0, 0], lines[0])
        await model.setColumnCount(4, at: [0])
        #expect(engine.saved.map(\.plainText) == ["Links!"])
        #expect(engine.columnCounts.first?.target == .path([0], type: "columns") && engine.columnCounts.first?.count == 4)
        #expect(model.active?.ref.id == "l0")

        typing(at: [0, 2, 0], lines[2])
        await model.setColumnCount(2, at: [0])
        #expect(engine.saved.last?.plainText == "Rechts!")
        #expect(engine.columnCounts.last?.count == 2)
        #expect(model.active == nil)

        typing(at: [1, 0], synced)
        await model.unsyncSource(NodeRef(path: [1], node: source))
        #expect(engine.saved.last?.plainText == "Quelle!")
        #expect(engine.unsynced == [.id("s")])
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

    /// A link and a line break added in the app come back from the engine with the attributes its schema fills in (the
    /// link's `rel`, `class` and `title`, the break's direction): no collaborator's change, so the editor keeps its text as
    /// it is. Inline content compares as the editor shows it.
    @Test(.timeLimit(.minutes(1))) func engineFilledAttributesAreNoCollaboratorsChange() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Docmost")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        let model = try Self.model(engine)
        model.activate(NodeRef(path: [0], node: paragraph), node: paragraph)
        model.activeText.link = URL(string: "https://docmost.com")
        model.activeText.append(AttributedString(String(InlineAttributedText.lineBreak) + "Wiki"))
        model.activeTextChanged()
        await model.flush()
        let link = PMMark(type: "link", attrs: ["href": "https://docmost.com", "target": "_blank", "internal": false])
        #expect(engine.saved.last?.children == [
            PMNode(type: "text", marks: [link], text: "Docmost"), PMNode(type: "hardBreak"), PMNode(type: "text", text: "Wiki"),
        ])
        let edited = model.activeText

        let filled = PMMark(type: "link", attrs: ["href": "https://docmost.com", "target": "_blank", "rel": "noopener noreferrer nofollow",
                                                  "class": .null, "title": .null, "internal": false])
        engine.sendDocument(PMNode(type: "doc", content: [
            PMNode(type: "paragraph", attrs: ["id": "a"], content: [
                PMNode(type: "text", marks: [filled], text: "Docmost"), PMNode(type: "hardBreak", attrs: ["dir": "auto"]),
                PMNode(type: "text", text: "Wiki"),
            ]),
        ]))
        try await Task.sleep(for: .milliseconds(200))

        #expect(model.activeText == edited)
    }

    /// An upload's error goes to the whole app, where it shows also once the page has closed: it went to the page's toast,
    /// which closed with it.
    @Test(.timeLimit(.minutes(1))) func uploadErrorIsToldAppWide() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph", attrs: ["id": "a"])]))
        let model = try Self.model(engine)
        var notices: [String] = []
        model.dependencies.postAppNotice = { notices.append($0) }
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
        model.dependencies.postAppNotice = { notices.append($0) }
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
        model.dependencies.serverURL = URL(string: "https://docs.example.com")!
        model.dependencies.sendUpload = { [self] file in
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
    var onUnsentChangesKept: (@MainActor ((any Error)?) -> Void)?
    /// Why saving the unsent changes (`saveUnsentChanges`, `close`) fails, like a full disk; nil keeps them.
    var unsentChangesError: (any Error)?
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

    /// The path of the block at `target` in this document.
    private func path(of target: BlockTarget) -> [Int]? {
        func find(_ node: PMNode, _ id: String, _ path: [Int]) -> [Int]? {
            for (index, child) in node.children.enumerated() {
                if child.string("id") == id { return path + [index] }
                if let found = find(child, id, path + [index]) { return found }
            }
            return nil
        }
        guard let document else { return nil }
        switch target {
        case .id(let id, _): return find(document, id, [])
        case .path(let path, _): return block(at: target) == nil ? nil : path
        }
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
        case .id(let id, _): return find(document, id)
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
    func close() {
        lifecycle.append("close")
        reportUnsentChanges()
    }
    /// With the number of block saves before it.
    func saveUnsentChanges() async {
        lifecycle.append("save after \(saved.count)")
        reportUnsentChanges()
    }
    /// As the engine reports a save that had something to keep.
    private func reportUnsentChanges() {
        if unconfirmedChanges > 0 { onUnsentChangesKept?(unsentChangesError) }
    }
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
    /// As `insertBlocks` or `replaceBlock(_:withNodes:expected:)`, with the first block's path where this document puts
    /// it, as the engine finds its target before it inserts (before `whileInserting`).
    func placeBlocks(_ nodes: [PMNode], at target: BlockTarget?, position: BlockPlace.Position, expected: PMNode?) async
        -> (result: EngineResult, path: [Int]?) {
        var placed: [Int]?
        if let target {
            placed = path(of: target)
            if position == .after, let path = placed { placed = Array(path.dropLast()) + [path[path.count - 1] + 1] }
        } else if let document {
            placed = [document.children.last?.type == "footnotes" ? document.children.count - 1 : document.children.count]
        }
        let result = switch (position, target) {
        case (.replace, let target?): await replaceBlock(target, withNodes: nodes, expected: expected)
        case (.replace, nil): EngineResult.refused
        case (.before, _): await insertBlocks(nodes, relativeTo: target, position: .before)
        case (.after, _): await insertBlocks(nodes, relativeTo: target, position: .after)
        }
        return (result, result.isApplied ? placed : nil)
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
    /// Return, Backspace and conversions as the model sent them. Where their lines go is the engine's
    /// (Engine/tools/keys-check.ts, conversions-check.ts); here the test says where the cursor goes, and `whileInserting`
    /// sets the document they leave.
    private(set) var enters: [(target: BlockTarget, node: PMNode, after: [PMNode], base: PMNode?)] = []
    var enterResult = KeyResult.moved(EngineCursor(path: [1], offset: 0))
    func enter(_ target: BlockTarget, keeping node: PMNode, after: [PMNode], base: PMNode?) async -> KeyResult {
        enters.append((target, node, after, base))
        if refusesSaves { return .refused }
        if savesUnavailable { return .unavailable }
        whileInserting?()
        return enterResult
    }
    /// Several lines at once (`enterLines`), as the model sent them; answered like `enter`.
    private(set) var enteredLines: [(target: BlockTarget, node: PMNode, lines: [[PMNode]], base: PMNode?)] = []
    func enterLines(_ target: BlockTarget, keeping node: PMNode, lines: [[PMNode]], base: PMNode?) async -> KeyResult {
        enteredLines.append((target, node, lines, base))
        if refusesSaves { return .refused }
        if savesUnavailable { return .unavailable }
        whileInserting?()
        return enterResult
    }
    private(set) var backspaces: [(target: BlockTarget, node: PMNode)] = []
    var backspaceResult = BackspaceResult.done(.nothing, cursor: nil)
    /// The base each Backspace passed.
    private(set) var backspaceBases: [PMNode?] = []
    func backspace(_ target: BlockTarget, holding node: PMNode, base: PMNode?) async -> BackspaceResult {
        backspaces.append((target, node))
        backspaceBases.append(base)
        whileInserting?()
        return backspaceResult
    }
    private(set) var converted: [(target: BlockTarget, kind: String)] = []
    var convertResult = KeyResult.refused
    func convert(_ target: BlockTarget, to kind: String) async -> KeyResult {
        converted.append((target, kind))
        whileInserting?()
        return convertResult
    }
    /// What a line can turn into, as the engine would say; nothing said by default.
    var conversionKinds: Set<String>?
    func conversions(_ target: BlockTarget) async -> Set<String>? { conversionKinds }
    /// Column counts set, unsynced sources and replaced embeds, as the model sent them.
    private(set) var columnCounts: [(target: BlockTarget, count: Int)] = []
    func setColumnCount(_ target: BlockTarget, count: Int) async -> EngineResult {
        columnCounts.append((target, count))
        return .applied
    }
    private(set) var unsynced: [BlockTarget] = []
    func unsync(_ target: BlockTarget) async -> EngineResult {
        unsynced.append(target)
        return .applied
    }
    private(set) var replacedReferences: [(path: [Int], sourcePageId: String, transclusionId: String, nodes: [PMNode])] = []
    func replaceReference(at path: [Int], sourcePageId: String, transclusionId: String, with nodes: [PMNode]) async -> EngineResult {
        replacedReferences.append((path, sourcePageId, transclusionId, nodes))
        whileInserting?()
        return .applied
    }
    /// Comments whose marks `unsetComment` removed.
    private(set) var unsetComments: [String] = []
    func unsetComment(_ commentId: String) async -> EngineResult {
        unsetComments.append(commentId)
        return .applied
    }
    /// What Backspace does, as the engine would tell the model in advance; nothing said by default.
    var plans: BackspacePlans?
    func backspacePlans(_ target: BlockTarget) async -> BackspacePlans? { plans }
    /// What the schema lets go where, as the test says; everything by default.
    var fitting: ((BlockPlace, [PMNode]) -> Bool)?
    /// The places asked about, with what for each.
    private(set) var fitQuestions: [(place: BlockPlace, candidates: [[PMNode]])] = []
    func fits(_ place: BlockPlace, candidates: [[PMNode]]) async -> [Bool]? {
        fitQuestions.append((place, candidates))
        return candidates.map { fitting?(place, $0) ?? true }
    }
    /// The table commands, by name, that apply to a cell; all by default.
    var tableCommandsApplying: Set<String>?
    /// Each question about table commands: the table, the cell and the commands.
    private(set) var tableQuestions: [(target: BlockTarget, cell: [Int], commands: [[String: JSONValue]])] = []
    func tableCommandsThatApply(_ target: BlockTarget, cell: [Int], commands: [[String: JSONValue]]) async -> [Bool]? {
        tableQuestions.append((target, cell, commands))
        return commands.map { command in tableCommandsApplying.map { $0.contains(command["name"]?.stringValue ?? "") } ?? true }
    }
}
