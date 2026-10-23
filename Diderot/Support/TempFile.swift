import Foundation

/// Writes downloads (attachments, database files, page exports) to the temporary directory for Quick Look or sharing.
nonisolated enum TempFile {
    /// `folder` parts and `name` come from page content or the server, so each must stay one path component.
    static func write(_ data: Data, folder: [String], name: String) throws -> URL {
        let directory = folder.reduce(FileManager.default.temporaryDirectory) { $0.appending(component: safeName($1), directoryHint: .isDirectory) }
        let file = directory.appending(component: safeName(name))
        // `standardized` is lexical; `standardizedFileURL` drops `/private` only from existing paths: fails on devices.
        guard file.standardized.deletingLastPathComponent() == directory.standardized else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable only while the device is unlocked, like the offline cache.
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    /// Deletes all downloads: the top-level folders callers write to.
    static func removeAll() {
        for folder in ["attachments", "exports"] {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(component: folder))
        }
    }

    /// `appending(component:)` keeps `/` and `..` and traps on NUL.
    private static func safeName(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        return ["", ".", ".."].contains(safe) ? "file" : safe
    }
}
