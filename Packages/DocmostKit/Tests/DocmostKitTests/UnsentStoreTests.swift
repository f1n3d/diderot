import Foundation
import Testing
@testable import DocmostKit

/// What the server hasn't confirmed yet (`UnsentStore`): its names stay as they were, it reads what the offline cache
/// kept there before, and it says when it can't read or write.
struct UnsentStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "unsent-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The unsent changes kept so far are found by these names.
    @Test func namesStayAsTheyWere() {
        #expect(UnsentStore.name(for: "https://a.example.com") == "https___a_example_com-b123322f09a0907a")
        #expect(UnsentStore.name(for: "u1") == "u1-8c47b07b56747f3")
        #expect(UnsentStore.name(for: "unsentTitles") == "unsentTitles-f5b98a95e5d78dc7")
        #expect(UnsentStore.name(for: "page/Ab12") == "page_Ab12-8c2e514788cc3447")
        // A long one keeps its first 48.
        #expect(UnsentStore.name(for: "https://documentation-platform.engineering.example.com")
            == "https___documentation-platform_engineering_examp-ac0a4ae7e1e0a60e")
    }

    /// What the offline cache kept there in earlier versions, this store finds.
    @Test func readsWhatTheCacheKept() async throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = DiskCache(scope: "u1", baseDirectory: base, protection: .afterFirstUnlock)
        await cache.write(["p1": "Titel"], key: "unsentTitles")
        await cache.writeData(Data([1, 2, 3]), key: "unsent/p1")
        let store = UnsentStore(directory: cache.directory)
        #expect(try await store.read([String: String].self, key: "unsentTitles") == ["p1": "Titel"])
        #expect(try await store.readData(key: "unsent/p1") == Data([1, 2, 3]))
        #expect(try await store.read([String: String].self, key: "nothing") == nil)
    }

    /// JSON kept as it came (the engine's document) reads as the value it encodes, and goes with `remove`.
    @Test func readsJSONKeptAsItCame() async throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = UnsentStore(directory: base)
        let json = #"{"type":"doc","content":[{"type":"paragraph","attrs":{"id":"a","indent":1},"content":[{"type":"text","text":"Eins"}]}]}"#
        try await store.writeJSON(Data(json.utf8), key: "unsentDocument/p1")
        let paragraph = PMNode(type: "paragraph", attrs: ["id": "a", "indent": 1], content: [PMNode(type: "text", text: "Eins")])
        #expect(try await store.read(PMNode.self, key: "unsentDocument/p1") == PMNode(type: "doc", content: [paragraph]))
        try await store.remove(key: "unsentDocument/p1")
        #expect(try await store.read(PMNode.self, key: "unsentDocument/p1") == nil)
    }

    /// A value it can't read throws, also for `update`, which then leaves it as it was; one it can't write throws.
    @Test func saysWhatFails() async throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = UnsentStore(directory: base)
        try await store.write(["p1": 1], key: "titles")
        await #expect(throws: (any Error).self) { _ = try await store.read([String: String].self, key: "titles") }
        await #expect(throws: (any Error).self) {
            try await store.update([String: String].self, key: "titles", initial: [:]) { $0["p2"] = "neu" }
        }
        #expect(try await store.read([String: Int].self, key: "titles") == ["p1": 1])
        try await store.remove(key: "titles")
        try await store.remove(key: "titles")
        #expect(try await store.read([String: Int].self, key: "titles") == nil)

        // A file where its folder would be: nothing can be written.
        let blocked = base.appending(path: "blocked")
        try Data().write(to: blocked)
        await #expect(throws: (any Error).self) { try await UnsentStore(directory: blocked).writeData(Data([1]), key: "x") }
    }
}
