import SwiftUI
import DocmostKit

/// Builds an `AttributedString` with SwiftUI attributes from inline runs.
struct InlineTextBuilder {
    var baseURL: URL?
    var font: Font = .body
    var monospacedFont: Font = .system(.callout, design: .monospaced)
    /// Block identity when status and math atoms should be tappable (editing, see `AtomLink`).
    var atomLinkBlock: String?
    /// A link's title from the server's preview (`LinkPreviewStore`), for integration mentions.
    var previewTitle: (String) -> String? = { _ in nil }
    /// Unresolved comments marked and opening on tap (`showsCommentMarks`).
    var showsComments = true

    func attributedString(for inlines: [Inline]) -> AttributedString {
        var result = AttributedString()
        var counts: [String: Int] = [:]
        for inline in inlines {
            var run = attributedString(for: inline)
            if let block = atomLinkBlock, let type = inline.atomType {
                let index = counts[type, default: 0]
                counts[type] = index + 1
                // The atom's sheet wins over a link or comment on it.
                if let url = AtomLink.url(block: block, type: type, index: index) { run.link = url }
            }
            result.append(run)
        }
        return result
    }

    private func attributedString(for inline: Inline) -> AttributedString {
        switch inline {
        case .text(let text, let style):
            return styled(text, style)
        case .hardBreak:
            return AttributedString("\n")
        case .mention(let mention):
            return mentionRun(mention)
        case .mathInline(let latex):
            var run = AttributedString(latex)
            run.font = monospacedFont
            run.backgroundColor = Color(.tertiarySystemFill)
            return run
        case .status(let text, let color):
            var run = AttributedString(" \(text) ")
            run.font = font.weight(.medium)
            run.backgroundColor = StatusPalette.background(for: color)
            run.foregroundColor = StatusPalette.foreground(for: color)
            return run
        case .integrationMention(let link):
            // Tinted like a status, without the service's logo (no third-party images).
            var run = AttributedString(" \(previewTitle(link.url) ?? IntegrationLinks.describe(link.url).title) ")
            run.font = font.weight(.medium)
            run.foregroundColor = .accentColor
            run.backgroundColor = Color.accentColor.opacity(0.12)
            if let url = URL(string: link.url) { run.link = url }
            return run
        case .footnoteReference(let number, let dataId):
            var run = AttributedString("[\(number ?? "?")]")
            run.font = .caption2
            run.baselineOffset = 6
            if let dataId {
                run.link = ContentLinkRouter.url(for: "#\(dataId)", baseURL: baseURL)
            }
            return run
        case .marked(let atom, let style):
            var run = attributedString(for: atom)
            apply(style, to: &run)
            return run
        case .unknown:
            return AttributedString()
        }
    }

    private func styled(_ text: String, _ style: InlineStyle) -> AttributedString {
        var run = AttributedString(text)
        run.font = style.code ? monospacedFont : font
        if style.superscript || style.subscript {
            run.font = style.code ? Font.system(.caption, design: .monospaced) : Font.caption
            run.baselineOffset = style.superscript ? 6 : -3
        }
        if style.code {
            run.backgroundColor = Color(.secondarySystemFill)
        }
        apply(style, to: &run)
        return run
    }

    /// The marks text and atoms share; an atom keeps its own link (mention) and font, made bold or italic.
    private func apply(_ style: InlineStyle, to run: inout AttributedString) {
        if style.bold { run.font = (run.font ?? font).bold() }
        if style.italic { run.font = (run.font ?? font).italic() }
        if style.strike {
            run.strikethroughStyle = .single
        }
        if style.underline {
            run.underlineStyle = .single
        }
        if let highlight = style.highlight {
            run.backgroundColor = HighlightPalette.color(name: highlight.colorName, hex: highlight.color)
        }
        if let textColor = style.textColor, let color = Color(hex: textColor) {
            run.foregroundColor = color
        }
        if let link = style.link, run.link == nil, let url = ContentLinkRouter.url(for: link.href, baseURL: baseURL) {
            run.link = url
            run.foregroundColor = .accentColor
            run.underlineStyle = .single
        }
        if showsComments, let comment = style.comment, !comment.resolved {
            run.backgroundColor = Color.yellow.opacity(0.25)
            // Opens the comment on tap, in the text color instead of link styling; a real link takes precedence.
            if run.link == nil, let id = comment.commentId, let url = CommentLink.url(for: id) {
                run.link = url
                if run.foregroundColor == nil { run.foregroundColor = .primary }
            }
        }
    }

    private func mentionRun(_ mention: Mention) -> AttributedString {
        let label = mention.label ?? "…"
        switch mention.entityType {
        case .page:
            var run = AttributedString("📄 \(label)")
            run.font = font.weight(.medium)
            run.foregroundColor = .accentColor
            if let slugId = mention.slugId ?? mention.entityId {
                run.link = ContentLinkRouter.pageURL(slugId: slugId, anchor: mention.anchorId)
            }
            return run
        case .user, .none:
            var run = AttributedString("@\(label)")
            run.font = font.weight(.medium)
            run.foregroundColor = .accentColor
            run.backgroundColor = Color.accentColor.opacity(0.12)
            if let id = mention.entityId {
                run.link = ContentLinkRouter.userURL(id: id)
            }
            return run
        }
    }
}

/// Highlight colors like the web client (`color-selector.tsx`), adapted for light and dark mode.
nonisolated enum HighlightPalette {
    static func color(name: String?, hex: String?) -> Color {
        switch name?.lowercased() {
        case "yellow": return Color.yellow.opacity(0.35)
        case "green": return Color.green.opacity(0.3)
        case "blue": return Color.blue.opacity(0.25)
        case "purple": return Color.purple.opacity(0.25)
        case "red": return Color.red.opacity(0.25)
        case "pink": return Color.pink.opacity(0.25)
        case "orange": return Color.orange.opacity(0.3)
        case "gray", "grey": return Color.gray.opacity(0.3)
        case "brown": return Color.brown.opacity(0.3)
        default:
            if let hex, let color = Color(hex: hex) {
                return color.opacity(0.4)
            }
            return Color.yellow.opacity(0.35)
        }
    }
}

nonisolated enum StatusPalette {
    static func background(for name: String) -> Color {
        switch name.lowercased() {
        case "blue": return Color.blue.opacity(0.18)
        case "green": return Color.green.opacity(0.2)
        case "yellow": return Color.yellow.opacity(0.3)
        case "red": return Color.red.opacity(0.18)
        case "purple": return Color.purple.opacity(0.18)
        default: return Color.gray.opacity(0.2)
        }
    }

    static func foreground(for name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .orange
        case "red": return .red
        case "purple": return .purple
        default: return .primary
        }
    }
}

nonisolated extension Color {
    /// `#rgb`, `#rrggbb` or `#rrggbbaa`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 3 || text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch text.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension EnvironmentValues {
    /// Unresolved comments show marked and open on tap; not in the presentation mode, as on the web.
    @Entry var showsCommentMarks = true
    /// Heading fonts by level instead of the reader's (`HeadingView.font`): the presentation mode's larger ones.
    @Entry var headingFont: ((Int) -> Font)?
}

/// Makes comment marks in text tappable: a custom scheme that the page view intercepts to open the comment.
enum CommentLink {
    static let scheme = "docmost-comment"

    static func url(for commentId: String) -> URL? {
        URL(string: "\(scheme)://\(commentId)")
    }

    static func commentId(from url: URL) -> String? {
        url.scheme == scheme ? url.host() : nil
    }
}

/// Makes status and math atoms tappable while editing: a custom scheme carrying the block, type and index of the atom
/// within the block, which the page view intercepts to open the matching sheet.
enum AtomLink {
    static let scheme = "docmost-atom"

    static func url(block: String, type: String, index: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "edit"
        components.queryItems = [
            URLQueryItem(name: "block", value: block), URLQueryItem(name: "type", value: type), URLQueryItem(name: "index", value: String(index)),
        ]
        return components.url
    }

    static func parse(_ url: URL) -> (block: String, type: String, index: Int)? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let block = items.first(where: { $0.name == "block" })?.value,
              let type = items.first(where: { $0.name == "type" })?.value,
              let index = items.first(where: { $0.name == "index" })?.value.flatMap(Int.init)
        else { return nil }
        return (block, type, index)
    }
}

private extension Inline {
    /// Node type of the tappable atoms.
    var atomType: String? {
        switch self {
        case .status: "status"
        case .mathInline: "mathInline"
        case .integrationMention: "integrationMention"
        case .marked(let atom, _): atom.atomType
        default: nil
        }
    }
}
