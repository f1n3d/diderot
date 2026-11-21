import Foundation
import Testing
@testable import DocmostKit

/// Docmost 0.98's template fields, read as the web's `getTemplateVariables` reads them.
struct TemplateVariableTests {
    private func variable(_ id: String, _ name: String, _ type: String = "text", options: [String] = []) -> JSONValue {
        ["type": "templateVariable", "attrs": ["id": .string(id), "name": .string(name), "fieldType": .string(type),
                                               "options": .array(options.map(JSONValue.string))]]
    }

    private let a = "0b5c8e0e-7c1f-4b8e-9a3d-2f1e5d6c7b8a", b = "6f1d2c3b-4a59-4e7d-8c6b-5a4f3e2d1c0b"

    @Test func oneFieldPerNameInOrder() throws {
        let content: JSONValue = ["type": "doc", "content": [
            ["type": "paragraph", "content": [variable(a, "Kunde"), ["type": "text", "text": " und "], variable(b, "Status", "select", options: ["offen", "zu"])]],
            ["type": "paragraph", "content": [variable(a, "Kunde"), variable("8d7c6b5a-4f3e-4d2c-9b1a-0f9e8d7c6b5a", " kunde ")]],
        ]]
        let fields = try TemplateVariable.fields(in: content)
        #expect(fields.map(\.name) == ["Kunde", "Status"])
        #expect(fields.map(\.id) == [a, b])
        #expect(fields[1].fieldType == .select)
        #expect(fields[1].options == ["offen", "zu"])
        #expect(try TemplateVariable.fields(in: ["type": "doc", "content": [["type": "paragraph"]]]).isEmpty)
        #expect(try TemplateVariable.fields(in: nil).isEmpty)
    }

    @Test func refusesWhatTheWebRefuses() {
        let invalid: [JSONValue] = [
            variable("not-a-uuid", "Kunde"),
            variable(a, ""),
            variable(a, "Zwei\nZeilen"),
            variable(a, "Kunde", "date"),
            variable(a, "Kunde", "text", options: ["x"]),
            variable(a, "Wahl", "select"),
            variable(a, "Wahl", "select", options: ["x", "x"]),
        ]
        for node in invalid {
            #expect(throws: TemplateVariable.Invalid.variable) { try TemplateVariable.fields(in: ["type": "doc", "content": [node]]) }
        }
        #expect(throws: TemplateVariable.Invalid.conflictingNames) {
            try TemplateVariable.fields(in: ["type": "doc", "content": [variable(a, "Kunde"), variable(a, "Projekt")]])
        }
    }

    @Test func showsAsItsNameInAPreview() {
        let doc = ContentDocument(json: ["type": "doc", "content": [["type": "paragraph", "content": [variable(a, "Kunde")]]]])
        guard case .paragraph(let text) = doc.blocks.first?.kind else { Issue.record("expected a paragraph"); return }
        #expect(text.inlines == [.templateVariable(name: "Kunde")])
    }
}
