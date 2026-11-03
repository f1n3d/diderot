import Foundation

/// A stored mark as the reader (`ContentParser`) and the editor (`InlineAttributedText`) read it, and as the editor
/// writes one it made: one reading of Docmost's marks for both, so the same text shows the same way in both. A mark of
/// another type, or without what it needs (a link without `href`, a text style without a color), is none of these: the
/// reader shows the text plain, the editor writes it back as stored.
public enum InlineMark: Hashable, Sendable {
    case bold, italic, strike, underline, code, superscript, `subscript`
    /// `integrationProvider`: the service the web recognized the link as (Docmost 0.97), e.g. `github`.
    case link(href: String, integrationProvider: String?)
    /// A color of the web's palette by name (`HighlightColors`) with its hex color, or a hex color alone.
    case highlight(color: String?, colorName: String?)
    case textColor(String)
    case comment(id: String?, resolved: Bool)

    public init?(_ mark: PMMark) {
        switch mark.type {
        case "bold": self = .bold
        case "italic": self = .italic
        case "strike": self = .strike
        case "underline": self = .underline
        case "code": self = .code
        case "superscript": self = .superscript
        case "subscript": self = .subscript
        case "link":
            guard let href = mark.string("href"), !href.isEmpty else { return nil }
            self = .link(href: href, integrationProvider: mark.string("integrationProvider"))
        case "highlight":
            self = .highlight(color: mark.string("color"), colorName: mark.string("colorName"))
        case "textStyle":
            guard let color = mark.string("color"), !color.isEmpty else { return nil }
            self = .textColor(color)
        case "comment":
            self = .comment(id: mark.string("commentId"), resolved: mark.bool("resolved") ?? false)
        default:
            return nil
        }
    }

    /// The mark as the web writes a new one: a link opens in a new tab and is `internal` when relative (mailto: and tel:
    /// have no host, but the web must open them outside); a highlight without a name has `colorName` null.
    public var mark: PMMark {
        switch self {
        case .bold: return PMMark(type: "bold")
        case .italic: return PMMark(type: "italic")
        case .strike: return PMMark(type: "strike")
        case .underline: return PMMark(type: "underline")
        case .code: return PMMark(type: "code")
        case .superscript: return PMMark(type: "superscript")
        case .subscript: return PMMark(type: "subscript")
        case .link(let href, let provider):
            var attrs: [String: JSONValue] = ["href": .string(href), "target": "_blank", "internal": .bool(URL(string: href)?.scheme == nil)]
            if let provider { attrs["integrationProvider"] = .string(provider) }
            return PMMark(type: "link", attrs: attrs)
        case .highlight(let color, let colorName):
            return PMMark(type: "highlight", attrs: ["color": color.map(JSONValue.string) ?? .null, "colorName": colorName.map(JSONValue.string) ?? .null])
        case .textColor(let color):
            return PMMark(type: "textStyle", attrs: ["color": .string(color)])
        case .comment(let id, let resolved):
            return PMMark(type: "comment", attrs: ["commentId": id.map(JSONValue.string) ?? .null, "resolved": .bool(resolved)])
        }
    }
}
