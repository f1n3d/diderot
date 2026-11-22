import Foundation
import Network

/// A server on this Mac that reads every request and never answers, as a server busy with a long one does: a request
/// to it goes out whole and then times out. `MockURLProtocol` can't stand in for it, since URLSession sends nothing
/// itself for a request a `URLProtocol` answers.
final class SilentServer: Sendable {
    let url: URL
    private let listener: NWListener

    init() async throws {
        let parameters = NWParameters.tcp
        // Only on the loopback address: nothing outside the Mac reaches it.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "SilentServer")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.read(connection)
        }
        listener.start(queue: queue)
        let deadline = ContinuousClock.now + .seconds(5)
        while listener.state != .ready {
            if case .failed(let error) = listener.state { throw error }
            guard ContinuousClock.now < deadline else { throw URLError(.cannotConnectToHost) }
            try await Task.sleep(for: .milliseconds(10))
        }
        url = URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")!
    }

    deinit {
        listener.cancel()
    }

    /// Reads until the client closes the connection; the waiting read keeps it open.
    private static func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
            } else {
                read(connection)
            }
        }
    }
}
