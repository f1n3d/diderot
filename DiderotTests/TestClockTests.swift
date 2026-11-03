import Foundation
import Testing
@testable import Diderot

/// The clock tests move by hand (`TestClock`): a sleep ends at its deadline, not before, and when cancelled.
struct TestClockTests {
    private final class Flag {
        var isSet = false
    }

    @Test(.timeLimit(.minutes(1))) func aSleepEndsWhenTheClockPassesItsDeadline() async {
        let clock = TestClock()
        let woke = Flag()
        let sleeper = Task { @MainActor in
            try? await clock.sleep(for: .milliseconds(400))
            woke.isSet = true
        }
        await clock.advance(by: .milliseconds(399))
        #expect(!woke.isSet)
        await clock.advance(by: .milliseconds(1))
        #expect(woke.isSet)
        await sleeper.value
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledSleepEnds() async {
        let clock = TestClock()
        let sleeper = Task { @MainActor in
            do {
                try await clock.sleep(for: .seconds(1))
                return false
            } catch {
                return error is CancellationError
            }
        }
        await Task.yield()
        sleeper.cancel()
        #expect(await sleeper.value)
    }
}
