import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// The page's one text editor and its saves (`ActiveTextSession`) on their own, with a stand-in for the page. What the keys
/// and menus do with them is tested through `DocumentModel` (DocumentModelTests).
struct ActiveTextSessionTests {
    /// A stand-in for the page (`DocumentModel`): counts the results it is shown.
    final class Owner: ActiveTextSessionOwner {
        var dependencies = DocumentModel.Dependencies()
        private(set) var reports: [EngineResult] = []

        func sessionReports(_ result: EngineResult) -> Bool {
            reports.append(result)
            return result.isApplied
        }

        func sessionShowsInput() {}
        func sessionShowsEngineDocument() {}
    }

    /// Text the app puts into the editor itself (a block's on activation, after undo, a collaborator's) isn't input: saved,
    /// it would write an untouched block back. Typing after it is.
    @Test func theAppsTextIsNoInput() {
        let session = ActiveTextSession(engine: nil)
        let paragraph = PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Eins")])
        session.show(paragraph, as: AttributedString("Eins"))
        #expect(session.base == paragraph)
        #expect(!session.textChangeIsInput())
        session.text.append(AttributedString("x"))
        #expect(session.textChangeIsInput())

        let code = PMNode(type: "codeBlock", content: [PMNode(type: "text", text: "let a = 1")])
        session.show(code, as: AttributedString("let a = 1"))
        #expect(session.code == "let a = 1" && !session.codeChangeIsInput())
        session.code += "\n"
        #expect(session.codeChangeIsInput())
    }

    /// Input whose save is on its way when editing moves on reaches the engine, also when the page goes meanwhile (the view
    /// let it go after leaving): the save holds the session, as it held the page before.
    @Test(.timeLimit(.minutes(1))) func aSaveOnItsWayOutlivesThePage() async throws {
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a"], content: [PMNode(type: "text", text: "Eins")])
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [paragraph]))
        var owner: Owner? = Owner()
        var session: ActiveTextSession? = ActiveTextSession(engine: engine)
        session?.owner = owner
        session?.active = DocumentModel.Active(ref: NodeRef(path: [0], node: paragraph), type: "paragraph", attrs: paragraph.attrs, itemPath: nil)
        session?.show(paragraph, as: AttributedString("Eins"))
        session?.text = AttributedString("Einsx")
        session?.scheduleCommit()

        session?.commitPendingNow()
        session = nil
        owner = nil
        for _ in 0..<500 where engine.saved.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(engine.saved.map(\.plainText) == ["Einsx"])
        #expect(engine.bases == [paragraph])
    }
}
