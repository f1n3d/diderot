import Foundation
import OSLog

/// Writes this process's logs to a text file for "Export Logs" in Settings.
nonisolated enum LogExporter {
    @concurrent static func export(lastHours: Int = 12) async throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-TimeInterval(lastHours) * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", AppLog.subsystem)
        let entries = try store.getEntries(at: position, matching: predicate)

        var text = "Diderot logs – exported \(Date().formatted(.iso8601))\n\n"
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            text += "\(log.date.formatted(.iso8601)) [\(log.category)] \(log.level.label) \(log.composedMessage)\n"
        }

        let url = FileManager.default.temporaryDirectory.appending(path: "docmost-logs.txt")
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

nonisolated private extension OSLogEntryLog.Level {
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "-"
        @unknown default: return "-"
        }
    }
}
