import Testing
@testable import Diderot

/// Only emoji become a page icon: "#" or "©" from a hardware keyboard are text; emoji-keyboard keycaps count.
struct EmojiPickerFieldTests {
    @Test func acceptsOnlyCharactersDrawnAsEmoji() {
        for text: Character in ["#", "©", "1"] {
            #expect(!EmojiPickerField.isEmoji(text))
        }
        for emoji: Character in ["1️⃣", "❤️", "😀"] {
            #expect(EmojiPickerField.isEmoji(emoji))
        }
    }
}
