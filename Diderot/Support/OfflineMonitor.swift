import Foundation
import Network
import Observation

/// Reachability for the offline banner; loaders show cached content on failed requests, not on this status alone.
@MainActor
@Observable
final class OfflineMonitor {
    private(set) var isOffline = false
    private let monitor = NWPathMonitor()
    /// The network's state while `DebugLaunch.offlineSeconds` pretends to be offline.
    private var pathIsOffline = false
    private var pretendsOffline = false

    init() {
        if let seconds = DebugLaunch.offlineSeconds {
            pretendsOffline = true
            isOffline = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                pretendsOffline = false
                isOffline = pathIsOffline
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.pathIsOffline = offline
                if !self.pretendsOffline { self.isOffline = offline }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.f1n3d.diderot.network"))
    }

    deinit {
        monitor.cancel()
    }
}
