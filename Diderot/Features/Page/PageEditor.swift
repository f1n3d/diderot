import SwiftUI
import DocmostKit

/// The page's one text editor, lying on the active block's text (paragraph, heading, toggle title, code; the block keeps
/// its place with a hidden copy). It stays the same view while the active block changes, so focus, the keyboard and its
/// state stay and the caret moves at once; one editor per block made iOS hand focus over at every Return.
struct PageEditor: View {
    let model: DocumentModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// With VoiceOver the text is edited in its block instead (`TextNodeView`): VoiceOver reads the page in order,
    /// and this editor lies outside it, so it came before the page's heading. On Return the keyboard then briefly
    /// hides, as focus moves to the next block's editor.
    static func editsInBlock(voiceOver: Bool) -> Bool {
        #if DEBUG
        voiceOver || DebugLaunch.editsInBlock
        #else
        voiceOver
        #endif
    }

    var body: some View {
        if !Self.editsInBlock(voiceOver: voiceOver), let active = model.active, let place = model.editorFrame {
            ActiveTextEditor(model: model, ref: active.ref, font: model.editorStyle.font, isCode: model.editorStyle.isCode)
                // Its own height, not the row's: beside a checkbox it took the checkbox's.
                .fixedSize(horizontal: false, vertical: true)
                // The text view puts the font's leading below every line, the reader only between lines: without the
                // last one the editor is as tall as the reader's text, so the blocks below don't move.
                .padding(.bottom, -model.editorStyle.leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if place.ref == active.ref { model.editorHeight = (active.ref, height) }
                }
                .multilineTextAlignment(model.editorStyle.alignment)
                .frame(width: place.frame.width, alignment: .topLeading)
                // Until the new block reports its place, the editor would show the new text at the old one.
                .opacity(place.ref == active.ref ? 1 : 0)
                .offset(x: place.frame.minX, y: place.frame.minY)
        }
    }
}

/// The text editor in `PageEditor`.
struct ActiveTextEditor: View {
    @Bindable var model: DocumentModel
    let ref: NodeRef
    let font: Font
    var isCode = false

    private var isActive: Bool { model.active?.ref == ref }

    var body: some View {
        TextEditor(text: text, selection: selection)
            .font(font)
            .autocorrectionDisabled(isCode)
            .textInputAutocapitalization(isCode ? .never : .sentences)
            // No caret until `applyCursor` places it: focus comes first, and the caret would show at the end and jump.
            .tint(isActive && model.cursorRequest != nil ? Color.clear : Color.accentColor)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            // Cancels the text area's 8 pt vertical and 5 pt horizontal insets: the text stays where it sat before
            // the tap and the block or table row doesn't grow.
            .padding(.vertical, -8)
            .padding(.horizontal, -5)
            .accessibilityIdentifier(isActive ? "active-editor" : "idle-editor")
            .accessibilityHidden(!isActive)
            .modifier(EditorFocus(model: model, ref: ref, onFocus: {
                // Pasting a copied synced block embeds it instead of inserting its markup as text.
                let model = model
                EditorPasteProxy.install { reference in
                    model.pasteSyncedReferenceIntoActive(reference)
                } onLink: { link in
                    model.pasteLink(link)
                }
                if let view = FirstResponder.current as? UITextView {
                    model.editorTextView = view
                    TextInputHooks.install(on: view)
                    TextInputHooks.onBackspaceAtStart = { [weak model] view in
                        guard let model, view === model.editorTextView else { return false }
                        return model.backspaceAtStart()
                    }
                }
            }))
            .onAppear { if isActive { applyCursor() } }
            .onChange(of: model.cursorRequest) { _, _ in if isActive { applyCursor() } }
            .onChange(of: model.activeText) { _, _ in
                guard isActive else { return }
                // Each answers only for its kind of block.
                model.activeTextChanged()
                model.activeCodeChanged()
            }
            .onChange(of: model.activeSelection) { _, _ in if isActive { model.activeSelectionChanged() } }
            .onChange(of: isCode) { _, _ in
                // The keyboard takes changed traits (autocorrection, capitalization) only after a reload.
                DispatchQueue.main.async { FirstResponder.current?.reloadInputViews() }
            }
    }

    private var text: Binding<AttributedString> {
        isActive ? $model.activeText : .constant(AttributedString())
    }

    private var selection: Binding<AttributedTextSelection> {
        isActive ? $model.activeSelection : .constant(AttributedTextSelection())
    }

    private func applyCursor() {
        guard let request = model.cursorRequest else { return }
        Task { @MainActor in
            // After this update: the editor has focus already but shows the new block's text only then.
            try? await Task.sleep(for: .zero)
            guard model.cursorRequest == request else { return }
            var resolved = request
            if case .point(let point) = request {
                resolved = await Self.offset(at: point, in: String(model.activeText.characters)).map { .offset($0) } ?? .end
                guard model.cursorRequest == request else { return }
            }
            let text = model.activeText
            let characters = text.characters
            let index: AttributedString.Index
            switch resolved {
            case .start:
                index = text.startIndex
            case .end, .point:
                index = text.endIndex
            case .offset(let offset):
                index = characters.index(text.startIndex, offsetBy: min(offset, characters.count))
            }
            model.activeSelection = AttributedTextSelection(insertionPoint: index)
            model.cursorRequest = nil
        }
    }

    /// Character offset under `point` (relative to the text's top left), by the focused text view's own layout once
    /// it shows `text`; `nil` if it doesn't within half a second (focus still on the previous block's editor).
    private static func offset(at point: CGPoint, in text: String) async -> Int? {
        for _ in 0..<5 {
            if let view = FirstResponder.current as? UITextView, view.text == text {
                view.layoutIfNeeded()
                // The editor's negative padding cancels these insets, so its text lies where the reader's was.
                let inset = view.textContainerInset, padding = view.textContainer.lineFragmentPadding
                guard let position = view.closestPosition(to: CGPoint(x: point.x + inset.left + padding, y: point.y + inset.top))
                else { return nil }
                let utf16 = view.offset(from: view.beginningOfDocument, to: position)
                return text.distance(from: text.startIndex, to: text.utf16.index(text.startIndex, offsetBy: min(max(utf16, 0), text.utf16.count)))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

/// Text and code editor focus: taken once the editor is in the window, reported to the model, retaken after a sheet.
private struct EditorFocus: ViewModifier {
    let model: DocumentModel
    let ref: NodeRef
    var onFocus: () -> Void = {}
    @FocusState private var focused: Bool
    /// Per-instance id: an editor SwiftUI rebuilds gets a new one.
    @State private var instance = UUID()

    private var isActive: Bool { model.active?.ref == ref }

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .background {
                FocusWhenInWindow { if isActive, !model.editsInSheet { focused = true } }
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused { onFocus() }
                model.editorFocusChanged(isFocused, instance: instance, ref: ref)
            }
            .onChange(of: model.editsInSheet) { _, editing in
                // After the link, comment or insert sheet (or emoji keyboard), editing continues in the same block.
                guard !editing, isActive else { return }
                focused = true
                // While the sheet is still dismissing, UIKit on device sometimes rejects focus: retry.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    if isActive, !model.editsInSheet, !focused { focused = true }
                }
            }
    }
}
