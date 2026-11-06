import Testing
import UIKit
@testable import Diderot

/// Backspace at the start of the editor's text (`TextInputHooks`). Each test hooks a text view class of its own: a hook
/// stays on its class for the rest of the run.
@MainActor
@Suite(.serialized)
struct TextInputHooksTests {
    /// A text view with "ab" and the cursor at `location`.
    private static func view<View: UITextView>(_: View.Type, cursorAt location: Int) -> View {
        let view = View()
        view.text = "ab"
        view.selectedRange = NSRange(location: location, length: 0)
        return view
    }

    /// Counts the handler's calls and answers `handles`, until the test ends.
    private final class Handler {
        var calls = 0
        var handles = true

        init() {
            TextInputHooks.onBackspaceAtStart = { [unowned self] _ in
                calls += 1
                return handles
            }
        }

        func stop() { TextInputHooks.onBackspaceAtStart = nil }
    }

    @Test func backspaceAtTheStartAsksTheHandler() {
        let handler = Handler()
        defer { handler.stop() }
        let view = Self.view(StartTextView.self, cursorAt: 0)
        TextInputHooks.install(on: view)

        view.deleteBackward()
        #expect(handler.calls == 1)
        #expect(view.text == "ab")

        // Not handled: the text view's own Backspace runs, which has nothing to delete at the start.
        handler.handles = false
        view.deleteBackward()
        #expect(handler.calls == 2)
        #expect(view.text == "ab")
    }

    /// Elsewhere the handler isn't asked, and the text view deletes as it would without the hook (the inherited
    /// implementation, looked up at the call).
    @Test func backspaceElsewhereDeletes() {
        let handler = Handler()
        defer { handler.stop() }
        let view = Self.view(InheritingTextView.self, cursorAt: 2)
        TextInputHooks.install(on: view)

        view.deleteBackward()
        #expect(handler.calls == 0)
        #expect(view.text == "a")
    }

    /// A class with its own `deleteBackward` keeps it behind the hook.
    @Test func ownBackspaceStaysBehindTheHook() {
        let handler = Handler()
        defer { handler.stop() }
        let view = Self.view(OwnBackspaceTextView.self, cursorAt: 2)
        TextInputHooks.install(on: view)

        view.deleteBackward()
        #expect(view.ownCalls == 1)
        #expect(view.text == "a")
        #expect(handler.calls == 0)
    }

    /// The inherited implementation is looked up at each call: a change on the superclass after the hook (another
    /// hook there) still runs.
    @Test func laterSuperclassChangeStillRuns() throws {
        let handler = Handler()
        defer { handler.stop() }
        let view = Self.view(LateChildTextView.self, cursorAt: 2)
        TextInputHooks.install(on: view)
        var superclassCalls = 0
        let block: @convention(block) (AnyObject) -> Void = { _ in superclassCalls += 1 }
        let selector = #selector(UITextView.deleteBackward)
        let method = try #require(class_getInstanceMethod(UITextView.self, selector))
        #expect(class_addMethod(LateParentTextView.self, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method)))

        view.deleteBackward()
        #expect(superclassCalls == 1)
    }

    /// A subclass of a hooked class gets no second hook, which would ask the handler twice when it passes Backspace on.
    @Test func subclassOfAHookedClassAsksOnce() {
        let handler = Handler()
        defer { handler.stop() }
        handler.handles = false
        TextInputHooks.install(on: Self.view(ParentTextView.self, cursorAt: 0))
        let child = Self.view(ChildTextView.self, cursorAt: 0)
        TextInputHooks.install(on: child)

        child.deleteBackward()
        #expect(handler.calls == 1)
    }

    /// Hooked while observed, the hook stays once the observation ends: it's on the view's class, not KVO's.
    @Test func hookOutlivesAnObservation() {
        let handler = Handler()
        defer { handler.stop() }
        let view = Self.view(ObservedTextView.self, cursorAt: 0)
        let observation = view.observe(\.text) { _, _ in }
        TextInputHooks.install(on: view)
        observation.invalidate()

        view.deleteBackward()
        #expect(handler.calls == 1)
    }
}

private class StartTextView: UITextView {}
private class InheritingTextView: UITextView {}
private class ParentTextView: UITextView {}
private class ChildTextView: ParentTextView {}
private class ObservedTextView: UITextView {}
private class LateParentTextView: UITextView {}
private class LateChildTextView: LateParentTextView {}

private class OwnBackspaceTextView: UITextView {
    var ownCalls = 0

    override func deleteBackward() {
        ownCalls += 1
        super.deleteBackward()
    }
}
