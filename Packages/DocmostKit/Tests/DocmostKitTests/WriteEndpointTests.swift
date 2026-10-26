import Foundation
import Testing
@testable import DocmostKit

struct WriteEndpointTests {
    @Test func createPageWithMarkdown() throws {
        let endpoint = Endpoints.Pages.create(spaceId: "s1", parentPageId: "p0", title: "Notes", icon: "📝", markdown: "# Hi")
        #expect(endpoint.path == "pages/create")
        let body = try body(of: endpoint)
        #expect(body["spaceId"] == "s1")
        #expect(body["parentPageId"] == "p0")
        #expect(body["title"] == "Notes")
        #expect(body["content"] == "# Hi")
        #expect(body["format"] == "markdown")

        let plain = try DocmostKitTests.body(of: Endpoints.Pages.create(spaceId: "s1", title: "Empty"))
        #expect(plain["format"] == nil)
        #expect(plain["content"] == nil)
    }

    @Test func updateTitleAndAppend() throws {
        let title = try body(of: Endpoints.Pages.update(pageId: "p1", title: "New", icon: "🔥"))
        #expect(title["pageId"] == "p1")
        #expect(title["title"] == "New")
        #expect(title["icon"] == "🔥")
        #expect(title["content"] == nil)

        let append = try body(of: Endpoints.Pages.appendMarkdown(pageId: "p1", "- note"))
        #expect(append["content"] == "- note")
        #expect(append["operation"] == "append")
        #expect(append["format"] == "markdown")
    }

    @Test func pageAttachmentsListAndDelete() throws {
        let list = Endpoints.Attachments.list(pageId: "p1", query: "bild")
        #expect(list.path == "pages/attachments")
        let listBody = try body(of: list)
        #expect(listBody["pageId"] == "p1")
        #expect(listBody["query"] == "bild")
        #expect(try body(of: Endpoints.Attachments.list(pageId: "p1"))["query"] == nil)

        let delete = Endpoints.Attachments.delete(attachmentId: "a1")
        #expect(delete.path == "attachments/delete")
        #expect(try body(of: delete)["attachmentId"] == "a1")
    }

    @Test func templatesAndDatabaseConversion() throws {
        let space = try body(of: Endpoints.Templates.list(spaceId: "s1"))
        #expect(space["spaceId"] == "s1")
        #expect(try body(of: Endpoints.Templates.list())["spaceId"] == nil)
        #expect(Endpoints.Templates.info(templateId: "t1").path == "templates/info")

        let use = Endpoints.Templates.use(templateId: "t1", spaceId: "s1")
        #expect(use.path == "templates/use")
        let useBody = try body(of: use)
        #expect(useBody["templateId"] == "t1")
        #expect(useBody["spaceId"] == "s1")
        #expect(useBody["parentPageId"] == nil)

        let kanban = try body(of: Endpoints.Bases.convert(pageId: "p1", template: "kanban"))
        #expect(kanban["pageId"] == "p1")
        #expect(kanban["template"] == "kanban")
        #expect(try body(of: Endpoints.Bases.convert(pageId: "p1"))["template"] == nil)
    }

    @Test func deleteAndRestore() throws {
        let trash = try body(of: Endpoints.Pages.delete(pageId: "p1"))
        #expect(trash["permanentlyDelete"] == nil)
        let permanent = try body(of: Endpoints.Pages.delete(pageId: "p1", permanently: true))
        #expect(permanent["permanentlyDelete"] == true)
        #expect(Endpoints.Pages.restore(pageId: "p1").path == "pages/restore")
    }

    @Test func commentContentIsStringifiedDocument() throws {
        let endpoint = try Endpoints.Comments.create(pageId: "p1", text: "Hello\n\nWorld", parentCommentId: "c0")
        let body = try body(of: endpoint)
        #expect(body["type"] == "page")
        #expect(body["parentCommentId"] == "c0")
        let contentString = try #require(body["content"]?.stringValue)
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentString.utf8))
        #expect(document["type"] == "doc")
        #expect(document["content"]?.arrayValue?.count == 3)
        #expect(document["content"]?[0]?["content"]?[0]?["text"] == "Hello")
        #expect(document["content"]?[1]?["content"] == nil)
        #expect(ContentDocument(json: document).blocks.count == 3)
    }

    @Test func commentPlainTextForEditing() {
        #expect(CommentContent.plainText(of: CommentContent.document(for: "Zeile eins\n\nZeile drei")) == "Zeile eins\n\nZeile drei")
        // Content from the web client: mentions and lists become plain text.
        let web: JSONValue = ["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "Hallo "], ["type": "mention", "attrs": ["label": "Jane"]]]],
            ["type": "bulletList", "content": [["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": "Punkt"]]]]]]],
        ]]
        #expect(CommentContent.plainText(of: web) == "Hallo @Jane\nPunkt")
        #expect(CommentContent.plainText(of: nil) == "")
    }

    @Test func inlineCommentAndResolve() throws {
        let inline = try body(of: Endpoints.Comments.createInline(pageId: "p1", text: "Hm?", selection: "markierter Text"))
        #expect(inline["type"] == "inline")
        #expect(inline["selection"] == "markierter Text")
        #expect(inline["parentCommentId"] == nil)
        // Page comments send no `selection`.
        #expect(try body(of: Endpoints.Comments.create(pageId: "p1", text: "x"))["selection"] == nil)

        let resolve = try body(of: Endpoints.Comments.resolve(commentId: "c1", pageId: "p1", resolved: true))
        #expect(Endpoints.Comments.resolve(commentId: "c1", pageId: "p1", resolved: false).path == "comments/resolve")
        #expect(resolve["commentId"] == "c1")
        #expect(resolve["pageId"] == "p1")
        #expect(resolve["resolved"] == true)
    }

    @Test func baseRowWrites() throws {
        // Patch: `null` clears a cell and must be present in the JSON; without a position the key is omitted.
        let update = try body(of: Endpoints.Bases.updateRow(pageId: "b1", rowId: "r1", cells: ["prpA": 4.5, "prpB": .null]))
        #expect(Endpoints.Bases.updateRow(pageId: "b1", rowId: "r1", cells: [:]).path == "bases/rows/update")
        #expect(update["pageId"] == "b1")
        #expect(update["rowId"] == "r1")
        #expect(update["cells"]?["prpA"] == 4.5)
        #expect(update["cells"]?["prpB"] == .null)
        #expect(update["position"] == nil)

        // Kanban move within a column: empty cells plus position (web parity).
        let move = try body(of: Endpoints.Bases.updateRow(pageId: "b1", rowId: "r1", cells: [:], position: "a0V"))
        #expect(move["cells"] == .object([:]))
        #expect(move["position"] == "a0V")

        let create = try body(of: Endpoints.Bases.createRow(pageId: "b1", cells: ["prpS": "optX"], position: "Zz"))
        #expect(Endpoints.Bases.createRow(pageId: "b1").path == "bases/rows/create")
        #expect(create["cells"]?["prpS"] == "optX")
        #expect(create["position"] == "Zz")
        #expect(create["afterRowId"] == nil)

        let delete = try body(of: Endpoints.Bases.deleteRow(pageId: "b1", rowId: "r1"))
        #expect(Endpoints.Bases.deleteRow(pageId: "b1", rowId: "r1").path == "bases/rows/delete")
        #expect(delete == ["rowId": "r1", "pageId": "b1"])

        let info = try body(of: Endpoints.Bases.rowInfo(pageId: "b1", rowId: "r1"))
        #expect(Endpoints.Bases.rowInfo(pageId: "b1", rowId: "r1").path == "bases/rows/info")
        #expect(info == ["rowId": "r1", "pageId": "b1"])
    }

    /// Docmost after 0.96 refuses queries over 200 characters: search and suggestions (link sheet, database pickers)
    /// send the first 200.
    @Test func longQueriesAreCut() throws {
        let long = String(repeating: "a", count: 250)
        #expect(try body(of: Endpoints.Search.search(query: long))["query"] == .string(String(repeating: "a", count: 200)))
        #expect(try body(of: Endpoints.Search.suggest(query: long))["query"] == .string(String(repeating: "a", count: 200)))
    }

    @Test func basePropertyUpdate() throws {
        let options: JSONValue = ["choices": [["id": "opt1", "name": "Neu", "color": "red"]], "choiceOrder": ["opt1"]]
        let endpoint = Endpoints.Bases.updateProperty(pageId: "b1", propertyId: "prpT", typeOptions: options)
        #expect(endpoint.path == "bases/properties/update")
        let body = try body(of: endpoint)
        #expect(body["propertyId"] == "prpT")
        #expect(body["typeOptions"] == options)
    }
}
