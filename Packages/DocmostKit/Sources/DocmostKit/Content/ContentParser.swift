import Foundation

/// ProseMirror tree → `ContentDocument`, adding the schema defaults (`collaboration.util.ts`) stored attributes lack.
public enum ContentParser {
    public static func parse(_ root: PMNode) -> ContentDocument {
        var state = State()
        var blocks: [Block] = []
        var footnotes: [Footnote] = []
        for (index, child) in root.children.enumerated() {
            if child.type == "footnotes" {
                footnotes = parseFootnotes(child, path: "\(index)", state: &state)
            } else {
                blocks.append(parseBlock(child, path: "\(index)", state: &state))
            }
        }
        return ContentDocument(blocks: blocks, footnotes: footnotes, anchors: state.anchors)
    }

    private struct State {
        var anchors: [String: String] = [:]
    }

    private static let inlineTypes: Set<String> = [
        "text", "hardBreak", "mention", "mathInline", "status", "footnoteReference", "integrationMention",
    ]

    // MARK: - Blocks

    private static func parseBlock(_ node: PMNode, path: String, state: inout State) -> Block {
        let id = node.string("id") ?? "p\(path)"
        func children() -> [Block] {
            parseBlocks(node.children, path: path, state: &state)
        }

        switch node.type {
        case "paragraph":
            return Block(id: id, kind: .paragraph(textBlock(node)))

        case "heading":
            let level = min(max(node.int("level") ?? 1, 1), 6)
            if let anchor = node.string("id") {
                state.anchors[anchor] = id
            }
            return Block(id: id, kind: .heading(level: level, textBlock(node)))

        case "blockquote":
            return Block(id: id, kind: .blockquote(children()))

        case "bulletList":
            return Block(id: id, kind: .bulletList(listItems(node, path: path, start: nil, state: &state)))

        case "orderedList":
            return Block(id: id, kind: .orderedList(listItems(node, path: path, start: node.int("start") ?? 1, state: &state)))

        case "taskList":
            let items = node.children.enumerated().map { index, item -> TaskItem in
                let itemPath = "\(path).\(index)"
                let blocks = parseBlocks(item.children, path: itemPath, state: &state)
                return TaskItem(id: item.string("id") ?? "p\(itemPath)", checked: item.bool("checked") ?? false, blocks: blocks)
            }
            return Block(id: id, kind: .taskList(items))

        case "codeBlock":
            let language = node.string("language").flatMap { $0.isEmpty ? nil : $0 }
            return Block(id: id, kind: .codeBlock(language: language, code: node.plainText))

        case "horizontalRule":
            return Block(id: id, kind: .horizontalRule)

        case "callout":
            let kind = node.string("type").flatMap(CalloutKind.init(rawValue:)) ?? .info
            let icon = node.string("icon").flatMap { $0.isEmpty ? nil : $0 }
            return Block(id: id, kind: .callout(kind: kind, icon: icon, children()))

        case "details":
            var summary: [Inline] = []
            var content: [Block] = []
            for (index, child) in node.children.enumerated() {
                switch child.type {
                case "detailsSummary": summary = inlines(of: child)
                case "detailsContent": content = parseBlocks(child.children, path: "\(path).\(index)", state: &state)
                default: content.append(parseBlock(child, path: "\(path).\(index)", state: &state))
                }
            }
            return Block(id: id, kind: .details(open: node.bool("open") ?? false, summary: summary, content))

        case "image":
            return Block(id: id, kind: .image(ImageBlock(
                src: node.string("src"), alt: node.string("alt"), width: Length(json: node.attr("width")),
                aspectRatio: node.double("aspectRatio"), align: node.string("align").flatMap(MediaAlign.init(rawValue:)) ?? .center
            )))

        case "video", "audio", "attachment", "pdf", "drawio", "excalidraw", "embed", "youtube":
            let kind = MediaBlock.Kind(rawValue: node.type)!
            return Block(id: id, kind: .media(MediaBlock(
                kind: kind, src: node.string("src") ?? node.string("url"), attachmentId: node.string("attachmentId"),
                name: node.string("name") ?? node.string("title"), size: node.int("size"), provider: node.string("provider")
            )))

        case "table":
            return Block(id: id, kind: .table(table(node, path: path, state: &state)))

        case "columns":
            let columns = node.children.enumerated().map { index, column in
                parseBlocks(column.children, path: "\(path).\(index)", state: &state)
            }
            return Block(id: id, kind: .columns(columns, weights: columnWeights(of: node)))

        case "mathBlock":
            return Block(id: id, kind: .mathBlock(node.string("text") ?? node.plainText))

        case "subpages":
            return Block(id: id, kind: .subpages(sortBy: node.string("sortBy").flatMap(SubpagesSort.init(rawValue:)) ?? .manual))

        case "tabs":
            var seen: Set<String> = []
            let tabs = node.children.enumerated().filter { $0.element.type == "tab" }.map { index, tab -> TabItem in
                let tabPath = "\(path).\(index)"
                let label = tab.children.first { $0.type == "tabLabel" }
                let panel = tab.children.first { $0.type == "tabPanel" }
                let blocks = panel.map { parseBlocks($0.children, path: "\(tabPath).1", state: &state) } ?? []
                var tabId = tab.string("id") ?? ""
                if tabId.isEmpty || seen.contains(tabId) { tabId = "t\(tabPath)" }
                seen.insert(tabId)
                return TabItem(id: tabId, label: label?.plainText ?? "", blocks: blocks)
            }
            return Block(id: id, kind: .tabs(tabs))

        case "integrationCard":
            return Block(id: id, kind: .integrationCard(integrationLink(node)))

        case "transclusionSource":
            if let anchor = node.string("id") {
                state.anchors[anchor] = id
            }
            return Block(id: id, kind: .transclusionSource(children()))

        case "transclusionReference":
            return Block(id: id, kind: .transclusionReference(
                sourcePageId: node.string("sourcePageId"), transclusionId: node.string("transclusionId")
            ))

        case "base":
            return Block(id: id, kind: .base(pageId: node.string("pageId")))

        case "pageBreak":
            return Block(id: id, kind: .pageBreak)

        default:
            // Unknown container: keep the children (like the server); pure text content becomes a paragraph.
            if !node.children.isEmpty, node.children.allSatisfy({ inlineTypes.contains($0.type) }) {
                return Block(id: id, kind: .unknown(type: node.type, [
                    Block(id: "\(id).text", kind: .paragraph(textBlock(node)))
                ]))
            }
            return Block(id: id, kind: .unknown(type: node.type, children()))
        }
    }

    private static func parseBlocks(_ nodes: [PMNode], path: String, state: inout State) -> [Block] {
        var blocks: [Block] = []
        for (index, node) in nodes.enumerated() {
            if inlineTypes.contains(node.type) {
                // Loose inline content at block position (e.g. text directly in a listItem) → paragraph.
                blocks.append(Block(id: "p\(path).\(index)", kind: .paragraph(TextBlock(inlines: inlines(of: PMNode(type: "paragraph", content: [node]))))))
            } else {
                blocks.append(parseBlock(node, path: "\(path).\(index)", state: &state))
            }
        }
        return blocks
    }

    private static func listItems(_ list: PMNode, path: String, start: Int?, state: inout State) -> [ListItem] {
        list.children.enumerated().map { index, item in
            let itemPath = "\(path).\(index)"
            let blocks = parseBlocks(item.children, path: itemPath, state: &state)
            return ListItem(id: item.string("id") ?? "p\(itemPath)", number: start.map { $0 + index }, blocks: blocks)
        }
    }

    private static func table(_ node: PMNode, path: String, state: inout State) -> TableBlock {
        let rows = node.children.enumerated().map { rowIndex, row -> TableBlock.Row in
            let rowPath = "\(path).\(rowIndex)"
            let cells = row.children.enumerated().map { cellIndex, cell -> TableBlock.Cell in
                let cellPath = "\(rowPath).\(cellIndex)"
                let colwidth = cell.attr("colwidth")?.arrayValue?.compactMap(\.doubleValue)
                return TableBlock.Cell(
                    id: cell.string("id") ?? "p\(cellPath)",
                    isHeader: cell.type == "tableHeader",
                    colspan: max(cell.int("colspan") ?? 1, 1),
                    colwidth: colwidth?.isEmpty == false ? colwidth : nil,
                    backgroundColor: cell.string("backgroundColor"),
                    backgroundColorName: cell.string("backgroundColorName"),
                    blocks: parseBlocks(cell.children, path: cellPath, state: &state)
                )
            }
            return TableBlock.Row(id: row.string("id") ?? "p\(rowPath)", cells: cells)
        }
        return TableBlock(rows: rows)
    }

    private static func parseFootnotes(_ node: PMNode, path: String, state: inout State) -> [Footnote] {
        node.children.enumerated().map { index, footnote in
            let footnotePath = "\(path).\(index)"
            let id = footnote.string("id") ?? "p\(footnotePath)"
            if let dataId = footnote.string("data-id") {
                state.anchors[dataId] = id
            }
            state.anchors[id] = id
            return Footnote(id: id, blocks: parseBlocks(footnote.children, path: footnotePath, state: &state))
        }
    }

    // MARK: - Inline

    private static func textBlock(_ node: PMNode) -> TextBlock {
        TextBlock(
            inlines: inlines(of: node),
            align: node.string("textAlign").flatMap(TextAlign.init(rawValue:)),
            indent: min(max(node.int("indent") ?? 0, 0), 8)
        )
    }

    /// Width shares of a columns block, as on the web: the columns' `width` (CSS `flex`), else the `layout` preset
    /// (`columns.css`).
    public static func columnWeights(of node: PMNode) -> [Double] {
        let widths = node.children.map { $0.attr("width")?.doubleValue }
        if widths.allSatisfy({ $0 != nil }) { return widths.map { $0 ?? 1 } }
        switch node.string("layout") {
        case "two_left_sidebar": return [1, 2]
        case "two_right_sidebar": return [2, 1]
        case "three_left_wide": return [2, 1, 1]
        case "three_right_wide": return [1, 1, 2]
        case "three_with_sidebars": return [1, 2, 1]
        default: return Array(repeating: 1, count: node.children.count)
        }
    }

    /// Inline content of a text node (paragraph, heading, toggle summary) for display.
    public static func inlines(of node: PMNode) -> [Inline] {
        var result: [Inline] = []
        for child in node.children {
            switch child.type {
            case "text":
                guard let text = child.text, !text.isEmpty else { continue }
                result.append(.text(text, style(for: child.marks ?? [])))
            case "hardBreak":
                result.append(.hardBreak)
            case "mention":
                result.append(marked(.mention(Mention(
                    label: child.string("label"),
                    entityType: child.string("entityType").flatMap(Mention.EntityType.init(rawValue:)),
                    entityId: child.string("entityId"), slugId: child.string("slugId"), anchorId: child.string("anchorId")
                )), child))
            case "mathInline":
                result.append(marked(.mathInline(child.string("text") ?? child.plainText), child))
            case "status":
                result.append(marked(.status(text: child.string("text") ?? "", color: child.string("color") ?? "gray"), child))
            case "footnoteReference":
                result.append(marked(.footnoteReference(number: child.string("referenceNumber"), dataId: child.string("data-id")), child))
            case "integrationMention":
                result.append(marked(.integrationMention(integrationLink(child)), child))
            default:
                if !child.children.isEmpty {
                    result.append(contentsOf: inlines(of: child))
                } else if let text = child.text, !text.isEmpty {
                    result.append(.text(text, style(for: child.marks ?? [])))
                } else {
                    result.append(.unknown(type: child.type))
                }
            }
        }
        return result
    }

    private static func integrationLink(_ node: PMNode) -> IntegrationLink {
        IntegrationLink(url: node.string("url") ?? "", provider: node.string("provider") ?? "")
    }

    private static func marked(_ atom: Inline, _ node: PMNode) -> Inline {
        let style = style(for: node.marks ?? [])
        return style == InlineStyle() ? atom : .marked(atom, style)
    }

    private static func style(for marks: [PMMark]) -> InlineStyle {
        var style = InlineStyle()
        for mark in marks {
            switch mark.type {
            case "bold": style.bold = true
            case "italic": style.italic = true
            case "strike": style.strike = true
            case "underline": style.underline = true
            case "code": style.code = true
            case "superscript": style.superscript = true
            case "subscript": style.subscript = true
            case "link":
                if let href = mark.string("href"), !href.isEmpty {
                    style.link = Link(href: href, integrationProvider: mark.string("integrationProvider"))
                }
            case "highlight":
                style.highlight = Highlight(color: mark.string("color"), colorName: mark.string("colorName"))
            case "textStyle":
                style.textColor = mark.string("color").flatMap { $0.isEmpty ? nil : $0 }
            case "comment":
                style.comment = CommentMark(commentId: mark.string("commentId"), resolved: mark.bool("resolved") ?? false)
            default:
                break
            }
        }
        return style
    }
}
