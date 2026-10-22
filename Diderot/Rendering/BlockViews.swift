import SwiftUI
import DocmostKit

/// All blocks of a document, inside the version history's `ScrollView` (`HistoryDetailView`).
struct ContentDocumentView: View {
    let document: ContentDocument

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in
                BlockView(block: block)
            }
            if !document.footnotes.isEmpty {
                FootnotesView(footnotes: document.footnotes)
            }
        }
    }
}

/// Renders one block; container blocks render their children eagerly (depth bounded by the content).
struct BlockView: View {
    let block: Block

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            ParagraphView(text: text)
        case .heading(let level, let text):
            HeadingView(level: level, text: text)
        case .blockquote(let blocks):
            BlockquoteView { BlockStack(blocks: blocks) }
        case .bulletList(let items):
            ListBlockView(items: items, ordered: false)
        case .orderedList(let items):
            ListBlockView(items: items, ordered: true)
        case .taskList(let items):
            TaskListView(items: items)
        case .codeBlock(let language, let code):
            if language == "mermaid" {
                MermaidView(code: code)
            } else {
                CodeBlockView(language: language, code: code)
            }
        case .horizontalRule:
            Divider().padding(.vertical, 6)
        case .callout(let kind, let icon, let blocks):
            CalloutView(kind: kind, icon: icon, blocks: blocks)
        case .details(let open, let summary, let blocks):
            DetailsView(initiallyOpen: open, summary: summary, blocks: blocks)
        case .image(let image):
            ContentImageView(image: image)
        case .media(let media):
            switch media.kind {
            case .video, .audio: VideoBlockView(media: media)
            case .pdf: PDFBlockView(media: media)
            case .attachment: AttachmentBlockView(media: media)
            case .drawio, .excalidraw: DiagramView(media: media)
            case .embed, .youtube: EmbedBlockView(media: media)
            }
        case .table(let table):
            TableView(table: table)
        case .columns(let columns, let weights):
            ColumnsView(columns: columns, weights: weights)
        case .mathBlock(let latex):
            MathBlockView(latex: latex)
        case .subpages:
            SubpagesBlockView()
        case .transclusionSource(let blocks):
            TransclusionSourceView(blocks: blocks)
        case .transclusionReference(let sourcePageId, let transclusionId):
            TransclusionReferenceView(sourcePageId: sourcePageId, transclusionId: transclusionId)
        case .base(let pageId):
            // Another database here (blocks moved) starts fresh instead of showing the previous one until loaded.
            BaseEmbedCard(pageId: pageId).id(pageId)
        case .pageBreak:
            PageBreakView()
        case .unknown(let type, let blocks):
            UnknownBlockView(type: type, blocks: blocks)
        }
    }
}

// MARK: - Text

struct ParagraphView: View {
    let text: TextBlock
    @Environment(\.renderContext) private var context
    @Environment(\.paragraphFont) private var paragraphFont

    var body: some View {
        if text.inlines.isEmpty {
            Text(" ")
        } else {
            Text(InlineTextBuilder(baseURL: context.baseURL, font: paragraphFont ?? .body).attributedString(for: text.inlines))
                .multilineTextAlignment(text.align.textAlignment)
                .frame(maxWidth: .infinity, alignment: text.align.frameAlignment)
                .padding(.leading, CGFloat(text.indent) * 24)
                .textSelection(.enabled)
        }
    }
}

struct HeadingView: View {
    let level: Int
    let text: TextBlock
    @Environment(\.renderContext) private var context

    /// Also the editor's (`TextNodeView`), so a page and its versions look the same.
    static func font(level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        case 5: return .subheadline.bold()
        default: return .footnote.bold()
        }
    }

    var body: some View {
        let font = Self.font(level: level)
        Text(InlineTextBuilder(baseURL: context.baseURL, font: font).attributedString(for: text.inlines))
            .font(font)
            .multilineTextAlignment(text.align.textAlignment)
            .frame(maxWidth: .infinity, alignment: text.align.frameAlignment)
            .padding(.top, level <= 2 ? 8 : 0)
            .padding(.leading, CGFloat(text.indent) * 24)
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
    }
}

extension TextAlign? {
    var textAlignment: TextAlignment {
        switch self {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }
}

// MARK: - Container

struct BlockStack: View {
    let blocks: [Block]
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in
                BlockView(block: block)
            }
        }
    }
}

/// Quote bar beside its blocks, in the reader and the editor.
struct BlockquoteView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3)
            content
        }
        .padding(.vertical, 2)
    }
}

struct ListBlockView: View {
    let items: [ListItem]
    let ordered: Bool
    @Environment(\.listDepth) private var listDepth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(for: item))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                        .accessibilityHidden(true)
                    BlockStack(blocks: item.blocks, spacing: 6)
                        .environment(\.listDepth, listDepth + 1)
                }
            }
        }
        .padding(.leading, listDepth == 0 ? 0 : 4)
    }

    private func marker(for item: ListItem) -> String {
        if ordered {
            return "\(item.number ?? 1)."
        }
        return Self.bullet(depth: listDepth)
    }

    /// Also the editor's (`ListNodeView`).
    static func bullet(depth: Int) -> String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "‣"
        }
    }
}

struct TaskListView: View {
    let items: [TaskItem]
    @Environment(\.listDepth) private var listDepth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(item.checked ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 22)
                        .accessibilityLabel(item.checked ? "Completed" : "Not completed")
                    BlockStack(blocks: item.blocks, spacing: 6)
                        .environment(\.listDepth, listDepth + 1)
                        .foregroundStyle(item.checked ? .secondary : .primary)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if let language, language != "mermaid" {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }
}

struct CalloutView: View {
    let kind: CalloutKind
    let icon: String?
    let blocks: [Block]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                Text(icon).font(.title3)
            } else {
                Image(systemName: kind.symbol)
                    .font(.title3)
                    .foregroundStyle(kind.tint)
            }
            BlockStack(blocks: blocks)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(kind.tint.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(String(localized: kind.title)) callout"))
    }
}

/// Callout colors and symbols of the reader and the editor (`CalloutNodeView`).
extension CalloutKind {
    var title: LocalizedStringResource {
        switch self {
        case .default: "Default"
        case .info: "Info"
        case .note: "Note"
        case .success: "Success"
        case .warning: "Warning"
        case .danger: "Danger"
        }
    }

    var tint: Color {
        switch self {
        case .default: .gray
        case .info: .blue
        case .note: .purple
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }

    /// The web shows the info icon for "default" too.
    var symbol: String {
        switch self {
        case .default, .info: "info.circle"
        case .note: "pencil.and.list.clipboard"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "exclamationmark.octagon"
        }
    }
}

struct DetailsView: View {
    let summary: [Inline]
    let blocks: [Block]
    @Environment(\.renderContext) private var context
    @State private var isExpanded: Bool

    init(initiallyOpen: Bool, summary: [Inline], blocks: [Block]) {
        self.summary = summary
        self.blocks = blocks
        self._isExpanded = State(initialValue: initiallyOpen)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            BlockStack(blocks: blocks)
                .padding(.top, 6)
        } label: {
            Text(InlineTextBuilder(baseURL: context.baseURL, font: .body.weight(.medium)).attributedString(for: summary))
        }
        .tint(.secondary)
    }
}

/// Columns as in the editor: side by side at regular width with the web's width shares, stacked when narrow.
struct ColumnsView: View {
    let columns: [[Block]]
    let weights: [Double]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let sideBySide = sizeClass == .regular
        // One layout for both widths: a size-class change (rotation, iPad window) doesn't rebuild the content.
        let layout = sideBySide
            ? AnyLayout(WeightedColumnsLayout(weights: weights.map { CGFloat($0) }, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        layout {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, blocks in
                BlockStack(blocks: blocks)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Side by side with fixed width shares; as tall as the tallest column. Also the editor's (`ColumnsNodeView`).
struct WeightedColumnsLayout: Layout {
    let weights: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let widths = columnWidths(total: width, count: subviews.count)
        let height = subviews.indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: widths[$0], height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }

    private func columnWidths(total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let available = max(total - spacing * CGFloat(count - 1), 0)
        let parts = (0..<count).map { $0 < weights.count ? max(weights[$0], 0.1) : 1 }
        let sum = parts.reduce(0, +)
        return parts.map { available * $0 / sum }
    }
}

struct TransclusionSourceView: View {
    let blocks: [Block]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .accessibilityLabel("Synced block")
            BlockStack(blocks: blocks)
        }
    }
}

struct UnknownBlockView: View {
    let type: String
    let blocks: [Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BlockStack(blocks: blocks)
            Text("Unsupported block: \(type)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Placeholders

struct PlaceholderCard<Accessory: View>: View {
    let icon: String
    let title: String
    var detail: String?
    var titleLineLimit: Int?
    var detailLineLimit: Int?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                // Decoration: VoiceOver would read the symbol's name (e.g. "Annotate").
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(titleLineLimit)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(detailLineLimit)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension PlaceholderCard where Accessory == EmptyView {
    init(icon: String, title: String, detail: String?) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

struct PageBreakView: View {
    var body: some View {
        HStack {
            line
            Text("Page break").font(.caption2).foregroundStyle(.tertiary)
            line
        }
    }

    private var line: some View {
        Rectangle().fill(.tertiary).frame(height: 1)
    }
}

/// Simple table: column widths from `colwidth`, `colspan` via `gridCellColumns`; `rowspan` is ignored.
struct TableView: View {
    let table: TableBlock

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(table.rows) { row in
                    GridRow {
                        ForEach(row.cells) { cell in
                            TableCellView(cell: cell)
                                .gridCellColumns(cell.colspan)
                        }
                    }
                }
            }
            // Rows keep their content height; otherwise the grid splits its height evenly between the stretching cells.
            .fixedSize(horizontal: false, vertical: true)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct TableCellView: View {
    let cell: TableBlock.Cell

    var body: some View {
        TableCellWidth(fixed: width) {
            BlockStack(blocks: cell.blocks, spacing: 4)
                .environment(\.listDepth, 0)
                .environment(\.paragraphFont, cell.isHeader ? .body.bold() : nil)
                .padding(8)
        }
        // Each cell matches its column's widest and its row's tallest, so borders line up.
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.background(name: cell.backgroundColorName, hex: cell.backgroundColor, isHeader: cell.isHeader))
        .border(Color(.separator), width: 0.5)
    }

    private var width: CGFloat? {
        guard let total = cell.colwidth?.reduce(0, +), total > 0 else { return nil }
        return CGFloat(total)
    }

    /// Also the editor's (`TableCellNodeView`).
    static func background(name: String?, hex: String?, isHeader: Bool) -> Color {
        if let name {
            return HighlightPalette.color(name: name, hex: hex)
        }
        if let hex, let color = Color(hex: hex) {
            return color.opacity(0.4)
        }
        return isHeader ? Color(.secondarySystemBackground) : .clear
    }
}

/// A table cell's width: its `colwidth`, else its content's own width between 120 and 320 points. A long paragraph
/// wraps at that width: the table's horizontal scroll view proposes no width, so text would run on in one line.
/// Also the editor's (`TableCellNodeView`).
struct TableCellWidth: Layout {
    var fixed: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = fixed ?? min(max(content.sizeThatFits(.unspecified).width, 120), 320)
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

struct FootnotesView: View {
    let footnotes: [Footnote]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            ForEach(Array(footnotes.enumerated()), id: \.element.id) { index, footnote in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                    // Paragraphs take their font from `paragraphFont`, not `.font`.
                    BlockStack(blocks: footnote.blocks, spacing: 4)
                        .environment(\.paragraphFont, .footnote)
                }
            }
        }
    }
}
