import Foundation
import Testing
@testable import Diderot

/// What a screen loads (`RemoteValue`): a load started later wins, the saved copy shows first and the answer is saved,
/// a failed refresh keeps what shows, a change made here outlives an earlier load.
struct RemoteValueTests {
    /// Runs a load whose fetch waits until `finish` is called, once it is under way.
    private final class HeldLoad {
        private let gate: AsyncStream<Void>
        private let opener: AsyncStream<Void>.Continuation
        private(set) var task: Task<Void, Never>?

        init() {
            (gate, opener) = AsyncStream<Void>.makeStream()
        }

        func start(on value: RemoteValue<Int>, answer: Int) async {
            let (started, signal) = AsyncStream<Void>.makeStream()
            let gate = gate
            task = Task {
                await value.load {
                    signal.yield()
                    for await _ in gate { break }
                    return answer
                }
            }
            for await _ in started { break }
        }

        func finish() async {
            opener.yield()
            await task?.value
        }
    }

    @Test(.timeLimit(.minutes(1))) func aLaterLoadWins() async {
        let value = RemoteValue<Int>()
        let early = HeldLoad()
        await early.start(on: value, answer: 1)
        await value.load { 2 }
        await early.finish()
        #expect(value.value == 2)
    }

    @Test func theSavedCopyShowsFirstAndTheAnswerIsSaved() async {
        let value = RemoteValue<[String]>()
        var saved: [String]?
        var shownWhileLoading: [String]?
        await value.load(cached: { ["saved"] }, save: { saved = $0 }) {
            shownWhileLoading = value.value
            return ["new"]
        }
        #expect(shownWhileLoading == ["saved"])
        #expect(value.value == ["new"] && saved == ["new"])
    }

    /// Without a value an error shows; with one, a failed refresh keeps it and says what failed; a cancelled load (its
    /// screen closing) changes nothing.
    @Test func aFailedRefreshKeepsTheValue() async {
        let value = RemoteValue<Int>()
        await value.load { throw CancellationError() }
        if case .failed = value.state { Issue.record("A cancelled load showed an error") }
        let first = await value.load { throw URLError(.notConnectedToInternet) }
        #expect(first == nil)
        guard case .failed = value.state else {
            Issue.record("Nothing to show, yet no error")
            return
        }
        await value.load { 1 }
        let refresh = await value.load { throw URLError(.timedOut) }
        #expect(refresh != nil && value.value == 1)
    }

    /// A comment added here shows at once; the answer of a load started before it would predate it.
    @Test(.timeLimit(.minutes(1))) func aChangeShownHereOutlivesAnEarlierLoad() async {
        let value = RemoteValue<Int>()
        await value.load { 1 }
        let reload = HeldLoad()
        await reload.start(on: value, answer: 1)
        value.show(2)
        await reload.finish()
        #expect(value.value == 2)
    }

    /// Another query's value (a scope switched) goes at once; a spinner shows until the answer. The same query's stays
    /// while it refreshes, as back from a template's preview: the list started over at the top (code review V38).
    @Test func aLoadForAnotherKeyDropsTheValueOneForTheSameKeepsIt() async {
        let value = RemoteValue<Int>()
        await value.load(for: "space") { 1 }
        var shownWhileLoading: Int?
        await value.load(for: "space") {
            shownWhileLoading = value.value
            return 2
        }
        #expect(shownWhileLoading == 1 && value.value == 2)
        await value.load(for: "all") {
            shownWhileLoading = value.value
            return 3
        }
        #expect(shownWhileLoading == nil && value.value == 3)
    }
}
