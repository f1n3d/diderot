import UIKit

/// Lets work the user started finish when the app goes to the background, for as long as iOS allows. The background
/// task ends with the work, or in iOS's expiration handler when the time is up: a task still running then ends the app,
/// and with it the work's unsaved part.
enum BackgroundWork {
    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let task = Token()
        task.id = UIApplication.shared.beginBackgroundTask(withName: name) { task.end() }
        Task {
            await work()
            task.end()
        }
    }

    private final class Token {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
