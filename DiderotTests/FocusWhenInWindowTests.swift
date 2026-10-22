import Testing
import UIKit
@testable import Diderot

/// The lazy list can move a built editor into another container, losing window and focus on the way. The signal fires
/// again so the editor refocuses (otherwise the floating "+" at the page end shows no editor).
struct FocusWhenInWindowTests {
    @Test func signalsAgainAfterAMove() async throws {
        var signals = 0
        let view = FocusWhenInWindow.SignalView { signals += 1 }
        let window = UIWindow(windowScene: try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        let container = UIView()
        window.addSubview(container)
        window.addSubview(view)
        view.removeFromSuperview()
        container.addSubview(view)
        try await Task.sleep(for: .milliseconds(100))
        #expect(signals == 2)
    }
}
