import SwiftUI
import UIKit

/// Reports the keyboard's top edge (accessory bar included) in window coordinates and its animation duration. The page
/// view turns off SwiftUI's keyboard avoidance and centers the active block itself, in one motion with the keyboard.
@MainActor
final class KeyboardObserver {
    private var token: NotificationCenter.ObservationToken?

    /// `top` is `nil` when the keyboard hides or isn't docked at the bottom (floating iPad keyboard).
    func start(onChange: @escaping @MainActor (_ top: CGFloat?, _ duration: Double) -> Void) {
        stop()
        token = NotificationCenter.default.addObserver(of: UIScreen.self, for: .keyboardWillChangeFrame) { message in
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
                onChange(nil, max(message.animationDuration, 0.1))
                return
            }
            let frame = window.convert(message.endFrame, from: window.screen.coordinateSpace)
            let bottom = window.bounds.maxY
            let docked = frame.height > 0 && frame.minY < bottom - 1 && frame.maxY >= bottom - 1
            onChange(docked ? frame.minY : nil, max(message.animationDuration, 0.1))
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

/// Signals when the editor it sits behind is in the window; only then may the editor request focus. An earlier
/// request fails (no window yet), yet SwiftUI already resigns the previous editor, so the keyboard hides and reappears;
/// in the window, UIKit hands focus over directly. Signals again when the lazy list moves the editor to another
/// container: leaving the window on the way costs it its focus.
struct FocusWhenInWindow: UIViewRepresentable {
    let request: () -> Void

    func makeUIView(context: Context) -> SignalView {
        SignalView(request: request)
    }

    func updateUIView(_ view: SignalView, context: Context) {
        view.request = request
    }

    final class SignalView: UIView {
        var request: () -> Void

        init(request: @escaping () -> Void) {
            self.request = request
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Next run loop: by then the sibling text field is in the window too.
            DispatchQueue.main.async { [weak self] in self?.request() }
        }
    }
}

/// The current first responder, for the active `TextEditor`'s text view and caret, which SwiftUI doesn't expose.
enum FirstResponder {
    fileprivate static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.docmostReportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    /// Caret (selection end) of the active text field in window coordinates, or `nil` without a usable value (yet):
    /// right after fast typing, the field sometimes returns an empty rect at the start.
    static var caretRectInWindow: CGRect? {
        guard let input = current as? (UIView & UITextInput), let range = input.selectedTextRange else { return nil }
        input.layoutIfNeeded()
        let caret = input.caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite, caret.height >= 8 else { return nil }
        return input.convert(caret, to: nil)
    }
}

private extension UIResponder {
    @objc func docmostReportFirstResponder() {
        FirstResponder.found = self
    }
}

/// Backspace at the start of the page editor's text, which SwiftUI's `TextEditor` doesn't report (the text doesn't
/// change). The editor used to put an invisible character there for Backspace to delete, but iOS then saw a letter
/// before the cursor: no capital letter and no sentence-start suggestions at a block's start. Hooks `deleteBackward`
/// of the editor's text view class once; other text views of that class pass through (the handler answers `false`).
/// The Return key stays with the text view: hooking `insertText` too left the keyboard at a sentence start while typing.
@MainActor
enum TextInputHooks {
    static var onBackspaceAtStart: ((UITextView) -> Bool)?
    private static var hooked: Set<ObjectIdentifier> = []

    static func install(on view: UITextView) {
        guard let cls = object_getClass(view), hooked.insert(ObjectIdentifier(cls)).inserted else { return }
        let selector = #selector(UITextView.deleteBackward)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let block: @convention(block) (AnyObject) -> Void = { object in
            let handled = MainActor.assumeIsolated {
                guard let view = object as? UITextView, view.selectedRange == NSRange(location: 0, length: 0) else { return false }
                return onBackspaceAtStart?(view) ?? false
            }
            if !handled { original(object, selector) }
        }
        let implementation = imp_implementationWithBlock(block)
        // An inherited method gets an override on this class only, so other subclasses of its superclass stay as they are.
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}
