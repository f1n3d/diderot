import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The server entry (Change Server, Add Server…) with saved sign-ins: it leads back to each of them.
    @Suite struct ServerSetup: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// SwiftUI builds its accessibility tree only while assistive technology is on, so `element(in:)` finds nothing
        /// on a simulator that never had it. Turns it on for this process as XCUITest does (private, test target only).
        private static let accessibilityOn: Void = {
            let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
            for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
                if let symbol = dlsym(handle, name) { unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1) }
            }
        }()

        init() { _ = Self.accessibilityOn }

        /// Change Server on the sign-in screen of a saved server the start couldn't reach (b, behind a VPN that is off)
        /// leads to the other saved sign-in (a), which stays as it was. The server entry offered only Cancel, which
        /// restored b again, and typing a's address meant signing in there anew, which ends a's saved sign-in.
        @Test(.timeLimit(.minutes(1))) func leadsToAnotherSavedSignIn() async throws {
            try store.save(StoredSession(serverURL: a, token: "a", email: "u1@example.com", workspaceName: "Work"))
            try store.save(StoredSession(serverURL: b, token: "b", email: "u1@example.com", workspaceName: "Home"))
            await removeCaches()
            StubURLProtocol.offline.withLock { $0 = true }
            let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
            await session.restore()
            StubURLProtocol.offline.withLock { $0 = false }
            try #require(session.uncheckedSignIn?.serverURL == b)
            session.beginAddingServer()

            let screen = UIHostingController(rootView: ServerSetupView().environment(session))
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = screen
            window.isHidden = false
            defer { window.isHidden = true }

            // Its row reads "Work, a.example.com, u1@example.com"; no other text on the screen holds a's host.
            let host = try #require(a.host())
            #expect(await poll { element(in: screen.view, containing: host) != nil }, "The server entry doesn't list the saved sign-ins")
            let row = try #require(element(in: screen.view, containing: host))
            #expect(row.accessibilityActivate())
            #expect(await poll { session.ready != nil }, "The saved sign-in doesn't open")
            #expect(session.ready?.server.url == a && session.ready?.token == "a")
            #expect(try store.pendingLogouts().isEmpty, "A saved sign-in was ended")
            #expect(try store.loadAccounts().sessions.map(\.token).sorted() == ["a", "b"])
            await removeCaches()
        }

        // MARK: Helpers

        /// Polls `condition` while SwiftUI lays out (`tries` × 50 ms).
        private func poll(tries: Int = 200, _ condition: () -> Bool) async -> Bool {
            for _ in 0..<tries {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        /// The first element VoiceOver can reach from `element` whose label holds `text`.
        private func element(in element: NSObject, containing text: String) -> NSObject? {
            if element.accessibilityLabel?.contains(text) == true { return element }
            let children = element.accessibilityElements as? [NSObject] ?? (element as? UIView)?.subviews ?? []
            for child in children {
                if let found = self.element(in: child, containing: text) { return found }
            }
            return nil
        }
    }
}
