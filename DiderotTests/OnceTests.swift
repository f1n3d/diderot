import Foundation
import Testing
@testable import Diderot

/// Views that SwiftUI builds anew on every pass of their parent (code review R51).
struct OnceTests {
    /// A web page and its data store are made the first time they're asked for, and only then: built in a view's `init`,
    /// they came anew on every pass of the parent.
    @Test func makesItsValueOnce() {
        let once = Once<NSObject>()
        var made = 0
        let first = once { made += 1; return NSObject() }
        let second = once { made += 1; return NSObject() }
        #expect(first === second && made == 1)
    }

    /// The licenses ship with the app and read: a file that didn't showed an empty list without a word.
    @Test func licensesRead() throws {
        let notices = try #require(LicensesView.notices)
        #expect(!notices.sections.isEmpty && notices.sections.allSatisfy { !$0.entries.isEmpty })
    }
}
