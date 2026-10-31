import Foundation
import DocmostKit

/// Writes downloads (attachments, database files, page exports) to the temporary directory for Quick Look or sharing.
/// Each server has its own folder, also for staged uploads (`UploadFile`): removing one server's files leaves another's
/// open previews and running uploads alone.
nonisolated enum TempFile {
    /// `folder` parts and `name` come from page content or the server, so each must stay one path component.
    static func write(_ data: Data, server: URL, folder: [String], name: String) throws -> URL {
        let directory = folder.reduce(directory(server: server)) { $0.appending(component: safeName($1), directoryHint: .isDirectory) }
        let file = directory.appending(component: safeName(name))
        // `standardized` is lexical; `standardizedFileURL` drops `/private` only from existing paths: fails on devices.
        guard file.standardized.deletingLastPathComponent() == directory.standardized else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable only while the device is unlocked, like the offline cache.
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    /// The server's folder, `tmp/servers/<server>`.
    static func directory(server: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "servers", directoryHint: .isDirectory)
            .appending(component: safeName(StoredAccounts.key(for: server)), directoryHint: .isDirectory)
    }

    /// Deletes the server's downloads; with `uploads` (signing out, removing the server) also its staged uploads, which a
    /// running upload reads. The folders of versions before per-server ones go too, as their server isn't known.
    static func removeAll(server: URL, uploads: Bool) {
        let directory = directory(server: server)
        let folders = uploads ? [directory] : ["attachments", "exports"].map { directory.appending(component: $0) }
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
