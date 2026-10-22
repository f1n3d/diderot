import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// "This page is empty." only when nothing renders: a lone mention, image or divider has no text but is content.
struct EmptyPageTests {
    @Test func readOnlyPageWithOnlyAnAtomIsNotEmpty() throws {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        func showsPlaceholder(_ blocks: [PMNode]) -> Bool {
            DocumentModel(page: page, initialDocument: PMNode(type: "doc", content: blocks), engine: nil, readOnlyReason: .noPermission)
                .showsEmptyPlaceholder
        }

        #expect(showsPlaceholder([]))
        #expect(showsPlaceholder([PMNode(type: "paragraph")]))
        #expect(!showsPlaceholder([PMNode(type: "paragraph", content: [PMNode(type: "mention", attrs: ["id": "m", "label": "Ann"])])]))
        #expect(!showsPlaceholder([PMNode(type: "image", attrs: ["src": "/files/a.png"])]))
        #expect(!showsPlaceholder([PMNode(type: "horizontalRule")]))
    }
}
