import Foundation
import Synchronization

/// A clock a test moves by hand: a sleep on it ends once `advance(by:)` has moved it to the sleep's deadline, and
/// `advance` then lets the main actor run what the sleeps woke. A test of what must or must not happen after a wait (a
/// save after the wait for more input) checks it after the wait itself, not after real time that a busy main actor may
/// not have spent on it.
nonisolated final class TestClock: Clock, Sendable {
    nonisolated struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = [:]
        /// Sleeps cancelled before they were waiting.
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ended: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = (deadline, continuation)
                    return nil
                }
                if let ended { continuation.resume(with: ended) }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return nil as CheckedContinuation<Void, any Error>?
                }
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock by `duration`, ends the sleeps it passes and lets the main actor run what they woke. First it lets
    /// the main actor start what was scheduled meanwhile (a debounce's task), so its sleep counts from before the move.
    @MainActor
    func advance(by duration: Duration) async {
        for _ in 0..<100 { await Task.yield() }
        let woken = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in woken { continuation.resume() }
        for _ in 0..<100 { await Task.yield() }
    }

    deinit {
        // A test that ends with sleeps still waiting (a debounce it didn't move past) ends them.
        let waiting = state.withLock { state in
            defer { state.sleepers = [:] }
            return state.sleepers.values.map(\.continuation)
        }
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }
}
