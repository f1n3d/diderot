import SwiftUI
import DocmostKit

/// Editor keyboard toolbar. No pop-up menus (on device they hide behind the keyboard): "Block type" swaps in a row
/// of buttons, "+" opens the insert menu below the block (as "/" does).
struct EditorToolbar: View {
    private enum Mode { case main, blockType }

    @Bindable var model: DocumentModel
    @State private var mode: Mode = .main
    @State private var confirmsDelete = false

    private var isCode: Bool { model.active?.type == "codeBlock" }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    switch mode {
                    case .main: mainRow
                    case .blockType: blockTypeRow
                    }
                }
                .padding(.horizontal, 4)
            }
            iconButton("Done", "keyboard.chevron.compact.down", id: "editor-done") { model.deactivate() }
                .padding(.leading, 6)
        }
        .onChange(of: model.active) { _, _ in mode = .main }
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

    private var divider: some View {
        Divider().frame(height: 20)
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
