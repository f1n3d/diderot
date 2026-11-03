import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Unsent changes stay where earlier versions kept them, `unsent/docmost-cache/<server>/docmost-cache/<user>`, with the
/// names the offline cache's layout gave them then (`UnsentStore.name(for:)`): every user's are found by it.
struct UnsentChangesTests {
    @Test func keptWhereEarlierVersionsKeptThem() {
        let directory = UnsentChanges.store(server: URL(string: "https://a.example.com")!, userId: "u1").directory
        #expect(Array(directory.pathComponents.suffix(5))
            == ["unsent", "docmost-cache", "https___a_example_com-b123322f09a0907a", "docmost-cache", "u1-8c47b07b56747f3"])
        #expect(directory.path(percentEncoded: false).hasPrefix(URL.applicationSupportDirectory.path(percentEncoded: false)))
    }
}
