import SwiftUI
import UIKit

/// Invisible text field that opens the emoji keyboard and reports the picked emoji (Backspace: `nil` = remove).
struct EmojiPickerField: UIViewRepresentable {
    @Binding var isPresented: Bool
    /// For UI tests: tells the page-icon field apart from the emoji-in-text field.
    var identifier = "emoji-field"
    let onPick: (String?) -> Void

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.delegate = context.coordinator
        field.onDeleteBackward = { context.coordinator.parent.onPick(nil) }
        field.alpha = 0.02
        field.autocorrectionType = .no
        field.tintColor = .clear
        field.accessibilityIdentifier = identifier
        field.isAccessibilityElement = true
        return field
    }

    func updateUIView(_ field: EmojiTextField, context: Context) {
        context.coordinator.parent = self
        if isPresented, !field.isFirstResponder {
            // Next run loop, if still wanted then: a late call after the pick would take focus from the editor again.
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak field] in
                guard let field, coordinator.parent.isPresented, !field.isFirstResponder else { return }
                field.becomeFirstResponder()
            }
        } else if !isPresented, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Drawn as a picture: starts with an emoji and has a scalar with emoji presentation (😀, 👍🏽) or the emoji
    /// selector U+FE0F (❤️, 1️⃣). "#", "©" and digits are emoji characters too, but drawn as text.
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        return scalars.first?.properties.isEmoji == true && scalars.contains { $0.properties.isEmojiPresentation || $0 == "\u{FE0F}" }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiPickerField

        init(parent: EmojiPickerField) {
            self.parent = parent
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let emoji = string.first, EmojiPickerField.isEmoji(emoji) {
                parent.onPick(String(emoji))
                textField.text = ""
                textField.resignFirstResponder()
            }
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isPresented = false
        }
    }
}

final class EmojiTextField: UITextField {
    var onDeleteBackward: (() -> Void)?

    override var textInputContextIdentifier: String? { "docmost.emoji" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }

    override func deleteBackward() {
        onDeleteBackward?()
        resignFirstResponder()
    }
}
