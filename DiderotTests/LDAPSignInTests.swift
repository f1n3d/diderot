import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The LDAP sign-in sheet while its sign-in runs: it stays until the server answers. Cancel and a swipe-down closed it
    /// before, and an MFA challenge then had no sheet to ask for the code: the saved sign-in the start couldn't check
    /// waited for a code sheet that never opened, without Try Again or a retry.
    @Suite struct LDAPSignIn: SessionStubbing {
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

        /// Sign In on the sign-in screen the start couldn't check, with the server slow to answer: Cancel does nothing and
        /// a swipe doesn't close the sheet. The answer asks for an MFA code, and once the code sheet closes, the screen
        /// waits for the saved sign-in again.
        @Test(.timeLimit(.minutes(1))) func staysOpenWhileItSignsIn() async throws {
            let session = try await uncheckedStartOnA {
                // No network change: the retries wait, so only the sign-in screen decides.
                $0.networkReturns = {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                    return false
                }
            }
            defer { withExtendedLifetime(session) {} }
            let server = ServerInfo(url: a, workspace: nil)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"userHasMfa": true}}"# }
            let (answer, release) = AsyncStream<Void>.makeStream()
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/sso/ldap/p1/login" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { for await _ in answer { break } } }
            defer { resetStub() }

            let provider = try JSONDecoder().decode(AuthProvider.self, from: Data(#"{"id": "p1", "name": "Directory", "type": "ldap"}"#.utf8))
            let shown = Shown()
            let host = UIHostingController(rootView: Color.clear.linkSheet(isPresented: Bindable(shown).isPresented) {
                LDAPLoginView(provider: provider, server: server)
                    .environment(session)
            })
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.isHidden = false
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
            }

            let signInLabel = String(localized: "Sign In"), cancelLabel = String(localized: "Cancel")
            StubURLProtocol.requests.withLock { $0 = [] }
            #expect(await poll { host.presentedViewController.map { textFields(in: $0.view).count == 2 } ?? false },
                    "The sheet doesn't ask for a username and a password")
            let sheet = try #require(host.presentedViewController)
            for field in textFields(in: sheet.view) {
                field.becomeFirstResponder()
                field.insertText("u1")
            }
            #expect(await poll { button(in: sheet.view, labeled: signInLabel).map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false },
                    "Sign In stays off with a username and a password")
            #expect(try #require(button(in: sheet.view, labeled: signInLabel)).accessibilityActivate())
            #expect(await poll { StubURLProtocol.requests.withLock { $0.contains("a.example.com/api/sso/ldap/p1/login") } },
                    "Sign In doesn't sign in")

            #expect(await poll { sheet.isModalInPresentation }, "A swipe closes the sheet while it signs in")
            let cancel = try #require(button(in: sheet.view, labeled: cancelLabel))
            #expect(cancel.accessibilityTraits.contains(.notEnabled), "Cancel is on while it signs in")
            _ = cancel.accessibilityActivate()
            try await Task.sleep(for: .milliseconds(500))
            #expect(shown.isPresented && host.presentedViewController === sheet, "Cancel closed the sheet while it signed in")

            release.yield()
            #expect(await poll { sheet.presentedViewController != nil }, "No sheet asks for the MFA code")
            let codeSheet = try #require(sheet.presentedViewController)
            #expect(session.uncheckedSignIn == nil, "The saved sign-in is tried while the code is asked for")
            #expect(await poll { button(in: codeSheet.view, labeled: cancelLabel) != nil })
            _ = try #require(button(in: codeSheet.view, labeled: cancelLabel)).accessibilityActivate()
            #expect(await poll { sheet.presentedViewController == nil }, "Cancel doesn't close the code sheet")
            #expect(await poll { session.uncheckedSignIn?.token == "a" }, "The screen doesn't wait for the saved sign-in again")
            await removeCaches()
        }

        // MARK: Helpers

        /// Whether the sheet shows.
        @Observable final class Shown {
            var isPresented = true
        }

        private func resetStub() {
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = nil }
            StubURLProtocol.body.withLock { $0 = nil }
        }

        /// Polls `condition` while SwiftUI lays out (`tries` × 50 ms).
        private func poll(tries: Int = 200, _ condition: () -> Bool) async -> Bool {
            for _ in 0..<tries {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        /// The text fields in `view`, in the order they show.
        private func textFields(in view: UIView) -> [UITextField] {
            view.layoutIfNeeded()
            if let field = view as? UITextField { return [field] }
            return view.subviews.flatMap { textFields(in: $0) }
        }

        /// The first button VoiceOver can reach from `element` that reads `label` (the sheet's title reads "Sign In" too).
        private func button(in element: NSObject, labeled label: String) -> NSObject? {
            if element.accessibilityLabel == label, element.accessibilityTraits.contains(.button) { return element }
            let children = element.accessibilityElements as? [NSObject] ?? (element as? UIView)?.subviews ?? []
            for child in children {
                if let found = button(in: child, labeled: label) { return found }
            }
            return nil
        }
    }
}
