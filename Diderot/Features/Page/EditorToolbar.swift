import SwiftUI
import DocmostKit

/// Editor keyboard toolbar. No pop-up menus (on device they hide behind the keyboard): "Block type" and, in a table,
/// "Table" swap in a row of buttons, "+" opens the insert menu below the block (as "/" does).
struct EditorToolbar: View {
    private enum Mode { case main, blockType, table, tableFormat }

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
            if mode == .blockType || model.activeTablePosition == nil { mode = .main }
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
            iconButton("Link", "link", id: "format-link", active: isActive { $0.link != nil }) { model.editsLink = true }
            iconButton("Line break", "return", id: "format-linebreak") { model.insertLineBreak() }
        }
        .disabled(isCode)
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
        tableButton("Align left", "text.alignleft", id: "table-align-left", .align(.left, formatScope), active: shows && table.align == .left)
        tableButton("Align center", "text.aligncenter", id: "table-align-center", .align(.center, formatScope), active: shows && table.align == .center)
        tableButton("Align right", "text.alignright", id: "table-align-right", .align(.right, formatScope), active: shows && table.align == .right)
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
        let active = formatScope == scope
        return Button { formatScope = scope } label: {
            TableScopeIcon(scope: scope)
                .frame(width: 30, height: 30)
                .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("table-scope-\(scope.rawValue)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// A swatch in the color the cell shows (`TableCellView.background`).
    private func colorButton(_ color: DocumentModel.TableColor, active: Bool) -> some View {
        Button { Task { await model.editTable(.background(color, formatScope)) } } label: {
            Group {
                if color == .none {
                    Image(systemName: "circle.slash")
                } else {
                    Circle()
                        .fill(HighlightPalette.color(name: color.name, hex: color.hex))
                        .overlay(Circle().strokeBorder(Color(.separator)))
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: 30, height: 30)
            .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(color.title))
        .accessibilityIdentifier("table-color-\(color.rawValue)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// All toolbar symbols in the same regular weight (the toolbar would draw them bolder).
    private func iconButton(_ title: LocalizedStringResource, _ symbol: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .fontWeight(active ? .semibold : .regular)
                .frame(width: 30, height: 30)
                .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(id)
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

    /// Whether the attribute is set across the whole selection; for a bare cursor, the typing attributes count.
    private func isActive(_ check: (AttributeContainer) -> Bool) -> Bool {
        switch model.activeSelection.indices(in: model.activeText) {
        case .insertionPoint:
            return check(model.activeSelection.typingAttributes(in: model.activeText))
        case .ranges(let ranges):
            return EditorText.allFormatted(model.activeText, in: ranges, check)
        }
    }

    /// Bold and italic, also from Cmd-B and Cmd-I (`EditorText.fontIntents`).
    private func hasIntent(_ intent: InlinePresentationIntent) -> Bool {
        isActive { ($0.inlinePresentationIntent ?? []).union(EditorText.fontIntents($0.font, base: model.activeFont)).contains(intent) }
    }

    private func toggleIntent(_ intent: InlinePresentationIntent) {
        let enabled = hasIntent(intent)
        let base = model.activeFont
        EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { EditorText.setIntent(intent, !enabled, in: &$0, base: base) }
        model.activeTextChanged()
    }

    // Underline, strikethrough, code and highlight also set SwiftUI attributes that survive typing (`EditorText`), both
    // sides together. Underline and strikethrough count only the visible style, like saving (`EditorText.normalized`).

    private var isUnderlined: Bool { isActive { $0.underlineStyle != nil } }
    private var isStruck: Bool { isActive { $0.strikethroughStyle != nil } }
    private var isCodeFormatted: Bool { isActive { $0.inlinePresentationIntent?.contains(.code) == true || $0.font == EditorText.codeFont } }
    private var isHighlighted: Bool {
        isActive { $0.docmost.highlight != nil || ($0.backgroundColor != nil && $0.backgroundColor != EditorText.codeBackground) }
    }

    private func toggleUnderline() {
        let enabled = isUnderlined
        EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { container in
            container.docmost.underline = enabled ? nil : true
            container.underlineStyle = enabled ? nil : .single
        }
        model.activeTextChanged()
    }

    private func toggleStrikethrough() {
        let enabled = isStruck
        EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { container in
            var intents = container.inlinePresentationIntent ?? []
            if enabled { intents.remove(.strikethrough) } else { intents.insert(.strikethrough) }
            container.inlinePresentationIntent = intents.isEmpty ? nil : intents
            container.strikethroughStyle = enabled ? nil : .single
        }
        model.activeTextChanged()
    }

    /// Like "/code": block to code block (keeping its text), code block back to paragraph. Where a code block isn't
    /// allowed (list item, table cell, …), inserts one after the enclosing block.
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

    private func toggleCode() {
        let enabled = isCodeFormatted
        EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { EditorText.setCode(!enabled, in: &$0) }
        model.activeTextChanged()
    }

    private func toggleHighlight() {
        let enabled = isHighlighted
        EditorText.transformRuns(of: &model.activeText, in: &model.activeSelection) { EditorText.setHighlight(!enabled, in: &$0) }
        model.activeTextChanged()
    }
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
    @State private var targetRange: Range<AttributedString.Index>?
    @State private var insertionPoint: AttributedString.Index?

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

    private var existingLink: URL? {
        guard let range = targetRange else { return nil }
        return model.activeText[range].runs.first?.link
    }

    /// The whole link the sheet edits (a selection may cover part of it): what becomes a card or mention.
    private var wholeLink: Range<AttributedString.Index>? {
        guard let range = targetRange, let url = existingLink else { return nil }
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
                        Text(targetRange != nil ? "The link is applied to the selected text." : "Select text first to turn it into a link; otherwise the address is inserted as text.")
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
                            Button("Show as Card") {
                                model.showLink(in: range, provider: provider, as: .card)
                                dismiss()
                            }
                        }
                        Button("Show as Mention") {
                            model.showLink(in: range, provider: provider, as: .mention)
                            dismiss()
                        }
                    }
                }
                if existingLink != nil {
                    Button("Remove Link", role: .destructive) {
                        if let range = targetRange { model.activeText[range].link = nil }
                        model.activeTextChanged()
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
                (targetRange, insertionPoint) = Self.target(in: model.activeText, selection: model.activeSelection)
                if let existing = existingLink { address = existing.absoluteString }
            }
            .task(id: pageQuery) {
                let query = pageQuery.trimmingCharacters(in: .whitespaces)
                guard !query.isEmpty, let suggest = model.suggest else {
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

    private func apply() {
        guard let url = link else { return }
        if let range = targetRange {
            model.activeText[range].link = url
        } else {
            var run = AttributedString(url.absoluteString)
            run.link = url
            let index = insertionPoint ?? model.activeText.endIndex
            model.activeText.transform(updating: &model.activeSelection) { text in
                text.insert(run, at: index)
            }
        }
        model.activeTextChanged()
        dismiss()
    }
}
