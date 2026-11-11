import Foundation
import SwiftUI
import Testing
@testable import Diderot

/// Code blocks get the web's syntax colors from the bundled highlight.js (Engine/tools/highlight-check.ts checks the
/// grammars' stretches; here, that the app's script loads and its offsets land on the right characters).
struct CodeHighlighterTests {
    @Test func aLanguagesStretchesComeFromTheBundledScript() async {
        let stretches = await CodeHighlighter.shared.stretches(of: "let x = 1", language: "swift")
        #expect(stretches.contains(CodeHighlighter.Stretch(start: 0, length: 3, scope: "keyword")))
        #expect(stretches.contains(CodeHighlighter.Stretch(start: 8, length: 1, scope: "number")))
        #expect(await CodeHighlighter.shared.stretches(of: "let x = 1", language: "plaintext").isEmpty)
        #expect(await CodeHighlighter.shared.stretches(of: "", language: "swift").isEmpty)
        // Without a language it is guessed, as on the web.
        let guessed = await CodeHighlighter.shared.stretches(of: "def f(x):\n    return x + 1\n\nprint(f(2))", language: nil)
        #expect(guessed.contains { $0.scope == "keyword" })
    }

    /// The script counts UTF-16 units: after an emoji, a stretch still colors its own characters.
    @Test func stretchesColorTheirCharacters() {
        let code = "// 🙂\nlet x = 1"
        let text = AttributedString(code: code, colored: [
            .init(start: 0, length: 5, scope: "comment"), .init(start: 6, length: 3, scope: "keyword"), .init(start: 14, length: 1, scope: "number"),
            .init(start: 10, length: 1, scope: "no-such-scope"), .init(start: 14, length: 9, scope: "keyword"),
        ])
        let colored = text.runs.filter { $0.foregroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(colored == ["// 🙂", "let", "1"])
        #expect(String(text.characters) == code)
    }
}
