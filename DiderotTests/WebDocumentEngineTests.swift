import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Engine events are decoded in one pass, straight into the app's types.
struct WebDocumentEngineTests {
    /// The same node as the route through `JSONSerialization`, `JSONValue` and `PMNode(json:)`.
    @Test func documentEventDecodesLikeTheJSONValueRoute() throws {
        let document = #"""
            {"type": "doc", "content": [
                {"type": "heading", "attrs": {"id": "h1", "textAlign": null, "level": 2}, "content": [
                    {"type": "text", "text": "Titel ✓", "marks": [{"type": "bold"}, {"type": "link", "attrs": {"href": "https://example.com/a?b=1"}}]}
                ]},
                {"type": "taskList", "content": [{"type": "taskItem", "attrs": {"checked": true}, "content": [{"type": "paragraph", "attrs": {"indent": 0}}]}]},
                {"type": "table", "content": [{"type": "tableRow", "content": [{"type": "tableCell", "attrs": {"colwidth": [120, 80.5], "background": null}}]}]}
            ]}
            """#
        let event = try JSONDecoder().decode(EngineEvent.self, from: Data(#"{"type": "document", "document": \#(document)}"#.utf8))
        let object = try JSONSerialization.jsonObject(with: Data(document.utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
        let decoded = try #require(event.document)

        #expect(decoded == PMNode(json: value))
    }

    /// The web client's entries carry only a name: they no longer empty the list. Each user shows once, a web tab of
    /// someone already shown from the app or of the signed-in user not at all.
    @Test func participantsIncludeWebEntries() throws {
        func participants(_ list: String) throws -> [EngineParticipant] {
            let entries = try JSONDecoder().decode(EngineEvent.self, from: Data(#"{"type": "awareness", "participants": \#(list)}"#.utf8)).participants?.list
            return EngineParticipant.merge(entries ?? [], myId: "me", myName: "Ich")
        }
        let ann = ##"{"id": "u1", "name": "Ann", "avatarUrl": "a.png", "color": "#0a84ff"}"##
        let ben = ##"{"name": "Ben", "color": "#958DF1"}"##
        let annWeb = ##"{"name": "Ann", "color": "#F98181"}"##
        let myApp = ##"{"id": "me", "name": "Ich", "avatarUrl": "", "color": "#0a84ff"}"##
        let myWeb = ##"{"name": "Ich", "color": "#FBBC88"}"##

        #expect(try participants("[\(ben), \(ann), \(ben), \(annWeb), \(myApp), \(myWeb)]") == [
            EngineParticipant(id: "u1", name: "Ann", avatarUrl: "a.png"),
            EngineParticipant(id: "web:Ben", name: "Ben", avatarUrl: nil),
        ])
    }

    /// A block without an id is found by position and carries its type, so the engine refuses another kind of block
    /// a collaborator moved there meanwhile; a block with an id needs no type.
    @Test func positionTargetCarriesTheBlockType() throws {
        let code = try #require(PMNode(json: JSONDecoder().decode(JSONValue.self, from: Data(#"{"type": "codeBlock"}"#.utf8))))
        let heading = try #require(PMNode(json: JSONDecoder().decode(JSONValue.self, from: Data(#"{"type": "heading", "attrs": {"id": "h1"}}"#.utf8))))

        #expect(NSDictionary(dictionary: NodeRef(path: [2, 0], node: code).target.jsObject) == ["path": [2, 0], "type": "codeBlock"])
        #expect(NSDictionary(dictionary: NodeRef(path: [1], node: heading).target.jsObject) == ["id": "h1"])
        #expect(NSDictionary(dictionary: BlockTarget.path([3]).jsObject) == ["path": [3]])
    }
}
