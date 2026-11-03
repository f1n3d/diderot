import Foundation

/// What the server hasn't confirmed yet, kept for one server and user until it goes out (the app's `UnsentChanges`):
/// unlike the offline cache (`DiskCache`), every read and write says when it fails, and `update` changes a value in one
/// step. Its files are readable from the first unlock after a restart on: they are written as the app goes to the
/// background, when the device may lock any moment.
public actor UnsentStore {
    public nonisolated let directory: URL
    private let decoder = JSONDecoding.makeDecoder()
    private let encoder = JSONDecoding.makeEncoder()

    public init(directory: URL) {
        self.directory = directory
    }

    /// The value, nil without one; throws for a file it can't read or decode, as the next write would replace it.
    public func read<Value: Decodable & Sendable>(_ type: Value.Type, key: String) throws -> Value? {
        try readData(key: key, kind: "json").map { try decoder.decode(Value.self, from: $0) }
    }

    public func write<Value: Encodable & Sendable>(_ value: Value, key: String) throws {
        try store(encoder.encode(value), at: fileURL(for: key, kind: "json"))
    }

    /// Changes the value (`initial` if there is none) in one step: nothing else reaches this store between the read and
    /// the write. Throws, changing nothing, if the stored value can't be read or the new one can't be written.
    @discardableResult
    public func update<Value: Codable & Sendable, Result: Sendable>(
        _ type: Value.Type, key: String, initial: Value, _ change: @Sendable (inout Value) throws -> Result
    ) throws -> Result {
        var value = try read(type, key: key) ?? initial
        let result = try change(&value)
        try write(value, key: key)
        return result
    }

    public func readData(key: String) throws -> Data? {
        try readData(key: key, kind: "bin")
    }

    public func writeData(_ data: Data, key: String) throws {
        try store(data, at: fileURL(for: key, kind: "bin"))
    }

    /// Removes the value or data under `key`; none there is no error.
    public func remove(key: String) throws {
        for kind in ["json", "bin"] {
            do {
                try FileManager.default.removeItem(at: fileURL(for: key, kind: kind))
            } catch CocoaError.fileNoSuchFile {}
        }
    }

    /// A file or folder name for any text (a server's URL, a user id, a key): its letters, digits, `-` and `_`, the
    /// others as `_`, at most 48, then a hash of the whole text. Fixed: the files kept so far are found by it.
    public static func name(for text: String) -> String {
        let readable = text.unicodeScalars.map { scalar -> Character in
            let character = Character(scalar)
            return character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        // 64-bit FNV-1a: stable across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "\(String(readable.prefix(48)))-\(String(hash, radix: 16))"
    }

    private func readData(key: String, kind: String) throws -> Data? {
        do {
            return try Data(contentsOf: fileURL(for: key, kind: kind))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private func store(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func fileURL(for key: String, kind: String) -> URL {
        directory.appending(path: "\(Self.name(for: key)).\(kind)")
    }
}
