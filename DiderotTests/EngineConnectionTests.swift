import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// The page's engine from opening to closing (`EngineConnection`) on its own, with a stand-in for its page. What it does
/// for the page is tested through `DocumentModel` (DocumentModelTests); these test how long it keeps the page.
struct EngineConnectionTests {
    /// What the connection asked of the page, kept apart from it: the page can go while a close still runs.
    final class Asked {
        var sent = 0, writes = 0, endings = 0, keeps = 0
        var messages: [String?] = []
    }

    /// A stand-in for the page (`DocumentModel`).
    final class Owner: EngineConnectionOwner {
        let asked: Asked
        var dependencies = DocumentModel.Dependencies()

        init(_ asked: Asked) {
            self.asked = asked
        }

        func connectionSent(_ document: PMNode) { asked.sent += 1 }
        func connectionWritesInput() async { asked.writes += 1 }
        func connectionEndsEditing() { asked.endings += 1 }
        func connectionKeepsInput() { asked.keeps += 1 }
        func connectionSays(_ message: String?) { asked.messages.append(message) }
    }

    /// A page the view lets go while its engine closes: the close still writes its input and keeps its last document
    /// for the next open, as when the page ran it, and lets the page go once done.
    @Test(.timeLimit(.minutes(1))) func aCloseKeepsItsPageUntilItIsDone() async throws {
        let document = PMNode(type: "doc", content: [PMNode(type: "paragraph", content: [PMNode(type: "text", text: "Entwurf")])])
        let engine = FakeDocumentEngine(document: document)
        let connection = try Self.connection(engine)
        let asked = Asked()
        var owner: Owner? = Owner(asked)
        let liveOwner = LiveDocuments.Owner(server: URL(string: "https://wiki.example.com")!, userId: UUID().uuidString)
        owner?.dependencies.liveOwner = liveOwner
        weak var gone = owner
        connection.owner = owner
        engine.sendDocument()
        #expect(connection.isLive && asked.sent == 1)

        let close = connection.suspend()
        owner = nil
        await close.value

        #expect(asked.endings == 1 && asked.writes == 1)
        #expect(engine.lifecycle == ["close"] && connection.lifecycle == .closed)
        #expect(LiveDocuments.document(for: "p", owner: liveOwner, newerThan: nil, serverClockOffset: 0) == document)
        #expect(gone == nil)
    }

    /// The engine's events for a page that is gone do nothing: the page's own handlers held it weakly. A web process that
    /// ended would otherwise reopen the engine for nobody.
    @Test(.timeLimit(.minutes(1))) func eventsForAGonePageDoNothing() async throws {
        let engine = FakeDocumentEngine(document: PMNode(type: "doc", content: [PMNode(type: "paragraph")]))
        let connection = try Self.connection(engine)
        let asked = Asked()
        var owner: Owner? = Owner(asked)
        connection.owner = owner
        engine.sendDocument()
        #expect(connection.isLive)

        owner = nil
        engine.onTerminated?()
        engine.onFailure?(.engineError)
        engine.sendDocument()
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.lifecycle.isEmpty)
        #expect(asked.sent == 1 && asked.keeps == 0 && asked.endings == 0 && asked.messages.isEmpty)
    }

    private static func connection(_ engine: FakeDocumentEngine) throws -> EngineConnection {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        return EngineConnection(page: page, engine: engine, readOnlyReason: nil)
    }
}
