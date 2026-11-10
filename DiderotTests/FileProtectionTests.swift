import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// The offline cache and downloads can be read only while the device is unlocked, so a locked device doesn't give away
/// pages. Unsent changes, written as the app goes to the background and the device may lock, from the first unlock on.
/// On a device only: the simulator reports the same class for every file, even one written without protection.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil, "The simulator ignores file protection"))
struct FileProtectionTests {
    private func protection(of url: URL) throws -> URLFileProtection? {
        try url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
    }

    private func onlyFile(in directory: URL) throws -> URL {
        try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    }

    @Test func cacheAndDownloadsOnlyWhileUnlocked() async throws {
        let cache = DiskCache(scope: "protection", baseDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        await cache.writeData(Data("x".utf8), key: "page")
        #expect(try protection(of: onlyFile(in: cache.directory)) == .complete)
        // A download the cache takes as a file gets the same, whatever it was written with.
        let downloaded = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("y".utf8).write(to: downloaded, options: .noFileProtection)
        #expect(try protection(of: await cache.storeFile(at: downloaded, key: "file")) == .complete)

        let server = URL(string: "https://protection-test.example.com")!
        let arrived = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("x".utf8).write(to: arrived, options: .noFileProtection)
        let download = try TempFile.take(arrived, server: server, folder: ["attachments", UUID().uuidString], name: "a.pdf")
        defer { try? FileManager.default.removeItem(at: download.deletingLastPathComponent()) }
        #expect(try protection(of: download) == .complete)
    }

    @Test func unsentChangesFromTheFirstUnlock() async throws {
        let server = URL(string: "https://protection-test.example.com")!
        defer { UnsentChanges.removeAll(server: server) }
        let store = UnsentChanges.store(server: server, userId: "u1")
        try await store.writeData(Data("x".utf8), key: "change")
        #expect(try protection(of: onlyFile(in: store.directory)) == .completeUntilFirstUserAuthentication)
    }
}
