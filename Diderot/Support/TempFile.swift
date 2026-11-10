import Foundation
import DocmostKit

/// Keeps downloads (attachments, database files, page exports) in the temporary directory for Quick Look or sharing.
/// Each server has its own folder, also for staged uploads (`UploadFile`): removing one server's files leaves another's
/// open previews and running uploads alone.
nonisolated enum TempFile {
    /// Downloads the file at `url` with `client` straight to its place in the server's folder, under `name`, for Quick
    /// Look or sharing: nothing of it passes through memory (an attachment of some hundred MB took the app's).
    static func download(_ url: URL, with client: APIClient, server: URL, folder: [String], name: String) async throws -> URL {
        try take(try await client.downloadFile(at: url).file, server: server, folder: folder, name: name)
    }

    /// Takes a download as the file for Quick Look or sharing by moving it to its place. A download that can't be
    /// taken is removed.
    static func take(_ download: URL, server: URL, folder: [String], name: String) throws -> URL {
        do {
            let file = try place(server: server, folder: folder, name: name)
            try protect(download)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: download, to: file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: download)
            throw error
        }
    }

    /// A copy of `source` (a file of the offline cache) under its own name, for sharing; a copy on the same volume
    /// takes no room of its own.
    static func copy(_ source: URL, server: URL, folder: [String], name: String) throws -> URL {
        let file = try place(server: server, folder: folder, name: name)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: source, to: file)
        try protect(file)
        return file
    }

    /// Where a file of that name goes, its folder made. `folder` parts and `name` come from page content or the
    /// server, so each must stay one path component.
    private static func place(server: URL, folder: [String], name: String) throws -> URL {
        let directory = folder.reduce(directory(server: server)) { $0.appending(component: safeName($1), directoryHint: .isDirectory) }
        let file = directory.appending(component: safeName(name))
        // `standardized` is lexical; `standardizedFileURL` drops `/private` only from existing paths: fails on devices.
        guard file.standardized.deletingLastPathComponent() == directory.standardized else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return file
    }

    /// The folder of one media loader's files that are too large for the offline cache (`MediaLoader`), in the
    /// server's folder: signing out removes it with the rest.
    static func sessionMedia(server: URL) -> URL {
        directory(server: server).appending(component: "media", directoryHint: .isDirectory).appending(component: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Moves a download into `folder` under a name of its own, readable only while the device is unlocked.
    static func move(_ download: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try protect(download)
        let file = folder.appending(component: UUID().uuidString)
        try FileManager.default.moveItem(at: download, to: file)
        return file
    }

    /// Removes what media loaders of an earlier run left (the app was ended): for the app's start.
    static func removeSessionMedia() {
        let servers = FileManager.default.temporaryDirectory.appending(component: "servers", directoryHint: .isDirectory)
        for server in (try? FileManager.default.contentsOfDirectory(at: servers, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: server.appending(component: "media", directoryHint: .isDirectory))
        }
    }

    /// Readable only while the device is unlocked, like the offline cache. Only a device has file protection: the
    /// simulator's files are the Mac's, where some refuse the attempt (as `DiskCache.storeFile` found on GitHub's runners).
    private static func protect(_ file: URL) throws {
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #if targetEnvironment(simulator)
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: file.path(percentEncoded: false))
        #else
        try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path(percentEncoded: false))
        #endif
    }

    /// The server's folder, `tmp/servers/<server>`.
    static func directory(server: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "servers", directoryHint: .isDirectory)
            .appending(component: safeName(StoredAccounts.key(for: server)), directoryHint: .isDirectory)
    }

    /// Deletes the server's downloads and its media outside the offline cache; with `uploads` (signing out, removing the server) also its staged uploads, which a
    /// running upload reads. The folders of versions before per-server ones go too, as their server isn't known.
    static func removeAll(server: URL, uploads: Bool) {
        let directory = directory(server: server)
        // "media": the files too large for the offline cache (`sessionMedia`); what shows them loads them again.
        let folders = uploads ? [directory] : ["attachments", "exports", "media"].map { directory.appending(component: $0) }
        let unsorted = ["attachments", "exports", "uploads"].map { FileManager.default.temporaryDirectory.appending(component: $0) }
        for folder in folders + unsorted {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// `appending(component:)` keeps `/` and `..` and traps on NUL.
    private static func safeName(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        return ["", ".", ".."].contains(safe) ? "file" : safe
    }
}
