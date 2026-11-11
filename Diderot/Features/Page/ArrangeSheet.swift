import SwiftUI
import DocmostKit

/// Reorder blocks by dragging, or delete them; a list's items one by one (`DocumentModel.elements`).
struct ArrangeSheet: View {
    let model: DocumentModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.elements) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: kind(of: entry)))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(summary(for: kind(of: entry)))
                            .lineLimit(2)
                    }
                }
                .onMove { source, destination in
                    Task { await model.moveBlocks(from: source, to: destination) }
                }
                .onDelete { offsets in
                    let blocks = model.elements
                    for offset in offsets where blocks.indices.contains(offset) {
                        Task { await model.delete(blocks[offset].ref) }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arrange Blocks")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// The entry's block; a bullet or numbered list's item as a one-item list of its kind, which names it and gives it
    /// its symbol (a checklist's item has its own).
    private func kind(of entry: NodeEntry) -> PMNode {
        guard entry.node.type == "listItem", let list = model.node(at: Array(entry.ref.path.dropLast())) else { return entry.node }
        return PMNode(type: list.type, content: [entry.node])
    }

    private func summary(for node: PMNode) -> String {
        let text = node.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(80)) }
        switch node.type {
        case "image": return String(localized: "Image")
        case "table": return String(localized: "Table")
        case "horizontalRule": return String(localized: "Divider")
        case "pageBreak": return String(localized: "Page break")
        case "subpages": return String(localized: "Subpages")
        case "columns": return String(localized: "Columns")
        case "transclusionSource", "transclusionReference": return String(localized: "Synced block")
        case "mathBlock": return String(localized: "Math block")
        case "embed": return String(localized: "Embed \(EmbedProvider(rawValue: node.string("provider") ?? "")?.name ?? "Iframe")")
        case "drawio": return String(localized: "Draw.io diagram")
        case "excalidraw": return String(localized: "Excalidraw drawing")
        case "base": return String(localized: "Database (inline)")
        case "integrationCard": return IntegrationLinks.describe(node.string("url") ?? "").title
        case "tabs": return String(localized: "Tabs")
        case "video": return String(localized: "Video")
        case "audio": return String(localized: "Audio")
        case "pdf", "attachment": return node.string("name") ?? String(localized: "File attachment")
        case "heading": return String(localized: "Heading \(node.int("level") ?? 1)")
        case "codeBlock" where node.string("language") == "mermaid": return String(localized: "Mermaid diagram")
        default:
            // Empty text blocks by their name in the insert menu, unknown ones as "Block".
            let templates: [String: BlockTemplate] = [
                "paragraph": .paragraph, "bulletList": .bulletList, "orderedList": .orderedList, "taskList": .taskList, "taskItem": .taskList,
                "blockquote": .quote, "callout": .callout, "details": .toggle, "codeBlock": .codeBlock,
            ]
            return String(localized: templates[node.type]?.titleResource ?? "Block")
        }
    }

    private func symbol(for node: PMNode) -> String {
        switch node.type {
        case "heading": "textformat.size"
        case "bulletList": "list.bullet"
        case "orderedList": "list.number"
        case "taskList": "checklist"
        case "taskItem": node.bool("checked") == true ? "checkmark.square" : "square"
        case "blockquote": "text.quote"
        case "codeBlock": "chevron.left.forwardslash.chevron.right"
        case "callout": "info.bubble"
        case "details": "chevron.right.square"
        case "image": "photo"
        case "table": "tablecells"
        case "horizontalRule": "minus"
        case "pageBreak": "rectangle.split.1x2"
        case "subpages": "list.bullet.indent"
        case "columns": "rectangle.split.3x1"
        case "transclusionSource", "transclusionReference": "arrow.triangle.2.circlepath"
        case "mathBlock": "x.squareroot"
        case "embed": "globe"
        case "drawio": "pencil.and.outline"
        case "excalidraw": "scribble.variable"
        case "base": "tablecells.badge.ellipsis"
        case "tabs": "rectangle.topthird.inset.filled"
        case "integrationCard": "link"
        case "video": "video"
        case "audio": "waveform"
        case "pdf": "doc.richtext"
        case "attachment": "paperclip"
        default: "text.alignleft"
        }
    }
}
