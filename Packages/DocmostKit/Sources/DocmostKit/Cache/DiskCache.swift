import Foundation

/// Per-server key → data file cache for offline reading. No database on purpose: every access is by key (space list,
/// page tree level, page, image).
public actor DiskCache {
    /// When its files can be read (iOS data protection).
    public enum Protection: Sendable {
        /// Only while the device is unlocked: the offline cache, so a locked device doesn't give away its pages.
        case whileUnlocked
        /// From the first unlock after a restart on: what the app must still write when it goes to the background
        /// and the device locks, such as unsent changes.
        case afterFirstUnlock
    }

    public nonisolated let directory: URL
    private let protection: Protection
    private let decoder = JSONDecoding.makeDecoder()
    private let encoder = JSONDecoding.makeEncoder()

    /// - Parameter scope: e.g. a hash of the server URL, keeping servers apart.
    public init(scope: String, baseDirectory: URL? = nil, protection: Protection = .whileUnlocked) {
        let base = baseDirectory ?? URL.cachesDirectory
        directory = base.appending(path: "docmost-cache/\(Self.safeName(scope))")
        self.protection = protection
    }

    // MARK: - Codable values

    public func read<Value: Decodable & Sendable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(for: key, kind: "json")) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }

    public func write<Value: Encodable & Sendable>(_ value: Value, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        store(data, at: fileURL(for: key, kind: "json"))
    }

    // MARK: - Raw data (images, files)

    public func readData(key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key, kind: "bin"))
    }

    public func writeData(_ data: Data, key: String) {
        store(data, at: fileURL(for: key, kind: "bin"))
    }

    // MARK: - Maintenance

    public func remove(key: String) {
        for kind in ["json", "bin"] {
            try? FileManager.default.removeItem(at: fileURL(for: key, kind: kind))
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes entries older than `maxAge` and caps the total size (oldest first).
    public func prune(maxAge: TimeInterval = 30 * 24 * 3600, maxBytes: Int = 300 << 20) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries = urls.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date, values.fileSize ?? 0)
        }
        let cutoff = Date.now.addingTimeInterval(-maxAge)
        for entry in entries where entry.1 < cutoff {
            try? FileManager.default.removeItem(at: entry.0)
        }
        entries = entries.filter { $0.1 >= cutoff }.sorted { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        for entry in entries where total > maxBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.2
        }
    }

    public func totalSize() -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - Internal

    private func store(_ data: Data, at url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let protection: Data.WritingOptions = switch self.protection {
        case .whileUnlocked: .completeFileProtection
        case .afterFirstUnlock: .completeFileProtectionUntilFirstUserAuthentication
        }
        try? data.write(to: url, options: [.atomic, protection])
    }

    private func fileURL(for key: String, kind: String) -> URL {
        directory.appending(path: "\(Self.safeName(key)).\(kind)")
    }

    /// File name for an arbitrary key: readable prefix plus stable hash.
    static func safeName(_ key: String) -> String {
        let allowed = key.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return c.isLetter || c.isNumber || c == "-" || c == "_" ? c : "_"
        }
        let prefix = String(allowed.prefix(48))
        return "\(prefix)-\(stableHash(key))"
    }

    /// 64-bit FNV-1a, stable across process launches (unlike `hashValue`).
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
