import SwiftUI
import DocmostKit

/// Editor keyboard toolbar. No pop-up menus (on device they hide behind the keyboard): "Block type", "Alignment",
/// "Color" and, in a table, "Table" swap in a row of buttons, "+" opens the insert menu below the block (as "/" does).
struct EditorToolbar: View {
    private enum Mode { case main, blockType, alignment, color, table, tableFormat }

    @Bindable var model: DocumentModel
    @State private var mode: Mode = .main
    @State private var confirmsDelete = false
    @State private var confirmsTableDelete = false
    /// What the table format row's colors, alignments and "Clear" change.
    @State private var formatScope = DocumentModel.TableScope.cell

    private var isCode: Bool { model.active?.type == "codeBlock" }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    switch mode {
                    case .main: mainRow
                    case .blockType: blockTypeRow
                    case .alignment: alignmentRow
                    case .color: colorRow
                    case .table: tableRow
                    case .tableFormat: tableFormatRow
                    }
                }
                .padding(.horizontal, 4)
            }
            // Each row starts at its beginning ("Back" first), not where the last one was scrolled to.
            .id(mode)
            iconButton("Done", "keyboard.chevron.compact.down", id: "editor-done") { model.deactivate() }
                .padding(.leading, 6)
        }
        // The table rows stay while the cursor goes from cell to cell, as their actions move it to new rows and columns.
        .onChange(of: model.active) { _, _ in
            if mode == .blockType || mode == .color || model.activeTablePosition == nil { mode = .main }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var mainRow: some View {
        // A toggle title or footnote text can't change type or be copied alone (see `conversionTemplates`).
        let isFixedPart = model.conversionTemplates.isEmpty
        let inFootnote = model.active.map { model.insertLocation(of: $0) } == .footnote
        if !isFixedPart {
            modeButton(title: currentTypeTitle, id: "editor-block-type") { mode = .blockType }
        }
        if model.activeTablePosition != nil {
            iconButton("Table", "tablecells", id: "editor-table") { mode = .table }
        }
        iconButton("Insert block", "plus", id: "editor-insert", active: model.showsPlusMenu) { model.togglePlusMenu() }
        // In a list item, as Shift-Tab and Tab on the web: the item one level out or in.
        if model.isInListItem {
            let levels = model.activeItemLevels
            iconButton("Outdent", "decrease.indent", id: "editor-outdent") { Task { await model.moveActiveItemLevel(inward: false) } }
                .disabled(levels?.outdent != true)
            iconButton("Indent", "increase.indent", id: "editor-indent") { Task { await model.moveActiveItemLevel(inward: true) } }
                .disabled(levels?.indent != true)
        }
        divider
        Group {
            iconButton("Bold", "bold", id: "format-bold", active: hasIntent(.stronglyEmphasized)) { toggleIntent(.stronglyEmphasized) }
            iconButton("Italic", "italic", id: "format-italic", active: hasIntent(.emphasized)) { toggleIntent(.emphasized) }
            iconButton("Underline", "underline", id: "format-underline", active: isUnderlined) { toggleUnderline() }
            iconButton("Strikethrough", "strikethrough", id: "format-strike", active: isStruck) { toggleStrikethrough() }
            // Inline code sits with the formats, as on the web.
            iconButton("Inline code", "chevron.left.forwardslash.chevron.right", id: "format-code", active: isCodeFormatted) { toggleCode() }
        }
        .disabled(isCode)
        // Like "/code"; footnotes hold only paragraphs, so they don't offer it.
        if !inFootnote {
            iconButton("Code block", "curlybraces.square", id: "editor-code-block", active: isCode) { toggleCodeBlock() }
        }
        Group {
            iconButton("Highlight", "highlighter", id: "format-highlight", active: isHighlighted) { toggleHighlight() }
            iconButton("Color", "paintpalette", id: "format-color", active: hasTextColor) { mode = .color }
            iconButton("Link", "link", id: "format-link", active: isActive { $0.link != nil }) { model.editsLink = true }
            iconButton("Line break", "return", id: "format-linebreak") { model.insertLineBreak() }
        }
        .disabled(isCode)
        // After the formats, which are used more and stay on the first screen of an iPhone's toolbar.
        if !model.isInListItem, let steps = model.activeIndentSteps {
            // In a paragraph or heading, as Shift-Tab and Tab on the web (Docmost's Indent): a step out or in.
            iconButton("Outdent", "decrease.indent", id: "editor-block-outdent") { Task { await model.indentActive(inward: false) } }
                .disabled(!steps.outdent)
            iconButton("Indent", "increase.indent", id: "editor-block-indent") { Task { await model.indentActive(inward: true) } }
                .disabled(!steps.indent)
        }
        if model.alignsActiveBlock {
            iconButton("Alignment", model.activeAlignment.symbol, id: "editor-alignment") { mode = .alignment }
                .accessibilityValue(Text(model.activeAlignment.title))
        }
        // Like "Comment" in the selection menu.
        if model.canComment {
            iconButton("Comment", "text.bubble", id: "format-comment") { model.editsComment = true }
                .disabled(!model.canCommentOnSelection)
        }
        divider
        iconButton("Undo", "arrow.uturn.backward", id: "editor-undo") { Task { await model.undo() } }
        iconButton("Redo", "arrow.uturn.forward", id: "editor-redo") { Task { await model.redo() } }
        divider
        if !isFixedPart {
            iconButton("Duplicate", "plus.square.on.square", id: "editor-duplicate") {
                guard let ref = model.active?.ref else { return }
                Task { await model.duplicate(ref) }
            }
        }
        iconButton("Delete", "trash", id: "editor-delete") { confirmsDelete = true }
            // On the button: iOS shows the confirmation as a popover from the view it's attached to.
            .confirmationDialog("Delete this block?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let ref = model.active?.ref else { return }
                    Task { await model.delete(ref) }
                }
            }
    }

    @ViewBuilder
    private var blockTypeRow: some View {
        iconButton("Back", "chevron.left", id: "editor-back") { mode = .main }
        divider
        ForEach(model.conversionTemplates) { template in
            iconButton(template.titleResource, template.symbol, id: "type-\(template.rawValue)") {
                mode = .main
                model.convertActive(to: template)
            }
        }
        // Like the web's "Turn into → Synced block": the block becomes a synced block's source.
        if model.active?.ref.isTopLevel == true {
            iconButton("Synced block", "arrow.triangle.2.circlepath", id: "type-synced-block") {
                mode = .main
                Task { await model.wrapActiveInSyncedBlock() }
            }
        }
    }

    /// As the web's alignment menu: left, center, right. Justified text shows left-aligned in the app (BACKLOG), so it isn't
    /// offered; a justified block shows none of the three as chosen.
    @ViewBuilder
    private var alignmentRow: some View {
        iconButton("Back", "chevron.left", id: "editor-back") { mode = .main }
        divider
        alignButton(.left, "Align left")
        alignButton(.center, "Align center")
        alignButton(.right, "Align right")
    }

    private func alignButton(_ align: TextAlign, _ title: LocalizedStringResource) -> some View {
        iconButton(title, align.symbol, id: "align-\(align.rawValue)", active: model.activeAlignment == align) {
            mode = .main
            Task { await model.alignActive(align) }
        }
    }

    /// As the web's color menu: its text colors, then its highlights, each with "Default" taking the color away. Like the
    /// format buttons, a color applies to the selection, or to what is typed next.
    @ViewBuilder
    private var colorRow: some View {
        iconButton("Back", "chevron.left", id: "editor-back") { mode = .main }
        divider
        textColorButton(nil)
        ForEach(EditorText.textColors, id: \.name) { textColorButton((key: $0.name, value: $0.hex)) }
        divider
        highlightButton(nil)
        ForEach(HighlightColors.names, id: \.self) { highlightButton($0) }
    }

    /// "A" in the color (`name`/`hex` of `TextColors`), as the web's swatches; none for "Default".
    private func textColorButton(_ color: (key: String, value: String)?) -> some View {
        let shown = color.flatMap { Color(hex: $0.value) }
        let active = shown.map { shown in isActive { $0.foregroundColor == shown } } ?? false
        return toolbarChoice(active: active) {
            EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { EditorText.setTextColor(color?.value, in: &$0) }
            mode = .main
        } label: {
            Text(verbatim: "A")
                .font(.body.weight(.semibold))
                .foregroundStyle(shown ?? Color.primary)
        }
        .accessibilityLabel(Text(EditorText.colorTitle(color?.key)))
        .accessibilityHint(Text("Text color"))
        .accessibilityIdentifier("text-color-\(color?.key ?? "default")")
    }

    /// A swatch in the highlight's color (`HighlightColors`); none for "Default".
    private func highlightButton(_ name: String?) -> some View {
        // Also a highlight stored by its hex alone, which shows in a color of its own.
        let active = name.map { name in
            isActive { $0.backgroundColor == EditorText.highlightColor(name) || $0.docmost.highlight?.lowercased() == HighlightColors.hex(for: name) }
        } ?? false
        return toolbarChoice(active: active) {
            EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { EditorText.setHighlight(named: name, in: &$0) }
            mode = .main
        } label: {
            if let name {
                Circle()
                    .fill(EditorText.highlightColor(name))
                    .overlay(Circle().strokeBorder(Color(.separator)))
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "circle.slash")
            }
        }
        .accessibilityLabel(Text(EditorText.colorTitle(name)))
        .accessibilityHint(Text("Highlight color"))
        .accessibilityIdentifier("highlight-color-\(name ?? "default")")
    }

    /// The table's actions on the cell being edited, as in the web's table menus. Merging goes cell by cell (the app
    /// has no cell selection); colors, alignment and "Clear" have a row of their own.
    @ViewBuilder
    private var tableRow: some View {
        let table = model.activeTableState ?? DocumentModel.TableState()
        iconButton("Back", "chevron.left", id: "editor-back") { mode = .main }
        divider
        tableButton("Add row above", "arrow.up.to.line", id: "table-insert-row-above", .insertRowAbove)
        tableButton("Add row below", "arrow.down.to.line", id: "table-insert-row-below", .insertRowBelow)
        tableButton("Add column left", "arrow.left.to.line", id: "table-insert-column-left", .insertColumnLeft)
        tableButton("Add column right", "arrow.right.to.line", id: "table-insert-column-right", .insertColumnRight)
        divider
        iconButton("Color and alignment", "paintpalette", id: "table-format") {
            formatScope = .cell
            mode = .tableFormat
        }
        divider
        tableButton("Header row", "rectangle.topthird.inset.filled", id: "table-header-row", .toggleHeaderRow, active: table.headerRow)
        tableButton("Header column", "rectangle.leadingthird.inset.filled", id: "table-header-column", .toggleHeaderColumn,
                    active: table.headerColumn)
        tableButton("Header cell", "rectangle.inset.filled", id: "table-header-cell", .toggleHeaderCell, active: table.headerCell)
        divider
        tableButton("Merge with the cell to the right", "arrow.right.and.line.vertical.and.arrow.left", id: "table-merge-right", .mergeRight)
            .disabled(!table.canMergeRight)
        tableButton("Merge with the cell below", "arrow.down.and.line.horizontal.and.arrow.up", id: "table-merge-down", .mergeDown)
            .disabled(!table.canMergeDown)
        tableButton("Split cell", "square.split.2x2", id: "table-split", .split)
            .disabled(!table.canSplit)
        divider
        tableButton("Move row up", "arrow.up.square", id: "table-move-row-up", .moveRowUp)
            .disabled(!table.canMoveRowUp)
        tableButton("Move row down", "arrow.down.square", id: "table-move-row-down", .moveRowDown)
            .disabled(!table.canMoveRowDown)
        tableButton("Move column left", "arrow.left.square", id: "table-move-column-left", .moveColumnLeft)
            .disabled(!table.canMoveColumnLeft)
        tableButton("Move column right", "arrow.right.square", id: "table-move-column-right", .moveColumnRight)
            .disabled(!table.canMoveColumnRight)
        tableButton("Sort A → Z", "chart.bar.xaxis.ascending", id: "table-sort-ascending", .sort(descending: false))
            .disabled(!table.canSort)
        tableButton("Sort Z → A", "chart.bar.xaxis.descending", id: "table-sort-descending", .sort(descending: true))
            .disabled(!table.canSort)
        divider
        tableButton("Delete row", "minus.rectangle", id: "table-delete-row", .deleteRow)
        tableButton("Delete column", "minus.rectangle.portrait", id: "table-delete-column", .deleteColumn)
        iconButton("Delete table", "trash", id: "table-delete") { confirmsTableDelete = true }
            .confirmationDialog("Delete this table?", isPresented: $confirmsTableDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await model.editTable(.deleteTable) } }
            }
    }

    /// Colors, alignment and "Clear" for the cell, its row or its column.
    @ViewBuilder
    private var tableFormatRow: some View {
        let table = model.activeTableState ?? DocumentModel.TableState()
        // Of the cell: its row or column can have several.
        let shows = formatScope == .cell
        iconButton("Back", "chevron.left", id: "editor-back") { mode = .table }
        divider
        scopeButton("Cell", .cell)
        scopeButton("Row", .row)
        scopeButton("Column", .column)
        divider
        ForEach(DocumentModel.TableColor.allCases, id: \.self) { color in
            colorButton(color, active: shows && table.color == color)
        }
        divider
        tableButton("Align left", TextAlign.left.symbol, id: "table-align-left", .align(.left, formatScope), active: shows && table.align == .left)
        tableButton("Align center", TextAlign.center.symbol, id: "table-align-center", .align(.center, formatScope), active: shows && table.align == .center)
        tableButton("Align right", TextAlign.right.symbol, id: "table-align-right", .align(.right, formatScope), active: shows && table.align == .right)
        divider
        tableButton("Clear", "eraser", id: "table-clear", .clear(formatScope))
    }

    private var divider: some View {
        Divider().frame(height: 20)
    }

    private func tableButton(_ title: LocalizedStringResource, _ symbol: String, id: String, _ edit: DocumentModel.TableEdit,
                             active: Bool = false) -> some View {
        iconButton(title, symbol, id: id, active: active) { Task { await model.editTable(edit) } }
    }

    private func scopeButton(_ title: LocalizedStringResource, _ scope: DocumentModel.TableScope) -> some View {
        toolbarChoice(active: formatScope == scope) { formatScope = scope } label: {
            TableScopeIcon(scope: scope)
        }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("table-scope-\(scope.rawValue)")
    }

    /// A swatch in the color the cell shows (`TableCellView.background`).
    private func colorButton(_ color: DocumentModel.TableColor, active: Bool) -> some View {
        toolbarChoice(active: active) { Task { await model.editTable(.background(color, formatScope)) } } label: {
            if color == .none {
                Image(systemName: "circle.slash")
            } else {
                Circle()
                    .fill(HighlightPalette.color(name: color.name, hex: color.hex))
                    .overlay(Circle().strokeBorder(Color(.separator)))
                    .frame(width: 20, height: 20)
            }
        }
        .accessibilityLabel(Text(color.title))
        .accessibilityIdentifier("table-color-\(color.rawValue)")
    }

    /// All toolbar symbols in the same regular weight (the toolbar would draw them bolder).
    private func iconButton(_ title: LocalizedStringResource, _ symbol: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        toolbarChoice(active: active, action: action) {
            Image(systemName: symbol)
                .fontWeight(active ? .semibold : .regular)
        }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(id)
    }

    /// The toolbar's square button, tinted while what it stands for applies (a format, a color, a scope). One place, so
    /// that every button shows it, and tells VoiceOver it's selected, the same way.
    private func toolbarChoice<Label: View>(active: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: 30, height: 30)
                .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func modeButton(title: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Block type")
        // What the button shows: the label alone told VoiceOver nothing of the block's type.
        .accessibilityValue(Text(title))
        .accessibilityIdentifier(id)
    }

    // MARK: - Block type

    private var currentTypeTitle: LocalizedStringKey {
        switch model.active?.type {
        case "heading":
            switch model.active?.attrs?["level"]?.intValue ?? 1 {
            case 1: return "H1"
            case 2: return "H2"
            default: return "H3"
            }
        case "codeBlock": return "Code"
        default:
            if model.active?.itemPath != nil { return "List" }
            return "Text"
        }
    }

    // MARK: - Formats

    private func isActive(_ check: (AttributeContainer) -> Bool) -> Bool { model.activeTextHas(check) }

    /// Bold and italic, also from Cmd-B and Cmd-I (`EditorText.fontIntents`).
    private func hasIntent(_ intent: InlinePresentationIntent) -> Bool {
        isActive { ($0.inlinePresentationIntent ?? []).union(EditorText.fontIntents($0.font, base: model.activeFont)).contains(intent) }
    }

    private func toggleIntent(_ intent: InlinePresentationIntent) {
        let enabled = hasIntent(intent)
        let base = model.activeFont
        EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { EditorText.setIntent(intent, !enabled, in: &$0, base: base) }
    }

    // Underline, strikethrough, code and highlight also set SwiftUI attributes that survive typing (`EditorText`), both
    // sides together. Underline and strikethrough count only the visible style, like saving (`EditorText.normalized`).

    private var isUnderlined: Bool { isActive { $0.underlineStyle != nil } }
    private var isStruck: Bool { model.activeTextIsStruck }
    private var isCodeFormatted: Bool { model.activeTextIsCode }
    /// A text color across the selection (or for what is typed next): a stored one, or one of the web's typed text shows.
    private var hasTextColor: Bool {
        isActive { attributes in
            attributes.docmost.inlineNode == nil
                && (attributes.docmost.textColor != nil || EditorText.textColors.contains { $0.color == attributes.foregroundColor })
        }
    }
    private var isHighlighted: Bool { model.activeTextIsHighlighted }

    private func toggleUnderline() {
        let enabled = isUnderlined
        EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { container in
            container.docmost.underline = enabled ? nil : true
            container.underlineStyle = enabled ? nil : .single
        }
    }

    private func toggleStrikethrough() { model.toggleStrikethrough() }

    /// Like "/code": block to code block (keeping its text), code block back to paragraph. Where the line can't become
    /// one (an item's first line, a toggle's title, …), inserts one after the enclosing block.
    private func toggleCodeBlock() {
        guard let active = model.active else { return }
        if active.type == "codeBlock" {
            Task { await model.convert(active.ref, to: .paragraph) }
        } else if model.conversionTemplates.contains(.codeBlock) {
            Task { await model.convert(active.ref, to: .codeBlock) }
        } else {
            Task { await model.insertTemplate(.codeBlock, placement: .afterTopLevel(active.ref)) }
        }
    }

    private func toggleCode() { model.toggleInlineCode() }

    private func toggleHighlight() { model.toggleHighlight() }
}

/// A 3 × 3 grid with the scope's part filled: the middle cell, row or column.
private struct TableScopeIcon: View {
    let scope: DocumentModel.TableScope

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 1.5
            let side = (min(size.width, size.height) - 2 * gap) / 3
            for row in 0..<3 {
                for column in 0..<3 {
                    let rect = CGRect(x: CGFloat(column) * (side + gap), y: CGFloat(row) * (side + gap), width: side, height: side)
                    let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1)
                    let filled = switch scope {
                    case .cell: row == 1 && column == 1
                    case .row: row == 1
                    case .column: column == 1
                    }
                    if filled {
                        context.fill(path, with: .foreground)
                    } else {
                        context.stroke(path, with: .foreground, lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Adds, edits or removes a link: on the selection, on the link under the cursor, or as new text.
struct LinkSheet: View {
    @Bindable var model: DocumentModel
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var pageQuery = ""
    @State private var pages: [MentionSuggestion] = []
    /// Captured on open: once the address field has focus, the editor no longer has it.
    @State private var target: Target?

    /// Range the link applies to: the selection or the whole link under the cursor.
    static func target(
        in text: AttributedString, selection: AttributedTextSelection
    ) -> (range: Range<AttributedString.Index>?, insertionPoint: AttributedString.Index?) {
        switch selection.indices(in: text) {
        case .ranges(let ranges):
            return (ranges.ranges.first.map { $0.lowerBound..<(ranges.ranges.last?.upperBound ?? $0.upperBound) }, nil)
        case .insertionPoint(let index):
            // Runs by link only: a link whose text is partly bold or highlighted is several attribute runs.
            let link = text.runs[\.link].first { url, range in
                url != nil && (range.contains(index) || range.upperBound == index)
            }
            return (link?.1, index)
        }
    }

    /// What the sheet links (`target(in:selection:)`), in characters of the block's text it opened on, as the comment
    /// sheet keeps its passage. Indices of that text don't fit another: a Return or Backspace still on its way to the
    /// engine makes another block active while the sheet is open, and Apply then inserted past the new text's end (a
    /// crash) or linked other text.
    struct Target {
        /// The block (`NodeRef.identity`) and its text.
        let block: String
        let characters: String
        let range: Range<Int>?
        let insertionPoint: Int?

        init?(block: String?, text: AttributedString, selection: AttributedTextSelection) {
            guard let block else { return nil }
            let (range, insertionPoint) = LinkSheet.target(in: text, selection: selection)
            let offset = { text.characters.distance(from: text.startIndex, to: $0) }
            self.block = block
            characters = String(text.characters)
            self.range = range.map { offset($0.lowerBound)..<offset($0.upperBound) }
            self.insertionPoint = insertionPoint.map(offset)
        }

        /// The target's indices in `text`, the active text of `block`: nil once another block is active or its text
        /// changed. A format change keeps it.
        func indices(
            in text: AttributedString, of block: String?
        ) -> (range: Range<AttributedString.Index>?, insertionPoint: AttributedString.Index?)? {
            guard block == self.block, String(text.characters) == characters else { return nil }
            let index = { text.characters.index(text.startIndex, offsetBy: $0) }
            return (range.map { index($0.lowerBound)..<index($0.upperBound) }, insertionPoint.map(index))
        }
    }

    /// The target in the active text as it is now: nil before the sheet appeared and once that text is gone. Everything
    /// reads it, the body too: the body shows the new text before `onChange` closes the sheet.
    private var current: (range: Range<AttributedString.Index>?, insertionPoint: AttributedString.Index?)? {
        target?.indices(in: model.activeText, of: model.active?.ref.identity)
    }

    /// The text the sheet opened on is gone: the sheet closes without a change.
    private var targetIsGone: Bool { target != nil && current == nil }

    private var existingLink: URL? {
        guard let range = current?.range else { return nil }
        return model.activeText[range].runs.first?.link
    }

    /// The whole link the sheet edits (a selection may cover part of it): what becomes a card or mention.
    private var wholeLink: Range<AttributedString.Index>? {
        guard let range = current?.range, let url = existingLink else { return nil }
        return model.activeText.runs[\.link].first { link, linkRange in link == url && linkRange.contains(range.lowerBound) }?.1
    }

    /// The address as it gets linked: nil while empty, with spaces, or of a kind the web doesn't link either.
    private var link: URL? {
        ContentLinkRouter.normalizedLink(address).flatMap { ContentLinkRouter.isLinkable($0) ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(apply)
                        .accessibilityIdentifier("link-address")
                } footer: {
                    if let typed = ContentLinkRouter.normalizedLink(address), !ContentLinkRouter.isLinkable(typed) {
                        Text("Only web, mail and phone addresses can be linked.")
                    } else {
                        Text(current?.range != nil ? "The link is applied to the selected text." : "Select text first to turn it into a link; otherwise the address is inserted as text.")
                    }
                }
                Section("Link to a page") {
                    TextField("Search pages", text: $pageQuery)
                        .autocorrectionDisabled()
                    ForEach(pages) { page in
                        Button {
                            if let slugId = page.slugId, let server = session.server?.url {
                                address = ContentLinkRouter.webPageURL(server: server, slugId: slugId).absoluteString
                            }
                        } label: {
                            HStack(spacing: 8) {
                                PageIconView(icon: page.icon, size: 18)
                                Text(page.title).lineLimit(1)
                                Spacer()
                                if let space = page.subtitle {
                                    Text(space).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Docmost 0.97: a link of an installed integration shows as a card or mention too, as on the web.
                if let range = wholeLink, let provider = model.integrationProvider(ofLinkIn: range) {
                    Section {
                        if model.canShowLinkAsCard(in: range) {
                            Button("Show as Card") { showLink(provider: provider, as: .card) }
                        }
                        Button("Show as Mention") { showLink(provider: provider, as: .mention) }
                    }
                }
                if existingLink != nil {
                    Button("Remove Link", role: .destructive) {
                        if let range = current?.range { model.activeText[range].link = nil }
                        dismiss()
                    }
                }
            }
            .navigationTitle("Link")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply)
                        .disabled(link == nil)
                        .accessibilityIdentifier("link-apply")
                }
            }
            .onAppear {
                target = Target(block: model.active?.ref.identity, text: model.activeText, selection: model.activeSelection)
                if let existing = existingLink { address = existing.absoluteString }
            }
            // Another block became active: a Return or Backspace was still on its way to the engine when the sheet
            // opened.
            .onChange(of: targetIsGone) { _, gone in
                if gone { dismiss() }
            }
            .task(id: pageQuery) {
                let query = pageQuery.trimmingCharacters(in: .whitespaces)
                guard !query.isEmpty, let suggest = model.dependencies.suggest else {
                    pages = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if let result = try? await suggest(query) {
                    pages = MentionSuggestion.from(result).filter { $0.kind == .page }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// With the link as it is when tapped: the button holds the range of the body that drew it.
    private func showLink(provider: String, as display: DocumentModel.IntegrationDisplay) {
        if let range = wholeLink { model.showLink(in: range, provider: provider, as: display) }
        dismiss()
    }

    private func apply() {
        guard let url = link else { return }
        // The text the sheet opened on is gone: nothing changes (the sheet is closing anyway).
        guard let current else {
            dismiss()
            return
        }
        if let range = current.range {
            model.activeText[range].link = url
        } else {
            var run = AttributedString(url.absoluteString)
            run.link = url
            let index = current.insertionPoint ?? model.activeText.endIndex
            model.activeText.transform(updating: &model.activeSelection) { text in
                text.insert(run, at: index)
            }
        }
        dismiss()
    }
}

extension TextAlign {
    /// The toolbar's symbol; "Alignment" shows the block's own, justified included.
    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justify: "text.justify"
        }
    }

    /// What VoiceOver reads as the value of "Alignment".
    var title: LocalizedStringResource {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .justify: "Justified"
        }
    }
}
