import Foundation
import Testing
@testable import DocmostKit

struct DiskCacheTests {
    private func makeCache() -> DiskCache {
        let base = FileManager.default.temporaryDirectory.appending(path: "docmost-cache-tests-\(UUID().uuidString)")
        return DiskCache(scope: "https://wiki.example.com", baseDirectory: base)
    }

    /// A file as a download leaves it, for the cache to take.
    private func download(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString).tmp")
        try data.write(to: file)
        return file
    }

    @Test func roundTripsCodableValues() async throws {
        let cache = makeCache()
        let page = try TestSupport.decodeFixture(Page.self, "page-info")
        await cache.write(page, key: "page/\(page.id)")
        #expect(await cache.read(Page.self, key: "page/\(page.id)") == page)
        #expect(await cache.read(Page.self, key: "page/missing") == nil)
        await cache.removeAll()
    }

    @Test func storesRawData() async throws {
        let cache = makeCache()
        let key = "https://wiki.example.com/api/files/a/b.png@512"
        let data = Data([1, 2, 3, 4])
        try await cache.storeFile(at: download(data), key: key)
        let file = try #require(await cache.dataFile(key: key))
        #expect(try Data(contentsOf: file) == data)
        await cache.remove(key: key)
        #expect(await cache.dataFile(key: key) == nil)
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

    /// A download becomes the entry by moving in, without passing through memory, and reads as a file.
    @Test func takesAFileAsTheEntry() async throws {
        let cache = makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(await cache.dataFile(key: "image/a") == nil)

        let first = try download(Data("first".utf8))
        let stored = try await cache.storeFile(at: first, key: "image/a")
        #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)), "moved, not copied")
        #expect(await cache.dataFile(key: "image/a") == stored)
        #expect(try Data(contentsOf: stored) == Data("first".utf8))

        // A newer download replaces it in the same place.
        #expect(try await cache.storeFile(at: download(Data("second".utf8)), key: "image/a") == stored)
        #expect(try Data(contentsOf: stored) == Data("second".utf8))
        #expect(await cache.totalSize() == 6)

        await cache.remove(key: "image/a")
        #expect(await cache.dataFile(key: "image/a") == nil)
    }

    @Test func pruneRemovesOldAndOversizedEntries() async throws {
        let cache = makeCache()
        try await cache.storeFile(at: download(Data(repeating: 1, count: 1000)), key: "big")
        try await cache.storeFile(at: download(Data(repeating: 2, count: 10)), key: "small")
        #expect(await cache.totalSize() == 1010)
        await cache.prune(maxAge: 3600, maxBytes: 500)
        #expect(await cache.totalSize() <= 500)
        await cache.removeAll()
        #expect(await cache.totalSize() == 0)
    }
}
