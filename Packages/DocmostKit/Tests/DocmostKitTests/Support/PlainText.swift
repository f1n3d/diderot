@testable import DocmostKit

/// Plain text and table size of parsed content, for assertions.
extension Block {
    var plainText: String {
        switch kind {
        case .paragraph(let block), .heading(_, let block): return block.plainText
        case .blockquote(let blocks), .callout(_, _, let blocks), .transclusionSource(let blocks), .unknown(_, let blocks):
            return blocks.map(\.plainText).joined(separator: "\n")
        case .bulletList(let items), .orderedList(let items):
            return items.map { $0.blocks.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .taskList(let items):
            return items.map { $0.blocks.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .codeBlock(_, let code): return code
        case .details(_, let summary, let blocks):
            return ([summary.plainText] + blocks.map(\.plainText)).joined(separator: "\n")
        case .columns(let columns, _):
            return columns.map { $0.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .table(let table):
            return table.rows.map { $0.cells.map { $0.blocks.map(\.plainText).joined(separator: " ") }.joined(separator: " | ") }.joined(separator: "\n")
        case .mathBlock(let latex): return latex
        case .image(let image): return image.alt ?? ""
        case .media(let media): return media.name ?? ""
        case .tabs(let tabs):
            return tabs.map { ([$0.label] + $0.blocks.map(\.plainText)).joined(separator: "\n") }.joined(separator: "\n")
        case .integrationCard(let link): return link.url
        case .horizontalRule, .subpages, .transclusionReference, .base, .pageBreak: return ""
        }
    }
}

extension TextBlock {
    var plainText: String { inlines.plainText }
}

extension TableBlock {
    var columnCount: Int {
        rows.map { $0.cells.reduce(0) { $0 + $1.colspan } }.max() ?? 0
    }
}

extension [Inline] {
    var plainText: String {
        map { inline -> String in
            switch inline {
            case .text(let text, _): return text
            case .hardBreak: return "\n"
            case .mention(let mention): return mention.label.map { mention.entityType == .user ? "@\($0)" : $0 } ?? ""
            case .mathInline(let latex): return latex
            case .status(let text, _): return text
            case .footnoteReference(let number, _): return number.map { "[\($0)]" } ?? ""
            case .integrationMention(let link): return link.url
            case .marked(let atom, _): return [atom].plainText
            case .unknown: return ""
            }
        }.joined()
    }
}
