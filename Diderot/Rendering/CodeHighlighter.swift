import JavaScriptCore
import SwiftUI

/// Syntax colors for code blocks, as on the web: highlight.js through lowlight, with the grammars Docmost's client
/// registers, bundled into Diderot/Resources/Engine/highlight.js (Engine/src/highlight.ts). It runs in a JavaScript
/// context of its own, without a page, so the reader has colors too, where no engine is open. Code used to be one color.
actor CodeHighlighter {
    static let shared = CodeHighlighter()

    /// A stretch of code with a highlight.js scope ("keyword", "string" …): start and length in UTF-16 units.
    struct Stretch: Equatable, Sendable {
        let start: Int
        let length: Int
        let scope: String
    }

    private struct Key: Hashable {
        let code: String
        let language: String?
    }

    /// Longer code stays plain: a grammar runs over all of it, and without a language every grammar does, to guess it.
    private static let longest = 60_000, longestToGuess = 8_000
    private var function: JSValue?
    private var failed = false
    /// The last results, oldest first in `order`: a block's colors are asked again each time it comes back into view.
    private var cache: [Key: [Stretch]] = [:]
    private var order: [Key] = []

    /// The colored stretches of `code`, in `language` where highlight.js knows it and else in the language it guesses,
    /// as on the web; none for code without colors, for code too long, and when the script is missing.
    func stretches(of code: String, language: String?) -> [Stretch] {
        let language = language.flatMap { $0.isEmpty ? nil : $0 }
        let length = code.utf16.count
        guard length > 0, length <= (language == nil ? Self.longestToGuess : Self.longest) else { return [] }
        let key = Key(code: code, language: language)
        if let known = cache[key] { return known }
        guard let function = loaded(),
              let json = function.call(withArguments: [code, language ?? NSNull()])?.toString(),
              let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]]
        else { return [] }
        let stretches = rows.compactMap { row -> Stretch? in
            guard row.count == 3, let start = row[0] as? Int, let length = row[1] as? Int, let scope = row[2] as? String else { return nil }
            return Stretch(start: start, length: length, scope: scope)
        }
        // The oldest quarter goes when it is full: emptied whole, a long page colored every block anew on each scroll.
        if order.count >= 128 {
            for old in order.prefix(32) { cache[old] = nil }
            order.removeFirst(32)
        }
        cache[key] = stretches
        order.append(key)
        return stretches
    }

    /// The script's function, loaded on first use.
    private func loaded() -> JSValue? {
        if let function { return function }
        guard !failed else { return nil }
        guard let url = Bundle.main.url(forResource: "highlight", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext()
        else {
            failed = true
            return nil
        }
        // highlight.js reports a grammar's problems to the console, which a bare context doesn't have.
        context.evaluateScript("var console = { log() {}, info() {}, warn() {}, error() {}, debug() {} };")
        context.evaluateScript(script)
        guard let found = context.objectForKeyedSubscript("DiderotHighlight"), !found.isUndefined else {
            failed = true
            return nil
        }
        function = found
        return found
    }
}

/// The colors of highlight.js's scopes, grouped as Docmost's stylesheet has them (its code.css, with Mantine's colors),
/// for light and dark.
nonisolated enum CodeColors {
    static func color(for scope: String) -> Color? {
        switch scope {
        case "comment", "quote": dynamic(0x868E96, 0x828282)
        case "variable", "template-variable", "attribute", "tag", "name", "regexp", "link", "selector-id", "selector-class",
             "string", "symbol", "bullet": dynamic(0xF03E3E, 0xFF6B6B)
        case "number", "meta", "built_in", "builtin-name", "literal", "type", "params": dynamic(0x1C7ED6, 0x22B8CF)
        case "title", "section": dynamic(0xD6336C, 0xFCC419)
        case "keyword", "selector-tag": dynamic(0x7048E8, 0xB197FC)
        default: nil
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
}

nonisolated extension AttributedString {
    /// `code` with the colors of `stretches`, whose offsets count UTF-16 units of `code`.
    init(code: String, colored stretches: [CodeHighlighter.Stretch]) {
        self.init(code)
        let units = code.utf16
        for stretch in stretches {
            guard let color = CodeColors.color(for: stretch.scope), stretch.start >= 0, stretch.length > 0, stretch.start + stretch.length <= units.count,
                  let from = AttributedString.Index(units.index(units.startIndex, offsetBy: stretch.start), within: self),
                  let to = AttributedString.Index(units.index(units.startIndex, offsetBy: stretch.start + stretch.length), within: self), from < to
            else { continue }
            self[from..<to].foregroundColor = color
        }
    }
}

/// Code as text with its syntax colors, which come a moment after the plain text: `content` draws the text it is given.
struct HighlightedCode<Content: View>: View {
    let code: String
    let language: String?
    @ViewBuilder let content: (AttributedString) -> Content
    /// The colored text, and the code and language it is of.
    @State private var colored: (code: String, language: String?, text: AttributedString)?

    private struct Key: Hashable {
        let code: String
        let language: String?
    }

    var body: some View {
        content(colored.flatMap { $0.code == code && $0.language == language ? $0.text : nil } ?? AttributedString(code))
            .task(id: Key(code: code, language: language)) {
                let stretches = await CodeHighlighter.shared.stretches(of: code, language: language)
                guard !Task.isCancelled else { return }
                colored = (code, language, AttributedString(code: code, colored: stretches))
            }
    }
}
