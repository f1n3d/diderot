import os
import DocmostKit

/// Central loggers. View with `log stream --predicate 'subsystem == "io.github.f1n3d.diderot"'`.
/// `nonisolated` so actors and `@Sendable` closures can use them.
nonisolated enum AppLog {
    static let subsystem = "io.github.f1n3d.diderot"
    static let session = Logger(subsystem: subsystem, category: "session")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Request logger for `APIClient`; never logs tokens or bodies.
    static let apiRequestLogger: @Sendable (APIRequestLog) -> Void = { entry in
        let millis = Int(entry.duration * 1000)
        if let error = entry.error {
            api.error("\(entry.method, privacy: .public) \(entry.path, privacy: .public) failed after \(millis)ms: \(error, privacy: .public)")
        } else {
            api.debug("\(entry.method, privacy: .public) \(entry.path, privacy: .public) → \(entry.status ?? 0) in \(millis)ms")
        }
    }
}
