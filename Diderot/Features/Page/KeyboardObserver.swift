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

/// What SwiftUI's `TextEditor` has no API for, hooked once on the page editor's text view class:
/// - Backspace at the start of the text, which `TextEditor` doesn't report (the text doesn't change). The editor used to
///   put an invisible character there for Backspace to delete, but iOS then saw a letter before the cursor: no capital
///   letter and no sentence-start suggestions at a block's start. Other text views of that class pass through (the
///   handler answers `false`). The Return key stays with the text view: hooking `insertText` too left the keyboard at a
///   sentence start while typing.
/// - Formats saving can't keep, refused (`refusedActions`), so the selection menu and the keyboard don't offer them.
/// - "Comment" in the selection menu (`commentsOnSelection`, `commentOnSelection`).
@MainActor
enum TextInputHooks {
    static var onBackspaceAtStart: ((UITextView) -> Bool)?
    /// Whether the text view's page offers "Comment" for its selected text: asked when the selection menu is built and
    /// again when the entry is tapped. Other text views of the class answer false.
    static var commentsOnSelection: ((UITextView) -> Bool)?
    /// Opens the comment sheet for the text view's selected text.
    static var commentOnSelection: ((UITextView) -> Void)?
    private static var hooked: Set<ObjectIdentifier> = []

    /// "Format › More…" opened the system's formatting panel, and ⌘+ and ⌘− step the font size: fonts, sizes, colors,
    /// line height and alignment, which the editor showed and saving dropped without a word (only bold, italic,
    /// underline and strikethrough map to Docmost's marks, `EditorText.normalized`). The panel's action has no public
    /// name; refusing it by name calls nothing private.
    static let refusedActions: Set<Selector> = [
        NSSelectorFromString("_showTextFormattingOptions:"),
        #selector(UIResponderStandardEditActions.increaseSize(_:)),
        #selector(UIResponderStandardEditActions.decreaseSize(_:)),
    ]

    static func install(on view: UITextView) {
        // The class the view says it has: while it is observed, `object_getClass` gives KVO's subclass, which goes,
        // with the hook, once the observation ends.
        let cls: AnyClass = view.classForCoder
        // A subclass of a hooked class has the hook: a second one would ask the handler twice.
        guard !sequence(first: cls, next: class_getSuperclass).contains(where: { hooked.contains(ObjectIdentifier($0)) }) else { return }
        hooked.insert(ObjectIdentifier(cls))
        hookDeleteBackward(of: cls)
        hookCanPerformAction(of: cls)
        hookBuildMenu(of: cls)
    }

    /// Adds "Comment" to the selection menu, before Cut, Copy and Paste (after them it lands on the menu's second page
    /// on narrow screens); only to a menu that has them, which other context menus of the text view don't. UIKit builds
    /// the menu along the responder chain, which ends at SwiftUI's app delegate, not the app's own: the entry it added
    /// there never showed. So it goes in here, at the first responder, and runs its action itself, as a command's
    /// selector would find no responder to answer it.
    private static func hookBuildMenu(of cls: AnyClass) {
        let selector = #selector(UIResponder.buildMenu(with:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, UIMenuBuilder) -> Void
        /// The class's own implementation, if it had one; an inherited one is looked up at each call.
        var own: Function?
        let block: @convention(block) (AnyObject, UIMenuBuilder) -> Void = { object, builder in
            if let own {
                own(object, selector, builder)
            } else if let superclass = class_getSuperclass(cls), let inherited = class_getMethodImplementation(superclass, selector) {
                unsafeBitCast(inherited, to: Function.self)(object, selector, builder)
            }
            MainActor.assumeIsolated {
                guard builder.system == .context, builder.menu(for: .standardEdit) != nil, let view = object as? UITextView,
                      commentsOnSelection?(view) == true
                else { return }
                // Asked again at the tap: the selection or the right to comment may have gone since the menu was built.
                let item = UIAction(title: String(localized: "Comment"), image: UIImage(systemName: "text.bubble")) { [weak view] _ in
                    guard let view, commentsOnSelection?(view) == true else { return }
                    commentOnSelection?(view)
                }
                builder.insertSibling(UIMenu(options: .displayInline, children: [item]), beforeMenu: .standardEdit)
            }
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            own = unsafeBitCast(method_setImplementation(method, implementation), to: Function.self)
        }
    }

    private static func hookCanPerformAction(of cls: AnyClass) {
        let selector = #selector(UIResponder.canPerformAction(_:withSender:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
        /// The class's own implementation, if it had one; an inherited one is looked up at each call.
        var own: Function?
        let block: @convention(block) (AnyObject, Selector, Any?) -> Bool = { object, action, sender in
            if MainActor.assumeIsolated({ refusedActions.contains(action) }) { return false }
            if let own { return own(object, selector, action, sender) }
            guard let superclass = class_getSuperclass(cls), let inherited = class_getMethodImplementation(superclass, selector) else { return false }
            return unsafeBitCast(inherited, to: Function.self)(object, selector, action, sender)
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            own = unsafeBitCast(method_setImplementation(method, implementation), to: Function.self)
        }
    }

    private static func hookDeleteBackward(of cls: AnyClass) {
        let selector = #selector(UITextView.deleteBackward)
        guard let method = class_getInstanceMethod(cls, selector) else {
            AppLog.ui.fault("\(NSStringFromClass(cls), privacy: .public) has no deleteBackward: Backspace at a block's start won't join it")
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        /// The class's own implementation, if it had one; an inherited one is looked up at each call.
        var own: Function?
        let block: @convention(block) (AnyObject) -> Void = { object in
            let handled = MainActor.assumeIsolated {
                guard let view = object as? UITextView, view.selectedRange == NSRange(location: 0, length: 0) else { return false }
                return onBackspaceAtStart?(view) ?? false
            }
            guard !handled else { return }
            if let own {
                own(object, selector)
            } else if let superclass = class_getSuperclass(cls), let inherited = class_getMethodImplementation(superclass, selector) {
                // As the superclass has it now, so a change made there later (another hook) still runs.
                unsafeBitCast(inherited, to: Function.self)(object, selector)
            }
        }
        let implementation = imp_implementationWithBlock(block)
        // An inherited method gets an override on this class only, so other subclasses of its superclass stay as they are.
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            own = unsafeBitCast(method_setImplementation(method, implementation), to: Function.self)
        }
    }
}
