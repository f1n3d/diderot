import Foundation
import Testing
@testable import Diderot

/// The search the person and page pickers share: it waits for more typing, keeps what shows while it runs and when it
/// fails, and changes nothing once the next key has cancelled it.
struct BasePickerSearchTests {
    /// A stand-in for `suggestPeople` and `suggestPages`: records what it was asked and answers after `delay` on the
    /// test's clock, if one is set.
    @MainActor
    private final class Server {
        let clock: TestClock
        var asked: [String] = []
        var answer: Result<[String], any Error> = .success([])
        var delay: Duration?
        /// Answers even when cancelled, as a request already answered does.
        var ignoresCancellation = false

        init(clock: TestClock) { self.clock = clock }

        func suggest(_ query: String) async throws -> [String] {
            asked.append(query)
            if let delay {
                if ignoresCancellation { try? await clock.sleep(for: delay) } else { try await clock.sleep(for: delay) }
            }
            return try answer.get()
        }
    }

    private struct Offline: LocalizedError {
        var errorDescription: String? { "You are offline." }
    }

    /// A typed search asks the server once typing has paused for 250 ms; an empty one (the picker opening, the field
    /// cleared) asks at once.
    @Test func typedSearchWaitsForMoreTyping() async {
        let clock = TestClock()
        let server = Server(clock: clock)
        let search = BasePickerSearch<String>(clock: clock)
        server.answer = .success(["Ada", "Grace"])
        await search.load("", with: server.suggest)
        #expect(server.asked == [""])
        #expect(search.results == ["Ada", "Grace"])

        server.answer = .success(["Grace"])
        let typing = Task { await search.load("Gr", with: server.suggest) }
        await clock.advance(by: .milliseconds(249))
        #expect(server.asked == [""])
        #expect(!search.isLoading)
        await clock.advance(by: .milliseconds(1))
        await typing.value
        #expect(server.asked == ["", "Gr"])
        #expect(search.results == ["Grace"])
    }

    /// While a search runs, the results so far stay and it says it is loading; a failed one keeps them beside its reason,
    /// and the next that succeeds clears the reason.
    @Test func failedSearchKeepsTheResults() async {
        let clock = TestClock()
        let server = Server(clock: clock)
        let search = BasePickerSearch<String>(clock: clock)
        server.answer = .success(["Ada"])
        await search.load("", with: server.suggest)

        server.answer = .failure(Offline())
        server.delay = .seconds(1)
        let failing = Task { await search.load("", with: server.suggest) }
        await clock.advance(by: .zero)
        #expect(search.isLoading)
        #expect(search.results == ["Ada"])
        await clock.advance(by: .seconds(1))
        await failing.value
        #expect(!search.isLoading)
        #expect(search.results == ["Ada"])
        #expect(search.searchError == "You are offline.")

        server.answer = .success(["Ada", "Grace"])
        server.delay = nil
        await search.load("", with: server.suggest)
        #expect(search.results == ["Ada", "Grace"])
        #expect(search.searchError == nil)
    }

    /// The next key cancels a search: during the wait it doesn't ask; after, neither its answer nor a cancelled request
    /// changes what shows.
    @Test func cancelledSearchChangesNothing() async {
        let clock = TestClock()
        let server = Server(clock: clock)
        let search = BasePickerSearch<String>(clock: clock)
        server.answer = .success(["Ada"])
        await search.load("", with: server.suggest)

        server.answer = .success(["Grace"])
        let waiting = Task { await search.load("G", with: server.suggest) }
        await clock.advance(by: .milliseconds(100))
        waiting.cancel()
        await waiting.value
        #expect(server.asked == [""])

        server.delay = .seconds(1)
        let cancelled = Task { await search.load("", with: server.suggest) }
        await clock.advance(by: .zero)
        cancelled.cancel()
        await cancelled.value

        server.ignoresCancellation = true
        let answered = Task { await search.load("", with: server.suggest) }
        await clock.advance(by: .zero)
        answered.cancel()
        await clock.advance(by: .seconds(1))
        await answered.value
        #expect(server.asked == ["", "", ""])
        #expect(search.results == ["Ada"])
        #expect(search.searchError == nil)
        #expect(!search.isLoading)
    }
}
