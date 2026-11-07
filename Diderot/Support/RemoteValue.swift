import Foundation

/// A value a screen loads from the server, in one place: its state (`LoadState`), loads that can't overlap (one started
/// later wins, an earlier one's answer is dropped), the saved copy shown first and the answer saved, if the screen keeps
/// one. While a value shows, a failed refresh leaves it: `load` returns the error, for a screen that says so.
@MainActor
@Observable
final class RemoteValue<Value: Sendable> {
    private(set) var state: LoadState<Value> = .idle
    @ObservationIgnored private var loads = 0
    /// What the last load was for (`load(for:)`).
    @ObservationIgnored private var key: AnyHashable?

    var value: Value? { state.value }

    init() {}

    /// Loads with `fetch`. While nothing shows, `cached` shows first if it has a copy, else a spinner; `save` keeps the
    /// answer. `key`: what the value is for, such as a scope. A load for another key than the last one's starts over,
    /// as what shows belongs to another query; one for the same key refreshes what shows, which keeps the place in it.
    /// Returns the error of a failed refresh while a value shows. A cancelled load (its screen closing) and an answer a
    /// later load overtook change nothing.
    @discardableResult
    func load(for key: AnyHashable? = nil, cached: (() async -> Value?)? = nil, save: ((Value) async -> Void)? = nil,
              fetch: () async throws -> Value) async -> (any Error)? {
        loads += 1
        let load = loads
        if key != self.key {
            state = .idle
            self.key = key
        }
        if state.value == nil {
            if let saved = await cached?(), load == loads, state.value == nil {
                state = .loaded(saved)
            } else if state.value == nil {
                state = .loading
            }
        }
        do {
            let value = try await fetch()
            guard load == loads else { return nil }
            state = .loaded(value)
            await save?(value)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard load == loads else { return nil }
            guard state.value != nil else {
                state = .failed(error)
                return nil
            }
            return error
        }
    }

    /// Shows `value`, made here (a comment added, an entry removed): the answer of a load started before it would predate
    /// it and is dropped; the next load brings the server's.
    func show(_ value: Value) {
        loads += 1
        state = .loaded(value)
    }
}
