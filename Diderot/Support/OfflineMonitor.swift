import Foundation
import Network
import Observation

/// Reachability for the offline banner; loaders show cached content on failed requests, not on this status alone.
@MainActor
@Observable
final class OfflineMonitor {
    private(set) var isOffline = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.isOffline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.f1n3d.diderot.network"))
    }

    deinit {
        monitor.cancel()
    }
}
