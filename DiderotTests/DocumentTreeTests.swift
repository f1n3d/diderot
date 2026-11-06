import Testing
import DocmostKit
@testable import Diderot

/// Finding a block in the app's copy of the page (`PMNode.locate`), as the engine finds it (`locate` in
/// Engine/src/steps.ts).
struct DocumentTreeTests {
    private static func paragraph(_ id: String, _ text: String) -> PMNode {
        PMNode(type: "paragraph", attrs: ["id": .string(id)], content: [PMNode(type: "text", text: text)])
    }

    /// An id found twice (a synced block unsynced on the web keeps its source's ids) counts only where the app saw the
    /// block: the first could be the source, and an edit there shows on every page that embeds it.
    @Test func anIdFoundTwiceCountsOnlyWhereTheAppSawIt() {
        let page = PMNode(type: "doc", content: [
            PMNode(type: "transclusionSource", attrs: ["id": "s"], content: [Self.paragraph("a", "Quelle")]),
            Self.paragraph("a", "Kopie"),
        ])
        #expect(page.locate(NodeRef(path: [1], id: "a"))?.node.plainText == "Kopie")
        #expect(page.locate(NodeRef(path: [0, 0], id: "a"))?.node.plainText == "Quelle")
        #expect(page.locate(NodeRef(path: [2], id: "a")) == nil)
    }

    /// An id found once finds its block where it is now, also after it moved.
    @Test func anIdFoundOnceFollowsItsBlock() {
        let page = PMNode(type: "doc", content: [Self.paragraph("z", "Neu"), Self.paragraph("b", "B")])
        #expect(page.locate(NodeRef(path: [0], id: "b"))?.path == [1])
        #expect(page.locate(NodeRef(path: [0], id: "x")) == nil)
    }
}
