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
/// - The web editor's keys (`EditorKeyAction`) as key commands, ahead of the text view's own Tab and Return.
/// - Undo and redo through the engine's history (`EditorUndoManager`, `onUndo`).
@MainActor
enum TextInputHooks {
    static var onBackspaceAtStart: ((UITextView) -> Bool)?
    /// Whether the text view takes the key (`onKey`) now: the page's editor does, ↑ and ↓ only at a block's first or last
    /// line (nil: asked for no particular key). Other text views of the class keep Tab, Return and the arrows as they are.
    static var takesKey: ((UITextView, EditorKeyAction?) -> Bool)?
    static var onKey: ((UITextView, EditorKeyAction) -> Void)?
    /// Undo (false) or redo (true) from the system, for the text view that takes the editor's keys (`takesKey`).
    static var onUndo: ((UITextView, Bool) -> Void)?
    private static var undoManagerKey: UInt8 = 0
    /// What the key commands call, added to the text view's class: no responder in the chain would answer it.
    static let keySelector = NSSelectorFromString("docmostEditorKey:")
    /// `wantsPriorityOverSystemBehavior`: Tab, Shift-Tab and Shift-Return go to the editor, not to the text view's
    /// typing or the focus system. A hook on the presses doesn't see them: the text view's keyboard input takes them
    /// before.
    static let keyCommands: [UIKeyCommand] = EditorKeyAction.shortcuts.map { shortcut in
        let command = UIKeyCommand(input: shortcut.input, modifierFlags: shortcut.modifiers, action: keySelector)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
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
        hookKeyCommands(of: cls)
        hookUndoManager(of: cls)
    }

    /// While a block is edited, the text view's undo manager is the editor's (`EditorUndoManager`): ⌘Z, ⌘⇧Z, shaking,
    /// the three-finger swipes and the edit menu's Undo go through the engine's history. Otherwise the text view's own.
    private static func hookUndoManager(of cls: AnyClass) {
        let selector = #selector(getter: UIResponder.undoManager)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> UndoManager?
        /// The class's own implementation, if it had one; an inherited one is looked up at each call.
        var own: Function?
        let block: @convention(block) (AnyObject) -> UndoManager? = { object in
            var manager: UndoManager?
            MainActor.assumeIsolated {
                if let view = object as? UITextView, takesKey?(view, nil) == true {
                    manager = editorUndoManager(of: view)
                } else if let own {
                    manager = own(object, selector)
                } else if let superclass = class_getSuperclass(cls), let implementation = class_getMethodImplementation(superclass, selector) {
                    manager = unsafeBitCast(implementation, to: Function.self)(object, selector)
                }
            }
            return manager
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            own = unsafeBitCast(method_setImplementation(method, implementation), to: Function.self)
        }
    }

    /// The text view's editor undo manager, made once and kept by the text view: an undo goes to the text view it was
    /// asked from.
    static func editorUndoManager(of view: UITextView) -> EditorUndoManager {
        if let manager = objc_getAssociatedObject(view, &undoManagerKey) as? EditorUndoManager { return manager }
        let manager = EditorUndoManager(view: view) { view, redo in onUndo?(view, redo) }
        objc_setAssociatedObject(view, &undoManagerKey, manager, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return manager
    }

    /// The editor's key commands next to the text view's own, and the method they call. Only the page's editor performs
    /// them (`canPerformAction`, `takesKey`); in other text views of the class the keys go on as without them.
    private static func hookKeyCommands(of cls: AnyClass) {
        let action: @convention(block) (AnyObject, UIKeyCommand) -> Void = { object, command in
            MainActor.assumeIsolated {
                guard let view = object as? UITextView, let input = command.input,
                      let key = EditorKeyAction(input: input, modifiers: command.modifierFlags) else { return }
                onKey?(view, key)
            }
        }
        class_addMethod(cls, keySelector, imp_implementationWithBlock(action), "v@:@")

        let selector = #selector(getter: UIResponder.keyCommands)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> NSArray?
        /// The class's own implementation, if it had one; an inherited one is looked up at each call.
        var own: Function?
        let block: @convention(block) (AnyObject) -> NSArray? = { object in
            var commands: NSArray?
            MainActor.assumeIsolated {
                var inherited: NSArray?
                if let own {
                    inherited = own(object, selector)
                } else if let superclass = class_getSuperclass(cls), let implementation = class_getMethodImplementation(superclass, selector) {
                    inherited = unsafeBitCast(implementation, to: Function.self)(object, selector)
                }
                commands = ((inherited as? [UIKeyCommand] ?? []) + keyCommands) as NSArray
            }
            return commands
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            own = unsafeBitCast(method_setImplementation(method, implementation), to: Function.self)
        }
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
            if MainActor.assumeIsolated({ action == keySelector }) {
                return MainActor.assumeIsolated {
                    guard let view = object as? UITextView else { return false }
                    let key = (sender as? UIKeyCommand).flatMap { command in
                        command.input.flatMap { EditorKeyAction(input: $0, modifiers: command.modifierFlags) }
                    }
                    return takesKey?(view, key) == true
                }
            }
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

/// The page editor's undo, for ⌘Z, ⌘⇧Z, shaking and the three-finger swipes: the engine's Yjs history, as the toolbar's
/// Undo and Redo and the web editor have it. The text view's own knew only what was typed in the active block since it
/// became active: Return's split, a conversion or typing in another block stayed. It takes no registrations, so the
/// text view's typing builds no second history. Undo is always offered: the engine says when there is nothing to undo.
@MainActor
final class EditorUndoManager: UndoManager {
    /// Weak: the text view keeps its manager.
    private weak var view: UITextView?
    private let step: (UITextView, Bool) -> Void

    init(view: UITextView, step: @escaping (UITextView, Bool) -> Void) {
        self.view = view
        self.step = step
        super.init()
        super.disableUndoRegistration()
    }

    override var canUndo: Bool { true }
    override var canRedo: Bool { true }
    override var undoActionName: String { "" }
    override var redoActionName: String { "" }

    /// Registration stays off for good: the text view's disable and enable pairs, or an enable without its disable,
    /// leave it so.
    override func disableUndoRegistration() {}
    override func enableUndoRegistration() {}

    override func undo() {
        if let view { step(view, false) }
    }

    override func redo() {
        if let view { step(view, true) }
    }
}
