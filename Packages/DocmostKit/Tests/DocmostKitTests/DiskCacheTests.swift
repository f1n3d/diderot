import Foundation
import Testing
@testable import DocmostKit

struct DiskCacheTests {
    private func makeCache() -> DiskCache {
        let base = FileManager.default.temporaryDirectory.appending(path: "docmost-cache-tests-\(UUID().uuidString)")
        return DiskCache(scope: "https://wiki.example.com", baseDirectory: base)
    }

    @Test func roundTripsCodableValues() async throws {
        let cache = makeCache()
        let page = try TestSupport.decodeFixture(Page.self, "page-info")
        await cache.write(page, key: "page/\(page.id)")
        #expect(await cache.read(Page.self, key: "page/\(page.id)") == page)
        #expect(await cache.read(Page.self, key: "page/missing") == nil)
        await cache.removeAll()
    }

    @Test func storesRawData() async {
        let cache = makeCache()
        let data = Data([1, 2, 3, 4])
        await cache.writeData(data, key: "https://wiki.example.com/api/files/a/b.png@512")
        #expect(await cache.readData(key: "https://wiki.example.com/api/files/a/b.png@512") == data)
        await cache.remove(key: "https://wiki.example.com/api/files/a/b.png@512")
        #expect(await cache.readData(key: "https://wiki.example.com/api/files/a/b.png@512") == nil)
        await cache.removeAll()
    }

    @Test func keysAreFileSafeAndStable() {
        let name = DiskCache.safeName("page/01a1-… weird/key?x=1")
        #expect(!name.contains("/"))
        #expect(!name.contains("?"))
        // Pinned FNV-1a 64 values ("a" is the published one): a changed hash would orphan every existing cache.
        #expect(DiskCache.stableHash("a") == "af63dc4c8601ec8c")
        #expect(DiskCache.stableHash("docmost") == "14c10d7adef59502")
        #expect(DiskCache.safeName("a") == "a-af63dc4c8601ec8c")
        #expect(DiskCache.safeName("a") != DiskCache.safeName("b"))
        #expect(DiskCache.safeName("https://wiki.example.com") == "https___wiki_example_com-7dc434cdcfb05899")
    }

    @Test func pruneRemovesOldAndOversizedEntries() async {
        let cache = makeCache()
        await cache.writeData(Data(repeating: 1, count: 1000), key: "big")
        await cache.writeData(Data(repeating: 2, count: 10), key: "small")
        #expect(await cache.totalSize() == 1010)
        await cache.prune(maxAge: 3600, maxBytes: 500)
        #expect(await cache.totalSize() <= 500)
        await cache.removeAll()
        #expect(await cache.totalSize() == 0)
    }
}
