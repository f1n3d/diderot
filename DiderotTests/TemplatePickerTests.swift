import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The template picker while a template is being used: it stays until the template is used. Cancel and a swipe-down
    /// closed it before, and the page was still made, or filled, a moment later.
    @Suite struct TemplatePicker: SessionStubbing {
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

        /// "Use" on a row, with the template's content slow to come: the row shows progress, Cancel does nothing and a
        /// swipe doesn't close the sheet. Once the answer is there the template is used, once, and the picker closes.
        @Test(.timeLimit(.minutes(1))) func staysOpenWhileATemplateIsUsed() async throws {
            let session = try await sessionOnA()
            defer { withExtendedLifetime(session) {} }
            let spaces = SpacesStore(session: session)
            StubURLProtocol.body.withLock { $0 = Self.answer }
            let (answer, release) = AsyncStream<Void>.makeStream()
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/templates/info" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { for await _ in answer { break } } }
            defer { resetStub() }

            var used: [String] = []
            let shown = Shown()
            let host = UIHostingController(rootView: Color.clear.linkSheet(isPresented: Bindable(shown).isPresented) {
                TemplatePickerView(spaceId: nil, action: "Create Page") { template, _ in used.append(template.id) }
                    .environment(session)
                    .environment(spaces)
            })
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.isHidden = false
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
            }

            let useLabel = String(localized: "Use"), cancelLabel = String(localized: "Cancel")
            #expect(await poll { host.presentedViewController.map { element(in: $0.view, labeled: useLabel) != nil } ?? false },
                    "The picker doesn't list the template")
            let picker = try #require(host.presentedViewController)
            #expect(try #require(element(in: picker.view, labeled: useLabel)).accessibilityActivate())
            #expect(await poll { StubURLProtocol.requests.withLock { $0.contains("a.example.com/api/templates/info") } },
                    "“Use” doesn't read the template")

            #expect(await poll { spinner(in: picker.view) && element(in: picker.view, labeled: useLabel) == nil },
                    "The row shows no progress while the template is used")
            #expect(picker.isModalInPresentation, "A swipe closes the picker while the template is used")
            let cancel = try #require(element(in: picker.view, labeled: cancelLabel))
            #expect(cancel.accessibilityTraits.contains(.notEnabled), "Cancel is on while the template is used")
            _ = cancel.accessibilityActivate()
            try await Task.sleep(for: .milliseconds(500))
            #expect(shown.isPresented && host.presentedViewController === picker, "Cancel closed the picker while the template was used")

            release.yield()
            #expect(await poll { used == ["t1"] }, "The template isn't used")
            #expect(await poll { !shown.isPresented && host.presentedViewController == nil }, "The picker doesn't close once the template is used")
            await removeCaches()
        }

        // MARK: Helpers

        /// Whether the sheet shows.
        @Observable final class Shown {
            var isPresented = true
        }

        /// One answer for the list and the template's content, as the stub gives each the same: the list reads `items`
        /// and `meta`, `templates/info` the template around them, which has no fields.
        private static let answer = #"""
            {"data": {"id": "t1", "title": "Protokoll", "spaceId": null,
                      "content": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Agenda"}]}]},
                      "items": [{"id": "t1", "title": "Protokoll", "spaceId": null}], "meta": {"hasNextPage": false}}}
            """#

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

        private func spinner(in view: UIView) -> Bool {
            view.layoutIfNeeded()
            return view is UIActivityIndicatorView || view.subviews.contains { spinner(in: $0) }
        }

        /// The first element VoiceOver can reach from `element` that reads `label`.
        private func element(in element: NSObject, labeled label: String) -> NSObject? {
            if element.accessibilityLabel == label { return element }
            let children = element.accessibilityElements as? [NSObject] ?? (element as? UIView)?.subviews ?? []
            for child in children {
                if let found = self.element(in: child, labeled: label) { return found }
            }
            return nil
        }
    }
}
