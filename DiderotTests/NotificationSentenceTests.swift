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

    /// Docmost 0.98: a change cost a page its verification or approval (the actor may be missing), and how a database's
    /// CSV import went.
    @Test func docmost098Notices() throws {
        func invalidated(_ data: [String: JSONValue]?) throws -> Text {
            try sentence("page.verification_invalidated", actorAndPage.merging(["data": data.map(JSONValue.object) ?? .null]) { $1 })
        }
        #expect(try invalidated(["verificationType": "expiring", "previousStatus": "verified"])
            == Text("\(alice) changed the verified page \(roadmap)"))
        #expect(try invalidated(nil) == Text("\(alice) changed the verified page \(roadmap)"))
        #expect(try invalidated(["verificationType": "qms", "previousStatus": "approved"]) == Text("\(alice) changed the approved page \(roadmap)"))
        #expect(try invalidated(["verificationType": "qms", "previousStatus": "in_approval"])
            == Text("\(alice) changed \(roadmap) while it was in approval"))
        let someone = Text(verbatim: String(localized: "Someone")).bold()
        #expect(try sentence("page.verification_invalidated", ["page": ["id": "p", "title": "Roadmap"]])
            == Text("\(someone) changed the verified page \(roadmap)"))

        let file = Text(verbatim: "kunden.csv").bold(), rows = 3, more = 4
        let imported = try sentence("base.import_completed", ["data": ["fileName": "kunden.csv", "importedRows": 3, "skippedValues": 0]])
        #expect(contents(imported) == contents(Text("Imported \(rows) rows from \(file)")))
        #expect(contents(imported) != contents(Text("Imported \(more) rows from \(file)")))
        #expect(try sentence("base.import_completed", ["data": ["fileName": "kunden.csv"]]) == Text("Imported \(file)"))
        #expect(try sentence("base.import_failed", ["data": ["fileName": "kunden.csv", "error": "Invalid CSV"]]) == Text("Couldn't import \(file)"))
    }

    /// The line below the sentence, as on the web: a failed import's error (or a request to try again), the values an
    /// import left empty, why a SIEM destination fails.
    @Test func details() throws {
        #expect(try detail("base.import_failed", ["fileName": "kunden.csv", "error": "Invalid CSV"]) == "Invalid CSV")
        #expect(try detail("base.import_failed", ["fileName": "kunden.csv", "error": ""]) == String(localized: "Nothing was imported. Please try again."))
        let skipped = 2
        #expect(try detail("base.import_completed", ["importedRows": 3, "skippedValues": 2])
            == String(localized: "\(skipped) values couldn't be read and were left empty."))
        #expect(try detail("base.import_completed", ["importedRows": 3, "skippedValues": 0]) == nil)
        #expect(try detail("siem_destination.failing", ["destinationName": "Splunk", "lastError": "HTTP 503"]) == "HTTP 503")
        #expect(try detail("siem_destination.recovered", ["destinationName": "Splunk", "lastError": "HTTP 503"]) == nil)
        #expect(try detail("comment.created", nil) == nil)
    }

    /// The counts' plural forms in the String Catalog, in English and German.
    @Test(arguments: [("en", 1, "Imported 1 row from kunden.csv", "1 value couldn't be read and was left empty."),
                      ("en", 3, "Imported 3 rows from kunden.csv", "3 values couldn't be read and were left empty."),
                      ("de", 1, "1 Zeile aus kunden.csv importiert", "1 Wert konnte nicht gelesen werden und wurde leer gelassen."),
                      ("de", 3, "3 Zeilen aus kunden.csv importiert", "3 Werte konnten nicht gelesen werden und wurden leer gelassen.")])
    func importCounts(language: String, count: Int, rows: String, skipped: String) {
        func localized(_ value: String.LocalizationValue) -> String {
            var resource = LocalizedStringResource(value)
            resource.locale = Locale(identifier: language)
            return String(localized: resource)
        }
        #expect(localized("Imported \(count) rows from \("kunden.csv")") == rows)
        #expect(localized("\(count) values couldn't be read and were left empty.") == skipped)
    }

    /// What a text holds: its key, arguments and modifiers. Its `==` can't tell where the interpolation has a number:
    /// two texts made apart with the same count compare unequal (iOS 27). So such a sentence compares by its dump, without
    /// the addresses in it; the count goes in as an Int, as the app reads it (a literal makes another kind of argument).
    private func contents(_ text: Text) -> String {
        var dumped = ""
        dump(text, to: &dumped)
        return dumped.replacing(/0x[0-9a-f]+/, with: "")
    }

    private func sentence(_ type: String, _ fields: [String: JSONValue]? = nil) throws -> Text {
        try row(type, fields).sentence
    }

    private func detail(_ type: String, _ data: [String: JSONValue]?) throws -> String? {
        try row(type, data.map { ["data": .object($0)] } ?? [:]).detail
    }

    /// The models have no public initializers; build them as the server sends them.
    private func row(_ type: String, _ fields: [String: JSONValue]?) throws -> NotificationRow {
        let json = JSONValue.object((fields ?? actorAndPage).merging(["id": "n", "type": .string(type)]) { $1 })
        let notification = try JSONDecoder().decode(ActivityNotification.self, from: JSONEncoder().encode(json))
        return NotificationRow(notification: notification, baseURL: nil)
    }
}
