import Foundation
import Testing
@testable import DocmostKit

/// A page's verification as Docmost 0.98 answers it (`pages/verification-info`): the statuses its web client opens
/// read-only, by the dialog each asks with.
struct PageVerificationTests {
    @Test(arguments: [
        ("verified", PageVerification.Lock.verified), ("expiring", .verified), ("approved", .approved), ("in_approval", .inApproval),
    ])
    func lockedStatusesAsk(status: String, lock: PageVerification.Lock) throws {
        #expect(try decode(status).lock == lock)
    }

    /// Drafts, changed and expired pages edit without asking, as on the web; so does a status a newer server adds.
    @Test(arguments: ["none", "draft", "invalidated", "expired", "obsolete", "someday"])
    func otherStatusesEditFreely(status: String) throws {
        #expect(try decode(status).lock == nil)
    }

    /// The whole answer decodes from its status alone; the rest (who, when, the verifiers) isn't needed yet.
    @Test func fullAnswerDecodes() throws {
        let json = #"{"id": "v1", "pageId": "p1", "type": "qms", "status": "approved", "mode": null, "verifiedBy": {"id": "u1", "name": "Alex"}, "verifiers": [], "permissions": {"canVerify": false}}"#
        #expect(try JSONDecoder().decode(PageVerification.self, from: Data(json.utf8)).lock == .approved)
    }

    private func decode(_ status: String) throws -> PageVerification {
        try JSONDecoder().decode(PageVerification.self, from: Data(#"{"status": "\#(status)"}"#.utf8))
    }
}
