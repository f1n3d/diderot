import Foundation
import Testing
@testable import Diderot

struct ErrorMessageTests {
    /// An error without a text of its own reads as a plain sentence, not "The operation couldn't be completed.
    /// (Swift.CancellationError error 1.)"; Foundation's and the network's keep theirs (code review R43).
    @Test func errorsWithoutATextOfTheirOwnReadPlainly() {
        struct Opaque: Error {}
        struct Described: LocalizedError { var errorDescription: String? { "Eigener Text" } }
        let plain = String(localized: "Something went wrong.")
        #expect(Opaque().userMessage == plain)
        #expect(CancellationError().userMessage == plain)
        #expect(Described().userMessage == "Eigener Text")
        #expect(CocoaError(.fileNoSuchFile).userMessage == CocoaError(.fileNoSuchFile).localizedDescription)
        #expect(URLError(.notConnectedToInternet).userMessage == URLError(.notConnectedToInternet).localizedDescription)
    }
}
