import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// Each notification type the server sends (`notification.constants.ts`) has its own sentence, worded like the web;
/// only unknown types fall back to the generic wording.
struct NotificationSentenceTests {
    private let alice = Text(verbatim: "Alice").bold(), roadmap = Text(verbatim: "Roadmap").bold()
    private let actorAndPage: [String: JSONValue] = ["actor": ["id": "u", "name": "Alice"], "page": ["id": "p", "title": "Roadmap"]]

    @Test func pageNotices() throws {
        #expect(try sentence("comment.user_mention") == Text("\(alice) mentioned you in a comment on \(roadmap)"))
        #expect(try sentence("comment.created") == Text("\(alice) commented on \(roadmap)"))
        #expect(try sentence("comment.resolved") == Text("\(alice) resolved a comment on \(roadmap)"))
        #expect(try sentence("page.user_mention") == Text("\(alice) mentioned you on \(roadmap)"))
        #expect(try sentence("page.updated") == Text("\(alice) updated \(roadmap)"))
        #expect(try sentence("page.permission_granted") == Text("\(alice) gave you access to \(roadmap)"))
        #expect(try sentence("page.verified") == Text("\(alice) verified \(roadmap)"))
        #expect(try sentence("page.approval_requested") == Text("\(alice) submitted \(roadmap) for your approval"))
        #expect(try sentence("page.approval_rejected") == Text("\(alice) returned \(roadmap) for revision"))
        #expect(try sentence("page.approval_cancelled") == Text("\(alice) changed the approval of \(roadmap)"), "future type")
    }

    /// The server sends these without an actor; SIEM alerts have no page either, only the destination's name.
    @Test func systemNotices() throws {
        let page: [String: JSONValue] = ["page": ["id": "p", "title": "Roadmap"]]
        #expect(try sentence("page.verification_expiring", page) == Text("Verification of \(roadmap) expires soon"))
        #expect(try sentence("page.verification_expired", page) == Text("Verification of \(roadmap) has expired"))
        let splunk = Text(verbatim: "Splunk").bold(), destination: [String: JSONValue] = ["data": ["destinationName": "Splunk"]]
        #expect(try sentence("siem_destination.failing", destination) == Text("SIEM destination \(splunk) is failing"))
        #expect(try sentence("siem_destination.disabled", destination)
            == Text("SIEM destination \(splunk) was disabled after 24 hours of failures"))
        #expect(try sentence("siem_destination.recovered", destination) == Text("SIEM destination \(splunk) recovered"))
    }

    /// The models have no public initializers; build them as the server sends them.
    private func sentence(_ type: String, _ fields: [String: JSONValue]? = nil) throws -> Text {
        let json = JSONValue.object((fields ?? actorAndPage).merging(["id": "n", "type": .string(type)]) { $1 })
        let notification = try JSONDecoder().decode(ActivityNotification.self, from: JSONEncoder().encode(json))
        return NotificationRow(notification: notification, baseURL: nil).sentence
    }
}
