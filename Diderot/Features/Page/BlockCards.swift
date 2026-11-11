import SwiftUI
import DocmostKit

/// All document blocks (top level lazy); text blocks turn into an editor when tapped.
struct DocumentBody: View {
    let model: DocumentModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(model.topLevel) { entry in
                if entry.node.type == "footnotes" {
                    // Id so the page scrolls here first when the cursor jumps into a footnote.
                    FootnotesNodeView(model: model, node: entry.node, ref: entry.ref)
                        .id(entry.ref.anchorId)
                } else {
                    NodeView(model: model, node: entry.node, ref: entry.ref)
                        .modifier(BlockDragModifier(model: model, entry: entry))
                        // Outermost: scrolling to a block the lazy list hasn't built yet finds its id only there.
                        .id(entry.ref.anchorId)
                }
            }
        }
        .mediaViewer { ContentParser.parse(model.document) }
        .blockPresentations()
    }
}

/// Children of a container (quote, callout, list item, cell, …).
struct NodeListView: View {
    let model: DocumentModel
    let nodes: [PMNode]
    let parentPath: [Int]
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(NodeEntry.entries(nodes, parentPath: parentPath)) { entry in
                NodeView(model: model, node: entry.node, ref: entry.ref)
            }
        }
    }
}

struct NodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef

    var body: some View {
        switch node.type {
        // As in the reader: each level is a view in a view.
        case _ where ref.path.count > ContentParser.maxDepth:
            TooDeepView()
        case "paragraph", "heading", "detailsSummary":
            TextNodeView(model: model, node: node, ref: ref, isEditing: model.active?.ref == ref)
        case "bulletList", "orderedList":
            ListNodeView(model: model, node: node, ref: ref)
        case "taskList":
            TaskListNodeView(model: model, node: node, ref: ref)
        case "blockquote":
            BlockquoteView { NodeListView(model: model, nodes: node.children, parentPath: ref.path).clearOfBlockActions() }
        case "callout":
            CalloutNodeView(model: model, node: node, ref: ref)
        case "details":
            ToggleNodeView(model: model, node: node, ref: ref)
        case "detailsContent":
            NodeListView(model: model, nodes: node.children, parentPath: ref.path)
        case "codeBlock":
            if node.string("language") == "mermaid", model.active?.ref != ref {
                ReaderNodeView(node: node)
                    .onTapGesture { if model.isEditable { model.activate(ref, node: node) } }
            } else {
                CodeNodeView(model: model, node: node, ref: ref)
            }
        case "table":
            TableNodeView(model: model, node: node, ref: ref)
        case "horizontalRule":
            Divider().padding(.vertical, 6)
        case "pageBreak":
            PageBreakView()
        case "columns":
            ColumnsNodeView(model: model, node: node, ref: ref)
        case "transclusionSource":
            SyncedBlockNodeView(model: model, node: node, ref: ref)
        case "transclusionReference":
            SyncedReferenceNodeView(model: model, node: node, ref: ref)
        case "drawio", "excalidraw":
            DiagramNodeView(model: model, node: node)
        case "mathBlock":
            MathBlockNodeView(model: model, node: node, ref: ref)
        case "embed":
            EmbedNodeView(model: model, node: node, ref: ref)
        case "tabs":
            TabsNodeView(model: model, node: node, ref: ref)
        case "subpages":
            SubpagesNodeView(model: model, node: node, ref: ref)
        default:
            ReaderNodeView(node: node)
        }
    }
}

/// Blocks without native editing (images, media, mermaid previews, filled embeds and diagrams, …), via the reader.
struct ReaderNodeView: View {
    let node: PMNode

    var body: some View {
        if let block = ContentParser.parse(PMNode(type: "doc", content: [node])).blocks.first {
            BlockView(block: block)
                .environment(\.listDepth, 0)
        }
    }
}

// MARK: - Text

struct TextNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    /// Active. Set by NodeView so inactive blocks don't observe `active` and aren't rebuilt on every switch.
    let isEditing: Bool
    @Environment(\.renderContext) private var context
    @Environment(\.pageFind) private var find
    @Environment(\.paragraphFont) private var paragraphFont
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.linkPreviews) private var linkPreviews

    private var fontLeading: CGFloat { CTFontGetLeading(font.resolve(in: fontContext).ctFont) }

    private var font: Font {
        switch node.type {
        case "heading": return HeadingView.font(level: node.int("level") ?? 1)
        case "detailsSummary": return .body.weight(.medium)
        default: return paragraphFont ?? .body
        }
    }

    private var align: TextAlign? { node.string("textAlign").flatMap(TextAlign.init(rawValue:)) }
    private var indent: CGFloat { CGFloat(min(max(node.int("indent") ?? 0, 0), 8)) * 24 }
    private var headingTop: CGFloat { node.type == "heading" && (node.int("level") ?? 1) <= 2 ? 8 : 0 }

    var body: some View {
        if isEditing {
            let isActive = model.active?.ref == ref
            VStack(alignment: .leading, spacing: 6) {
                if PageEditor.editsInBlock(voiceOver: voiceOver) {
                    ActiveTextEditor(model: model, ref: ref, font: font)
                        // Its own height, not the row's: beside a checkbox it took the checkbox's.
                        .fixedSize(horizontal: false, vertical: true)
                        // The text view puts the font's leading below every line, the reader only between lines:
                        // without the last one the editor is as tall as the reader's text, so the blocks below don't move.
                        .padding(.bottom, -fontLeading)
                        .multilineTextAlignment(align.textAlignment)
                } else {
                    // The page's one editor (`PageEditor`) lies on this text: hidden, it keeps the block's place and
                    // size as the reader would show the text (the editor draws it the same), and tells the editor where
                    // to lie. An empty text gets a space's height, as in the reader.
                    Text(model.activeText.characters.isEmpty ? AttributedString(" ") : model.activeText)
                        .font(font)
                        .multilineTextAlignment(align.textAlignment)
                        .frame(maxWidth: .infinity, alignment: align.frameAlignment)
                        .frame(height: model.editorHeight?.ref == ref ? model.editorHeight?.height : nil, alignment: .top)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DocumentModel.documentSpace)) } action: { frame in
                            if model.active?.ref == ref { model.editorFrame = (ref, frame) }
                        }
                }
                if isActive, model.showsInsertMenu {
                    InsertMenuView(model: model)
                } else if isActive, model.mentionQuery != nil {
                    MentionMenuView(model: model)
                }
            }
            .padding(.leading, indent)
            .padding(.top, headingTop)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DocumentModel.documentSpace)) } action: { frame in
                if model.active?.ref == ref { model.activeBlockFrame = frame }
            }
            .onChange(of: EditorStyle(font: font, leading: fontLeading, alignment: align.textAlignment), initial: true) { _, style in
                guard model.active?.ref == ref else { return }
                model.editorStyle = style
                model.activeFont = style.font
            }
        } else {
            let inlines = ContentParser.inlines(of: node)
            let holdsCurrentMatch = find?.currentMatch?.ref == ref
            Group {
                if inlines.isEmpty {
                    Text(" ")
                } else {
                    Text(displayed(inlines))
                }
            }
            .font(font)
            .loadsLinkPreviews(for: inlines)
            .multilineTextAlignment(align.textAlignment)
            .frame(maxWidth: .infinity, alignment: align.frameAlignment)
            .padding(.leading, indent)
            .padding(.top, headingTop)
            // Report the frame while this block holds the current find match (the page scrolls there).
            .onGeometryChange(for: CGRect?.self) { holdsCurrentMatch ? $0.frame(in: .named(DocumentModel.documentSpace)) : nil } action: { frame in
                if let frame { find?.currentFrame = (ref, frame) }
            }
            .textSelection(.enabled)
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { tapped(at: $0.location) })
            .modifier(LongPressPlacesCaret(model: model) { location in
                model.activate(ref, node: node, cursor: .point(caretPoint(location)))
            })
            // A transform, not `@Environment`: the page renews its action each edit, which would rebuild every block.
            .transformEnvironment(\.openURL) { openURL in
                let page = openURL
                openURL = OpenURLAction { url in
                    model.linkTapped = (ref, .now)
                    page(url)
                    return .handled
                }
            }
            .accessibilityAddTraits(node.type == "heading" ? .isHeader : [])
            .accessibilityHint(model.isEditable ? Text("Double tap to edit") : Text(""))
        }
    }

    /// Text as in the reader, with find matches highlighted.
    private func displayed(_ inlines: [Inline]) -> AttributedString {
        // Editable: tapping a status or math atom opens its sheet (link carries block and atom index).
        var builder = InlineTextBuilder(baseURL: context.baseURL, font: font, previewTitle: { linkPreviews?.preview(for: $0)?.title })
        if model.isEditable { builder.atomLinkBlock = ref.identity }
        var text = builder.attributedString(for: inlines)
        if let find { FindMatcher.highlight(&text, find: find, ref: ref) }
        return text
    }

    /// `location`: in this view, whose text starts after the indent and the heading's top padding.
    private func tapped(at location: CGPoint) {
        // A link tap sets `linkTapped`: don't also activate the editor. Only a link of this block opened just now
        // counts: one opened without a tap (VoiceOver rotor, keyboard) or late must not swallow a later tap.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            if let link = model.linkTapped, link.ref == ref, link.at.timeIntervalSinceNow > -1 {
                model.linkTapped = nil
                return
            }
            // The caret goes where the finger was, as on the web. VoiceOver taps the block's center: the end fits better.
            if model.isEditable {
                model.activate(ref, node: node, cursor: UIAccessibility.isVoiceOverRunning ? .end : .point(caretPoint(location)))
            }
        }
    }

    /// `location` in this view relative to its text, which starts after the indent and the heading's top padding.
    private func caretPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - indent, y: location.y - headingTop)
    }
}

/// While a block is edited, a long press on another text puts the caret where the finger was, as a long press in a text
/// does (in the edited one, the text view itself shows the magnifier). Blocks aren't dragged then (`BlockDragModifier`).
private struct LongPressPlacesCaret: ViewModifier {
    let model: DocumentModel
    let place: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content.gesture(
            LongPressGesture(minimumDuration: 0.3).sequenced(before: DragGesture(minimumDistance: 0))
                .onEnded { value in
                    if case .second(true, let drag?) = value { place(drag.location) }
                },
            including: model.hasActiveBlock ? .all : .subviews
        )
    }
}

// MARK: - Lists

/// A bullet or numbered list. The items of a list on the page's top level are elements of their own
/// (`DocumentModel.elements`): each moves by long-press and drag, as the web's handle takes each item. The "…" at the
/// list's top right is the whole list's (`BlockDragModifier`).
struct ListNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @Environment(\.listDepth) private var depth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(NodeEntry.entries(node.children, parentPath: ref.path)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index: item.ref.path.last ?? 0))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                        .accessibilityHidden(true)
                    NodeListView(model: model, nodes: item.node.children, parentPath: item.ref.path, spacing: 6)
                        .environment(\.listDepth, depth + 1)
                        .movesAsElement(item, of: ref, model: model)
                        // The first item's text ends before the list's "…".
                        .clearOfBlockActions(applies: item.ref.path.last == 0)
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : 4)
    }

    private func marker(index: Int) -> String {
        if node.type == "orderedList" {
            return "\(ContentParser.listStart(of: node) + index)."
        }
        return ListBlockView.bullet(depth: depth)
    }
}

/// A checklist as on the web: a row per item, no card around them. Its items are elements of their own on the page's
/// top level, and its "…" is the whole list's, as a bullet list's (`ListNodeView`).
struct TaskListNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @Environment(\.listDepth) private var depth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(NodeEntry.entries(node.children, parentPath: ref.path)) { item in
                let checked = item.node.bool("checked") == true
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button {
                        Task { await model.toggleTask(itemPath: item.ref.path) }
                    } label: {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isEditable)
                    .accessibilityLabel(checked ? "Completed" : "Not completed")
                    NodeListView(model: model, nodes: item.node.children, parentPath: item.ref.path, spacing: 6)
                        .environment(\.listDepth, depth + 1)
                        .foregroundStyle(checked ? .secondary : .primary)
                        .movesAsElement(item, of: ref, model: model)
                        // The first item's text ends before the list's "…".
                        .clearOfBlockActions(applies: item.ref.path.last == 0)
                }
            }
        }
    }
}

private extension View {
    /// An item's blocks, beside its bullet, number or checkbox, move the item of a top-level list `list` by long-press
    /// and drag and take drops (`BlockMoveModifier`). On them, not on the whole row: as a drag's source, the row gave its
    /// frame to the text for accessibility, the list's "…" included, and a tap at the text's end met the "…".
    @ViewBuilder
    func movesAsElement(_ item: NodeEntry, of list: NodeRef, model: DocumentModel) -> some View {
        if list.isTopLevel {
            modifier(BlockMoveModifier(model: model, entry: item))
        } else {
            self
        }
    }
}

// MARK: - Containers

struct CalloutNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef

    /// Missing or unknown type is info, as in the schema, web and reader.
    var kind: CalloutKind { node.string("type").flatMap(CalloutKind.init(rawValue:)) ?? .info }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.activeAncestorPath(ofType: "callout") == ref.path {
                CalloutTypeBar(model: model, path: ref.path, current: kind)
            }
            HStack(alignment: .top, spacing: 10) {
                if let icon = node.string("icon"), !icon.isEmpty {
                    Text(icon).font(.title3)
                } else {
                    Image(systemName: kind.symbol)
                        .font(.title3)
                        .foregroundStyle(kind.tint)
                }
                NodeListView(model: model, nodes: node.children, parentPath: ref.path)
                    .clearOfBlockActions(inset: 12)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(kind.tint.opacity(0.25)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("\(String(localized: kind.title)) callout"))
        }
    }
}

struct ToggleNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @State private var isExpanded: Bool

    init(model: DocumentModel, node: PMNode, ref: NodeRef) {
        self.model = model
        self.node = node
        self.ref = ref
        self._isExpanded = State(initialValue: model.readerToggles[ref.path] ?? node.bool("open") ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    if model.isEditable {
                        // Stored in the document like on the web; the view follows it below.
                        Task { await model.setAttributes(of: NodeRef(path: ref.path, id: nil), ["open": .bool(!isExpanded)]) }
                    } else {
                        withAnimation(.snappy) { isExpanded.toggle() }
                        // Find on page searches what the reader sees.
                        model.readerToggles[ref.path] = isExpanded
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
                if let summary = node.children.first {
                    NodeView(model: model, node: summary, ref: NodeRef(path: ref.path + [0], node: summary))
                        .clearOfBlockActions()
                }
            }
            if isExpanded {
                // Numbered before dropping the summary: content starts at index 1, and edits address blocks by path.
                ForEach(NodeEntry.entries(node.children, parentPath: ref.path).dropFirst()) { entry in
                    NodeView(model: model, node: entry.node, ref: entry.ref)
                }
                .padding(.leading, 30)
                // Below the title's row, where the toggle's "…" is: a list or code block there keeps no room for it.
                .environment(\.showsBlockActions, false)
            }
        }
        // No card around it, as on the web: the arrow and the indented content show what belongs to it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Editable pages follow the stored state, also a collaborator's; read-only pages keep their own (web parity).
        .onChange(of: model.isEditable ? node.bool("open") ?? false : nil) { _, open in
            if let open { withAnimation(.snappy) { isExpanded = open } }
            // Closed with the cursor inside: editing ends, as the content's editor used to vanish with it.
            if open == false, let active = model.active?.ref.path, active.starts(with: ref.path + [1]) { model.deactivate() }
        }
    }
}

// MARK: - Code

struct CodeNodeView: View {
    @Bindable var model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @Environment(\.pageFind) private var find
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var copied = false

    private static let codeFont = Font.system(.callout, design: .monospaced)
    private var isActive: Bool { model.active?.ref == ref }
    private var code: String { isActive ? model.activeCode : node.plainText }

    /// Code as in the reader, in its syntax colors (`colored`), with find matches highlighted.
    private func displayed(_ colored: AttributedString) -> AttributedString {
        var text = code.isEmpty ? AttributedString(" ") : colored
        if let find { FindMatcher.highlight(&text, find: find, ref: ref) }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActive {
                CodeLanguageBar(model: model, path: ref.path, current: node.string("language"))
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                if let language = node.string("language"), !language.isEmpty {
                    Chip(text: language)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            // "Copy" stays beside the block's "…", which a code block not being edited shows.
            .clearOfBlockActions(inset: 12)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if isActive {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if PageEditor.editsInBlock(voiceOver: voiceOver) {
                            ActiveTextEditor(model: model, ref: ref, font: Self.codeFont, isCode: true)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            // The page's one editor lies on this code, as on a text block's text (`TextNodeView`).
                            Text(code.isEmpty ? " " : code)
                                .font(Self.codeFont)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: model.editorHeight?.ref == ref ? model.editorHeight?.height : nil, alignment: .top)
                                .hidden()
                                .accessibilityHidden(true)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DocumentModel.documentSpace)) } action: { frame in
                                    if isActive { model.editorFrame = (ref, frame) }
                                }
                        }
                    }
                    // Where the code block's own editor drew the code: inside its 8 pt padding and its text view's
                    // insets (8 pt vertical, 5 pt horizontal), at least 60 pt tall with them.
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .onChange(of: EditorStyle(font: Self.codeFont, leading: CTFontGetLeading(Self.codeFont.resolve(in: fontContext).ctFont),
                                              alignment: .leading, isCode: true), initial: true) { _, style in
                        if isActive { model.editorStyle = style }
                    }
                    // "+" from the keyboard toolbar: insert menu below the code (inserts after the block).
                    if isActive, model.showsPlusMenu {
                        InsertMenuView(model: model)
                            .padding([.horizontal, .bottom], 8)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DocumentModel.documentSpace)) } action: { frame in
                    if isActive { model.activeBlockFrame = frame }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(0..<max(lines.count, 1), id: \.self) { index in
                                Text("\(index + 1)")
                            }
                        }
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        // Colored when it isn't being edited: the page's one editor shows its text in one color.
                        HighlightedCode(code: code, language: node.string("language")) { colored in
                            Text(displayed(colored))
                                .font(.system(.callout, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(12)
                }
                .contentShape(Rectangle())
                .onTapGesture { if model.isEditable { model.activate(ref, node: node) } }
                .onGeometryChange(for: CGRect?.self) { [holdsCurrentMatch = find?.currentMatch?.ref == ref] in
                    holdsCurrentMatch ? $0.frame(in: .named(DocumentModel.documentSpace)) : nil
                } action: { frame in
                    if let frame { find?.currentFrame = (ref, frame) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Table

struct TableNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @State private var showsActions = false

    private var isActive: Bool { model.activeTablePosition?.tablePath == ref.path }

    var body: some View {
        let grid = TableGrid(table: node)
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 4) {
                TableGridLayout {
                    ForEach(Array(NodeEntry.entries(node.children, parentPath: ref.path).enumerated()), id: \.element.id) { rowIndex, row in
                        ForEach(Array(NodeEntry.entries(row.node.children, parentPath: row.ref.path).enumerated()), id: \.element.id) { cellIndex, cell in
                            TableCellNodeView(model: model, cell: cell)
                                .layoutValue(key: TableCellArea.self, value: grid.areas[rowIndex][cellIndex])
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // While a cell is edited, the keyboard toolbar has the table's actions.
                if model.isEditable, !isActive {
                    BlockActionsButton {
                        model.deactivate()
                        showsActions = true
                    }
                    .confirmationDialog("Block", isPresented: $showsActions, titleVisibility: .hidden) {
                        Button("Duplicate") { Task { await model.duplicate(ref) } }
                        Button("Delete", role: .destructive) { Task { await model.delete(ref) } }
                    }
                }
            }
        }
    }
}

private struct TableCellNodeView: View {
    let model: DocumentModel
    let cell: NodeEntry

    private var isHeader: Bool { cell.node.type == "tableHeader" }
    private var width: CGFloat? {
        guard let widths = cell.node.attr("colwidth")?.arrayValue?.compactMap(\.doubleValue), !widths.isEmpty else { return nil }
        let total = widths.reduce(0, +)
        return total > 0 ? CGFloat(total) : nil
    }

    var body: some View {
        TableCellWidth(fixed: width) {
            NodeListView(model: model, nodes: cell.node.children, parentPath: cell.ref.path, spacing: 4)
                .environment(\.paragraphFont, isHeader ? .body.bold() : nil)
                .padding(8)
        }
        // Cells stretch to the column's widest and the row's tallest so borders line up with multi-line cells.
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: .infinity, alignment: .topLeading)
        .background(TableCellView.background(name: cell.node.string("backgroundColorName"), hex: cell.node.string("backgroundColor"), isHeader: isHeader))
        .border(Color(.separator), width: 0.5)
    }
}
