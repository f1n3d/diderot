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

    /// The formatting panel and the font size steps are refused, so the selection menu and the keyboard don't offer
    /// them; the class's own answer stays behind the hook for every other action.
    @Test func formatsSavingCantKeepAreRefused() {
        let view = Self.view(OwnActionsTextView.self, cursorAt: 0)
        TextInputHooks.install(on: view)

        for action in TextInputHooks.refusedActions {
            #expect(!view.canPerformAction(action, withSender: nil), "\(NSStringFromSelector(action)) is offered")
        }
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.toggleBoldface(_:)), withSender: nil))
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        #expect(TextInputHooks.refusedActions.contains(NSSelectorFromString("_showTextFormattingOptions:")))
    }

    /// "Comment" goes into the text view's selection menu, before Cut, Copy and Paste, when its page offers it: not
    /// without the offer, not in a context menu without those entries, not in the menu bar. A class's own `buildMenu`
    /// stays behind the hook.
    @Test func commentGoesIntoTheSelectionMenu() {
        let view = Self.view(OwnMenuTextView.self, cursorAt: 0)
        TextInputHooks.install(on: view)
        var offers = true
        TextInputHooks.commentsOnSelection = { $0 === view && offers }
        defer { TextInputHooks.commentsOnSelection = nil }

        let menu = MenuBuilderStub(system: .context, menus: [.standardEdit])
        view.buildMenu(with: menu)
        #expect(view.ownMenuCalls == 1)
        #expect(menu.insertedBeforeStandardEdit.flatMap(\.children).map(\.title) == [String(localized: "Comment")])

        offers = false
        let withoutOffer = MenuBuilderStub(system: .context, menus: [.standardEdit])
        view.buildMenu(with: withoutOffer)
        #expect(withoutOffer.insertedBeforeStandardEdit.isEmpty)

        offers = true
        let otherContextMenu = MenuBuilderStub(system: .context, menus: [])
        view.buildMenu(with: otherContextMenu)
        let menuBar = MenuBuilderStub(system: .main, menus: [.standardEdit])
        view.buildMenu(with: menuBar)
        #expect(otherContextMenu.insertedBeforeStandardEdit.isEmpty && menuBar.insertedBeforeStandardEdit.isEmpty)
        #expect(view.ownMenuCalls == 4)
    }

    /// The editor's key commands come with the text view's own; only a text view that takes them performs them, others
    /// keep Tab and Return as they are.
    @Test func keyCommandsGoToTheEditorOnly() {
        let editor = Self.view(KeyTextView.self, cursorAt: 0)
        let other = Self.view(KeyTextView.self, cursorAt: 0)
        TextInputHooks.install(on: editor)
        TextInputHooks.takesKeys = { $0 === editor }
        defer { TextInputHooks.takesKeys = nil }

        let commands = editor.keyCommands ?? []
        #expect(TextInputHooks.keyCommands.allSatisfy { ours in commands.contains { $0 === ours } })
        #expect(editor.canPerformAction(TextInputHooks.keySelector, withSender: nil))
        #expect(!other.canPerformAction(TextInputHooks.keySelector, withSender: nil))
        #expect(editor.responds(to: TextInputHooks.keySelector))
    }

    /// Without an own answer, the text view answers as it would without the hook (the inherited implementation).
    @Test func otherActionsAnswerAsWithoutTheHook() {
        let plain = Self.view(UITextView.self, cursorAt: 0)
        let view = Self.view(InheritingActionsTextView.self, cursorAt: 0)
        TextInputHooks.install(on: view)
        let actions = [#selector(UIResponderStandardEditActions.toggleBoldface(_:)), #selector(UIResponderStandardEditActions.copy(_:)),
                       #selector(UIResponderStandardEditActions.selectAll(_:)), #selector(UIResponderStandardEditActions.paste(_:))]
        for action in actions {
            #expect(view.canPerformAction(action, withSender: nil) == plain.canPerformAction(action, withSender: nil),
                    "\(NSStringFromSelector(action)) answers differently")
        }
    }
}

private class StartTextView: UITextView {}
private class InheritingTextView: UITextView {}
private class ParentTextView: UITextView {}
private class ChildTextView: ParentTextView {}
private class ObservedTextView: UITextView {}
private class LateParentTextView: UITextView {}
private class LateChildTextView: LateParentTextView {}
private class InheritingActionsTextView: UITextView {}
private class KeyTextView: UITextView {}

/// Counts its own `buildMenu`, which the hook keeps.
private class OwnMenuTextView: UITextView {
    var ownMenuCalls = 0

    override func buildMenu(with builder: any UIMenuBuilder) {
        ownMenuCalls += 1
        super.buildMenu(with: builder)
    }
}

/// A menu being built: which menus it has, and what goes before Cut, Copy and Paste.
@MainActor
private final class MenuBuilderStub: NSObject, UIMenuBuilder {
    let system: UIMenuSystem
    private let menus: Set<UIMenu.Identifier>
    private(set) var insertedBeforeStandardEdit: [UIMenu] = []

    init(system: UIMenuSystem, menus: Set<UIMenu.Identifier>) {
        self.system = system
        self.menus = menus
    }

    func menu(for identifier: UIMenu.Identifier) -> UIMenu? { menus.contains(identifier) ? UIMenu(identifier: identifier, children: []) : nil }
    func insertSibling(_ siblingMenu: UIMenu, beforeMenu siblingIdentifier: UIMenu.Identifier) {
        if siblingIdentifier == .standardEdit { insertedBeforeStandardEdit.append(siblingMenu) }
    }

    // The rest of the protocol, unused by the hook.
    func action(for identifier: UIAction.Identifier) -> UIAction? { nil }
    func __command(forAction action: Selector, propertyList: Any?) -> UICommand? { nil }
    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementMenu: UIMenu) {}
    func replaceChildren(ofMenu parentIdentifier: UIMenu.Identifier, from childrenBlock: ([UIMenuElement]) -> [UIMenuElement]) {}
    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementElements: [UIMenuElement]) {}
    func replace(action replacedIdentifier: UIAction.Identifier, with replacementElements: [UIMenuElement]) {}
    func __replaceCommand(forAction replacedAction: Selector, propertyList replacedPropertyList: Any?, with replacementElements: [UIMenuElement]) {}
    func insertElements(_ insertedElements: [UIMenuElement], beforeMenu siblingIdentifier: UIMenu.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], afterMenu siblingIdentifier: UIMenu.Identifier) {}
    func insertSibling(_ siblingMenu: UIMenu, afterMenu siblingIdentifier: UIMenu.Identifier) {}
    func insertChild(_ childMenu: UIMenu, atStartOfMenu parentIdentifier: UIMenu.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], beforeAction siblingIdentifier: UIAction.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], afterAction siblingIdentifier: UIAction.Identifier) {}
    func __insert(_ insertedElements: [UIMenuElement], beforeCommandForAction siblingAction: Selector, propertyList siblingPropertyList: Any?) {}
    func __insert(_ insertedElements: [UIMenuElement], afterCommandForAction siblingAction: Selector, propertyList siblingPropertyList: Any?) {}
    func insertElements(_ childElements: [UIMenuElement], atStartOfMenu parentIdentifier: UIMenu.Identifier) {}
    func insertChild(_ childMenu: UIMenu, atEndOfMenu parentIdentifier: UIMenu.Identifier) {}
    func insertElements(_ childElements: [UIMenuElement], atEndOfMenu parentIdentifier: UIMenu.Identifier) {}
    func remove(menu removedIdentifier: UIMenu.Identifier) {}
    func remove(action removedIdentifier: UIAction.Identifier) {}
    func __removeCommand(forAction removedAction: Selector, propertyList removedPropertyList: Any?) {}
}

/// Offers every action: what the hook refuses shows against it.
private class OwnActionsTextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { true }
}

private class OwnBackspaceTextView: UITextView {
    var ownCalls = 0

    override func deleteBackward() {
        ownCalls += 1
        super.deleteBackward()
    }
}
