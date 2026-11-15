import SwiftUI
import DocmostKit

/// Formats in the block editor. While typing, `TextEditor` drops attributes it doesn't know (custom Docmost ones, the
/// code intent) and doesn't render them even on existing text. So underline, strikethrough, code, highlight and text
/// color also get SwiftUI attributes, which survive typing and render; saving converts them back.
nonisolated enum EditorText {
    /// As in the reader (`InlineTextBuilder.monospacedFont`): a larger one made inline code jump on activation.
    static let codeFont = Font.system(.callout, design: .monospaced)
    static let codeBackground = Color(.secondarySystemFill)

    static func highlightColor(_ value: String) -> Color {
        value.hasPrefix("#") ? HighlightPalette.color(name: nil, hex: value) : HighlightPalette.color(name: value, hex: nil)
    }

    /// The web's text colors (`TextColors`) as the editor shows them, made once: the toolbar asks for each run.
    static let textColors: [(name: String, hex: String, color: Color)] = TextColors.named.compactMap { name, hex in
        Color(hex: hex).map { (name, hex, $0) }
    }

    /// The web's color names (`color-selector.tsx`, also the table's cell colors); "Default" for none.
    static func colorTitle(_ name: String?) -> LocalizedStringResource {
        switch name?.lowercased() {
        case "blue": "Blue"
        case "green": "Green"
        case "purple": "Purple"
        case "red": "Red"
        case "yellow": "Yellow"
        case "orange": "Orange"
        case "pink": "Pink"
        case "gray": "Gray"
        case "brown": "Brown"
        default: "Default"
        }
    }

    /// On opening a block for editing: adds the visible SwiftUI attributes next to the Docmost ones.
    static func display(_ text: AttributedString) -> AttributedString {
        var result = text
        for run in text.runs {
            let intents = run.inlinePresentationIntent ?? []
            var container = AttributeContainer()
            if intents.contains(.strikethrough) { container.strikethroughStyle = .single }
            if run.docmost.underline == true { container.underlineStyle = .single }
            if intents.contains(.code) {
                container.font = codeFont
                container.backgroundColor = codeBackground
            }
            if let highlight = run.docmost.highlight { container.backgroundColor = highlightColor(highlight) }
            if let color = run.docmost.textColor.flatMap(Color.init(hex:)) { container.foregroundColor = color }
            if run.docmost.inlineNode != nil { container.foregroundColor = .accentColor }
            result[run.range].mergeAttributes(container)
        }
        return result
    }

    /// Before saving: typed text carries only SwiftUI attributes; converts them back to intents and Docmost attributes.
    /// Underline and strikethrough follow the visible attribute both ways: system formatting (Cmd-U, format panel)
    /// changes only that one. Its bold and italic (Cmd-B, Cmd-I) set only the font (on inline code also dropping the
    /// code intent), so the font decides. `base`: the font the block's editor draws with.
    static func normalized(_ text: AttributedString, base: Font = .body) -> AttributedString {
        var result = text
        // Text typed next to a colored word shows its color but has lost the hex: the colors the text holds, then the
        // web's. A color outside the palette (set on the web from elsewhere) stays with what is typed next to it, and
        // keeps its spelling, so the word stays one piece.
        var shownColors: [(hex: String, color: Color)] = []
        for (hex, _) in text.runs[\.textColor] {
            if let hex, !shownColors.contains(where: { $0.hex == hex }), let color = Color(hex: hex) { shownColors.append((hex, color)) }
        }
        shownColors += textColors.map { ($0.hex, $0.color) }
        for run in text.runs {
            let range = run.range
            var intents = (run.inlinePresentationIntent ?? []).union(fontIntents(run.font, base: base))
            if run.strikethroughStyle != nil { intents.insert(.strikethrough) } else { intents.remove(.strikethrough) }
            result[range].inlinePresentationIntent = intents.isEmpty ? nil : intents
            result[range].docmost.underline = run.underlineStyle != nil ? true : nil
            if run.docmost.highlight == nil, let background = run.backgroundColor, background != codeBackground,
               let name = HighlightColors.names.first(where: { HighlightPalette.color(name: $0, hex: nil) == background })
            {
                result[range].docmost.highlight = name
            }
            // A mention's or status's accent color isn't a text color, nor is code's: its mark excludes all others.
            if run.docmost.textColor == nil, run.docmost.inlineNode == nil, !intents.contains(.code), let shown = run.foregroundColor,
               let hex = shownColors.first(where: { $0.color == shown })?.hex
            {
                result[range].docmost.textColor = hex
            }
        }
        return result
    }

    /// Code, bold and italic that system formatting set as the font. `base`: the font the block's editor draws with.
    static func fontIntents(_ font: Font?, base: Font) -> InlinePresentationIntent {
        guard let font else { return [] }
        let context = EnvironmentValues().fontResolutionContext
        var largeType = EnvironmentValues()
        largeType.dynamicTypeSize = .accessibility1
        // Only the editor's text styles scale; fixed-size pasted fonts stay unsaved (with Bold Text even regular
        // pasted text resolves bold).
        let resolved = font.resolve(in: context)
        guard resolved.pointSize != font.resolve(in: largeType.fontResolutionContext).pointSize else { return [] }
        var intents: InlinePresentationIntent = []
        if resolved.isMonospaced { intents.insert(.code) }
        // System formatting derives a run's font from the block font, bold itself in headings (and, with Bold Text, in
        // the toggle title): only another bold weight is visible, so only that counts.
        if resolved.isBold, resolved.weight != base.resolve(in: context).weight { intents.insert(.stronglyEmphasized) }
        if resolved.isItalic { intents.insert(.emphasized) }
        return intents
    }

    /// Toolbar: bold or italic on/off. System bold and italic (Cmd-B, Cmd-I) are in the font: they move to the intents
    /// first, so the button sees and removes them too.
    static func setIntent(_ intent: InlinePresentationIntent, _ on: Bool, in attributes: inout AttributeContainer, base: Font) {
        var intents = attributes.inlinePresentationIntent ?? []
        let fromFont = fontIntents(attributes.font, base: base)
        if !fromFont.isDisjoint(with: [.stronglyEmphasized, .emphasized]) {
            intents.formUnion(fromFont)
            attributes.font = fromFont.contains(.code) ? codeFont : nil
        }
        if on { intents.insert(intent) } else { intents.remove(intent) }
        attributes.inlinePresentationIntent = intents.isEmpty ? nil : intents
    }

    /// Whether the selected text all passes `check`. An inline node (mention, status, formula) counts only where it has
    /// the format itself, as on the web: "Select All" on a bold paragraph reads as bold, and so does a mention (or part
    /// of one) made bold.
    static func allFormatted(_ text: AttributedString, in ranges: RangeSet<AttributedString.Index>,
                             _ check: (AttributeContainer) -> Bool) -> Bool {
        let runs = text[ranges].runs.filter { run in
            !text[run.range].characters.isEmpty && (run.docmost.inlineNode == nil || check(run.attributes))
        }
        return !runs.isEmpty && runs.allSatisfy { check($0.attributes) }
    }

    /// Toolbar formats (typing attributes at a bare cursor). `body` changes each selected run on its own so links,
    /// mentions and other formats stay, as on the web (`transformAttributes(in:)` spreads the first run's attributes).
    static func transformRuns(
        of text: inout AttributedString, in selection: inout AttributedTextSelection, _ body: (inout AttributeContainer) -> Void
    ) {
        guard case .ranges(let ranges) = selection.indices(in: text) else {
            text.transformAttributes(in: &selection, body: body)
            return
        }
        let changes = text[ranges].runs.map { run in
            var attributes = run.attributes
            body(&attributes)
            return (run.range, attributes)
        }
        // Even an attribute change invalidates the selection's indices (it would collapse to the end) unless tracked.
        text.transform(updating: &selection) { text in
            for (range, attributes) in changes { text[range].setAttributes(attributes) }
        }
    }

    /// Toolbar: inline code on/off. Code and highlight share the background (highlight wins in `display`): code
    /// replaces a highlight, as on the web (its mark excludes all others); code off leaves a highlight visible.
    static func setCode(_ on: Bool, in attributes: inout AttributeContainer) {
        var intents = attributes.inlinePresentationIntent ?? []
        if on { intents.insert(.code) } else { intents.remove(.code) }
        attributes.inlinePresentationIntent = intents.isEmpty ? nil : intents
        attributes.font = on ? codeFont : nil
        if on {
            attributes.docmost.highlight = nil
            attributes.backgroundColor = codeBackground
            attributes.docmost.textColor = nil
            if attributes.docmost.inlineNode == nil { attributes.foregroundColor = nil }
        } else if attributes.backgroundColor == codeBackground {
            attributes.backgroundColor = nil
        }
    }

    /// Toolbar: highlight on/off; turning it off on code restores the code background.
    static func setHighlight(_ on: Bool, in attributes: inout AttributeContainer) {
        setHighlight(named: on ? "yellow" : nil, in: &attributes)
    }

    /// Toolbar: a highlight in one of the web's colors (`HighlightColors`), or none.
    static func setHighlight(named name: String?, in attributes: inout AttributeContainer) {
        let isCode = attributes.inlinePresentationIntent?.contains(.code) == true || attributes.font == codeFont
        attributes.docmost.highlight = name
        attributes.backgroundColor = name.map(highlightColor) ?? (isCode ? codeBackground : nil)
    }

    /// Toolbar: a text color of the web's (`TextColors`, as hex), or none (the web's "Default"). Not on inline code,
    /// whose mark excludes all others, as the web leaves it; a mention or status keeps showing its accent color.
    static func setTextColor(_ hex: String?, in attributes: inout AttributeContainer) {
        guard attributes.inlinePresentationIntent?.contains(.code) != true, attributes.font != codeFont else { return }
        attributes.docmost.textColor = hex
        if attributes.docmost.inlineNode == nil { attributes.foregroundColor = hex.flatMap(Color.init(hex:)) }
    }
}

/// The formats the toolbar and the hardware keys share (`EditorToolbar`, `DocumentModel.handleKey`).
extension DocumentModel {
    /// Whether the attribute is set across the whole selection; for a bare cursor, the typing attributes count.
    func activeTextHas(_ check: (AttributeContainer) -> Bool) -> Bool {
        switch activeSelection.indices(in: activeText) {
        case .insertionPoint:
            return check(activeSelection.typingAttributes(in: activeText))
        case .ranges(let ranges):
            return EditorText.allFormatted(activeText, in: ranges, check)
        }
    }

    // Strikethrough, code and highlight also set SwiftUI attributes that survive typing (`EditorText`), both sides
    // together. Strikethrough counts only the visible style, like saving (`EditorText.normalized`).

    var activeTextIsStruck: Bool { activeTextHas { $0.strikethroughStyle != nil } }
    var activeTextIsCode: Bool { activeTextHas { $0.inlinePresentationIntent?.contains(.code) == true || $0.font == EditorText.codeFont } }
    var activeTextIsHighlighted: Bool {
        activeTextHas { $0.docmost.highlight != nil || ($0.backgroundColor != nil && $0.backgroundColor != EditorText.codeBackground) }
    }

    func toggleStrikethrough() {
        let enabled = activeTextIsStruck
        EditorText.transformRuns(of: &activeText, in: &activeSelection) { container in
            var intents = container.inlinePresentationIntent ?? []
            if enabled { intents.remove(.strikethrough) } else { intents.insert(.strikethrough) }
            container.inlinePresentationIntent = intents.isEmpty ? nil : intents
            container.strikethroughStyle = enabled ? nil : .single
        }
    }

    func toggleInlineCode() {
        let enabled = activeTextIsCode
        EditorText.transformRuns(of: &activeText, in: &activeSelection) { EditorText.setCode(!enabled, in: &$0) }
    }

    func toggleHighlight() {
        let enabled = activeTextIsHighlighted
        EditorText.transformRuns(of: &activeText, in: &activeSelection) { EditorText.setHighlight(!enabled, in: &$0) }
    }

    /// ⌘⇧S, ⌘E and ⌘⇧H, as the toolbar's buttons.
    func toggleFormat(_ action: EditorKeyAction) {
        switch action {
        case .strikethrough: toggleStrikethrough()
        case .inlineCode: toggleInlineCode()
        case .highlight: toggleHighlight()
        default: break
        }
    }
}
