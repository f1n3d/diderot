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

/// The page's one text editor, lying on the active block's text (paragraph, heading, toggle title, code; the block keeps
/// its place with a hidden copy). It stays the same view while the active block changes, so focus, the keyboard and its
/// state stay and the caret moves at once; one editor per block made iOS hand focus over at every Return.
struct PageEditor: View {
    let model: DocumentModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// With VoiceOver the text is edited in its block instead (`TextNodeView`): VoiceOver reads the page in order,
    /// and this editor lies outside it, so it came before the page's heading. On Return the keyboard then briefly
    /// hides, as focus moves to the next block's editor.
    static func editsInBlock(voiceOver: Bool) -> Bool {
        voiceOver || DebugLaunch.editsInBlock
    }

    var body: some View {
        if !Self.editsInBlock(voiceOver: voiceOver), let active = model.active, let place = model.editorFrame {
            ActiveTextEditor(model: model, ref: active.ref, font: model.editorStyle.font, isCode: model.editorStyle.isCode)
                // Its own height, not the row's: beside a checkbox it took the checkbox's.
                .fixedSize(horizontal: false, vertical: true)
                // The text view puts the font's leading below every line, the reader only between lines: without the
                // last one the editor is as tall as the reader's text, so the blocks below don't move.
                .padding(.bottom, -model.editorStyle.leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if place.ref == active.ref { model.editorHeight = (active.ref, height) }
                }
                .multilineTextAlignment(model.editorStyle.alignment)
                .frame(width: place.frame.width, alignment: .topLeading)
                // Until the new block reports its place, the editor would show the new text at the old one.
                .opacity(place.ref == active.ref ? 1 : 0)
                .offset(x: place.frame.minX, y: place.frame.minY)
        }
    }
}

/// The text editor in `PageEditor`.
struct ActiveTextEditor: View {
    @Bindable var model: DocumentModel
    let ref: NodeRef
    let font: Font
    var isCode = false

    private var isActive: Bool { model.active?.ref == ref }

    var body: some View {
        TextEditor(text: text, selection: selection)
            .font(font)
            .autocorrectionDisabled(isCode)
            .textInputAutocapitalization(isCode ? .never : .sentences)
            // No caret until `applyCursor` places it: focus comes first, and the caret would show at the end and jump.
            .tint(isActive && model.cursorRequest != nil ? Color.clear : Color.accentColor)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            // Cancels the text area's 8 pt vertical and 5 pt horizontal insets: the text stays where it sat before
            // the tap and the block or table row doesn't grow.
            .padding(.vertical, -8)
            .padding(.horizontal, -5)
            .accessibilityIdentifier(isActive ? "active-editor" : "idle-editor")
            .accessibilityHidden(!isActive)
            .modifier(EditorFocus(model: model, ref: ref, onFocus: {
                // Pasting a copied synced block embeds it instead of inserting its markup as text.
                let model = model
                EditorPasteProxy.install { reference in
                    model.pasteSyncedReferenceIntoActive(reference)
                } onLink: { link in
                    model.pasteLink(link)
                }
                if let view = FirstResponder.current as? UITextView {
                    model.editorTextView = view
                    TextInputHooks.install(on: view)
                    TextInputHooks.onBackspaceAtStart = { [weak model] view in
                        guard let model, view === model.editorTextView else { return false }
                        return model.backspaceAtStart()
                    }
                }
            }))
            .onAppear { if isActive { applyCursor() } }
            .onChange(of: model.cursorRequest) { _, _ in if isActive { applyCursor() } }
            .onChange(of: model.activeText) { _, _ in
                guard isActive else { return }
                // Each answers only for its kind of block.
                model.activeTextChanged()
                model.activeCodeChanged()
            }
            .onChange(of: model.activeSelection) { _, _ in if isActive { model.activeSelectionChanged() } }
            .onChange(of: isCode) { _, _ in
                // The keyboard takes changed traits (autocorrection, capitalization) only after a reload.
                DispatchQueue.main.async { FirstResponder.current?.reloadInputViews() }
            }
    }

    private var text: Binding<AttributedString> {
        isActive ? $model.activeText : .constant(AttributedString())
    }

    private var selection: Binding<AttributedTextSelection> {
        isActive ? $model.activeSelection : .constant(AttributedTextSelection())
    }

    private func applyCursor() {
        guard let request = model.cursorRequest else { return }
        Task { @MainActor in
            // After this update: the editor has focus already but shows the new block's text only then.
            try? await Task.sleep(for: .zero)
            guard model.cursorRequest == request else { return }
            var resolved = request
            if case .point(let point) = request {
                resolved = await Self.offset(at: point, in: String(model.activeText.characters)).map { .offset($0) } ?? .end
                guard model.cursorRequest == request else { return }
            }
            let text = model.activeText
            let characters = text.characters
            let index: AttributedString.Index
            switch resolved {
            case .start:
                index = text.startIndex
            case .end, .point:
                index = text.endIndex
            case .offset(let offset):
                index = characters.index(text.startIndex, offsetBy: min(offset, characters.count))
            }
            model.activeSelection = AttributedTextSelection(insertionPoint: index)
            model.cursorRequest = nil
        }
    }

    /// Character offset under `point` (relative to the text's top left), by the focused text view's own layout once
    /// it shows `text`; `nil` if it doesn't within half a second (focus still on the previous block's editor).
    private static func offset(at point: CGPoint, in text: String) async -> Int? {
        for _ in 0..<5 {
            if let view = FirstResponder.current as? UITextView, view.text == text {
                view.layoutIfNeeded()
                // The editor's negative padding cancels these insets, so its text lies where the reader's was.
                let inset = view.textContainerInset, padding = view.textContainer.lineFragmentPadding
                guard let position = view.closestPosition(to: CGPoint(x: point.x + inset.left + padding, y: point.y + inset.top))
                else { return nil }
                let utf16 = view.offset(from: view.beginningOfDocument, to: position)
                return text.distance(from: text.startIndex, to: text.utf16.index(text.startIndex, offsetBy: min(max(utf16, 0), text.utf16.count)))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

/// Text and code editor focus: taken once the editor is in the window, reported to the model, retaken after a sheet.
private struct EditorFocus: ViewModifier {
    let model: DocumentModel
    let ref: NodeRef
    var onFocus: () -> Void = {}
    @FocusState private var focused: Bool
    /// Per-instance id: an editor SwiftUI rebuilds gets a new one.
    @State private var instance = UUID()

    private var isActive: Bool { model.active?.ref == ref }

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .background {
                FocusWhenInWindow { if isActive, !model.editsInSheet { focused = true } }
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused { onFocus() }
                model.editorFocusChanged(isFocused, instance: instance, ref: ref)
            }
            .onChange(of: model.editsInSheet) { _, editing in
                // After the link, comment or insert sheet (or emoji keyboard), editing continues in the same block.
                guard !editing, isActive else { return }
                focused = true
                // While the sheet is still dismissing, UIKit on device sometimes rejects focus: retry.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    if isActive, !model.editsInSheet, !focused { focused = true }
                }
            }
    }
}

// MARK: - Lists

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

struct TaskListNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @Environment(\.listDepth) private var depth

    private var doneCount: Int { node.children.filter { $0.bool("checked") == true }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ref.isTopLevel && node.children.count > 1 {
                HStack {
                    Label("Checklist", systemImage: "checklist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Chip(text: String(localized: "\(doneCount) of \(node.children.count) done"))
                }
            }
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
                }
            }
        }
        .padding(ref.isTopLevel && node.children.count > 1 ? 14 : 0)
        .background {
            if ref.isTopLevel && node.children.count > 1 {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground))
            }
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

/// Floating capsule bar above the active block (callout type, code language, column actions).
struct FloatingBlockBar<Content: View>: View {
    var verticalPadding: CGFloat = 3
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) { content }
                .padding(.horizontal, 6)
                .padding(.vertical, verticalPadding)
        }
        .background(.regularMaterial, in: Capsule())
    }
}

private extension Text {
    /// Option in the callout and code bars.
    func barOption(selected: Bool) -> some View {
        font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .contentShape(Capsule())
    }
}

/// Switches the type of the active callout.
private struct CalloutTypeBar: View {
    let model: DocumentModel
    let path: [Int]
    let current: CalloutKind

    var body: some View {
        FloatingBlockBar {
            ForEach(CalloutKind.allCases, id: \.self) { kind in
                Button {
                    Task { await model.setAttributes(of: NodeRef(path: path, id: nil), ["type": .string(kind.rawValue)]) }
                } label: {
                    Text(kind.title).barOption(selected: kind == current)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("callout-\(kind.rawValue)")
            }
        }
    }
}

/// Picks the language of the active code block.
private struct CodeLanguageBar: View {
    let model: DocumentModel
    let path: [Int]
    let current: String?

    private static let languages = [
        "plaintext", "swift", "javascript", "typescript", "python", "json", "bash", "shell", "html", "css", "sql",
        "yaml", "markdown", "java", "kotlin", "go", "rust", "c", "cpp", "csharp", "php", "ruby", "xml", "mermaid",
    ]

    var body: some View {
        FloatingBlockBar {
            ForEach(Self.languages, id: \.self) { language in
                Button {
                    Task { await model.setAttributes(of: NodeRef(path: path, id: nil), ["language": language == "plaintext" ? .null : .string(language)]) }
                } label: {
                    Text(language).barOption(selected: (current ?? "plaintext") == language)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Suggestions for "@": pages and people.
private struct MentionMenuView: View {
    let model: DocumentModel
    @Environment(\.renderContext) private var context

    var body: some View {
        let suggestions = Array(model.mentionSuggestions.prefix(8))
        VStack(alignment: .leading, spacing: 0) {
            if suggestions.isEmpty {
                Text(model.mentionQuery?.isEmpty == false ? "No matches" : "Mention a page or person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(suggestions) { suggestion in
                Button {
                    model.insertMention(suggestion)
                } label: {
                    HStack(spacing: 10) {
                        if suggestion.kind == .user {
                            AvatarView(name: suggestion.title, avatarUrl: suggestion.avatarUrl, baseURL: context.baseURL, size: 24)
                        } else {
                            PageIconView(icon: suggestion.icon, size: 18)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title).lineLimit(1)
                            if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mention-\(suggestion.id)")
                if suggestion.id != suggestions.last?.id {
                    Divider().padding(.leading, 46)
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Insert menu below the active block: filtered by the query after "/", complete after "+". Entries in web editor
/// order; scrolls beyond `maxHeight`.
struct InsertMenuView: View {
    let model: DocumentModel
    @State private var contentHeight: CGFloat = 0
    private let maxHeight: CGFloat = 264

    var body: some View {
        let matches = model.insertMatches
        Group {
            if matches.isEmpty {
                Text("No matching block")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { command in
                            row(command)
                            if command.id != matches.last?.id {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight)
                .scrollIndicatorsFlash(onAppear: true)
                // New query: start at the top again.
                .id(model.slashQuery ?? "+")
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ command: InsertCommand) -> some View {
        let enabled = model.isEnabled(command)
        return Button {
            model.perform(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.symbol)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !enabled {
                    Image(systemName: "lock")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Not included in your plan")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityIdentifier("slash-\(command.id)")
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
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// Code as in the reader, with find matches highlighted.
    private var displayedCode: AttributedString {
        var text = AttributedString(code.isEmpty ? " " : code)
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
                        Text(displayedCode)
                            .font(.system(.callout, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
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

extension EnvironmentValues {
    /// The page shows the block's "…" (`BlockActionsButton`) at its top right, over the block.
    @Entry var showsBlockActions = false
}

extension View {
    /// Keeps text inside a block clear of the block's "…" at its top right, where the page shows one. `inset`: room
    /// the block already has there (a callout's padding); `applies`: whether this part sits at the top right.
    func clearOfBlockActions(inset: CGFloat = 0, applies: Bool = true) -> some View {
        modifier(ClearOfBlockActions(inset: inset, applies: applies))
    }
}

private struct ClearOfBlockActions: ViewModifier {
    let inset: CGFloat
    let applies: Bool
    @Environment(\.showsBlockActions) private var showsBlockActions
    /// The button's width: a `.title3` symbol with 6 points on each side, growing with the text size as it does.
    @ScaledMetric(relativeTo: .title3) private var buttonWidth: CGFloat = 34

    func body(content: Content) -> some View {
        content
            .padding(.trailing, showsBlockActions && applies ? max(buttonWidth - inset, 0) : 0)
            // Blocks inside have a button of their own, or none.
            .environment(\.showsBlockActions, false)
    }
}

/// The "…" that opens a block's actions.
struct BlockActionsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Block actions")
        .accessibilityIdentifier("block-actions")
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

// MARK: - Drag & Drop

/// Long-press and drag a block to move it, unless a block is being edited; where shown, its "…" button offers Duplicate,
/// Delete and edit actions.
private struct BlockDragModifier: ViewModifier {
    let model: DocumentModel
    let entry: NodeEntry
    @State private var height: CGFloat = 0
    @State private var isTargeted = false
    @State private var insertBefore = true
    @State private var showsActions = false

    /// Text, lists and code get actions from the keyboard toolbar, synced blocks from their menu; others from "…".
    private var showsMenuButton: Bool {
        if ["paragraph", "heading", "bulletList", "orderedList", "taskList", "codeBlock", "transclusionSource",
            "transclusionReference"].contains(entry.node.type) { return false }
        // A table shows its own "…" after its last column: on a wide one this corner would cover a cell.
        if entry.node.type == "table" { return false }
        // Active columns show their own bar on top; the button would cover it.
        if entry.node.type == "columns", model.activeAncestorPath(ofType: "columns") == entry.ref.path { return false }
        return true
    }

    func body(content: Content) -> some View {
        // By `engine`, which the page keeps: `isEditable` turns true after the first sync, and switching branches
        // would rebuild every block (formulas re-render, media reload).
        if model.engine != nil {
            content
                .environment(\.showsBlockActions, model.isEditable && showsMenuButton)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .overlay(alignment: insertBefore ? .top : .bottom) {
                    if isTargeted {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .offset(y: insertBefore ? -6 : 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.isEditable, showsMenuButton {
                        BlockActionsButton {
                            model.deactivate()
                            showsActions = true
                        }
                        // On the button: iOS shows the actions as a popover from the view they're attached to.
                        .confirmationDialog("Block", isPresented: $showsActions, titleVisibility: .hidden) {
                            switch entry.node.type {
                            case "embed":
                                Button("Change Link") {
                                    let provider = EmbedProvider(rawValue: entry.node.string("provider") ?? "") ?? .iframe
                                    model.editorSheet = .embed(.edit(entry.ref), provider: provider, link: entry.node.string("src") ?? "")
                                }
                            case "mathBlock":
                                Button("Edit Equation") { model.editorSheet = .mathBlock(.edit(entry.ref), latex: entry.node.string("text") ?? "") }
                            case "drawio", "excalidraw":
                                Button("Edit in Web Editor") { model.requestsWebEditor = true }
                            case "integrationCard":
                                Button("Show as Mention") { Task { await model.showIntegrationCard(entry.ref, as: .mention) } }
                                Button("Show as URL") { Task { await model.showIntegrationCard(entry.ref, as: .link) } }
                            default:
                                EmptyView()
                            }
                            Button("Duplicate") { Task { await model.duplicate(entry.ref) } }
                            Button("Delete", role: .destructive) { Task { await model.delete(entry.ref) } }
                        }
                    }
                }
                .onDrag {
                    DragPayload.provider(BlockDropDelegate.prefix(model) + entry.ref.identity)
                }
                // While a block is edited, a long press belongs to the text (`LongPressPlacesCaret`), not to moving
                // blocks: they move through "Arrange Blocks" then. This one keeps the drag from starting elsewhere.
                .gesture(LongPressGesture(minimumDuration: 0.3), including: model.hasActiveBlock ? .all : .subviews)
                .onDrop(of: DragPayload.types, delegate: BlockDropDelegate(
                    model: model, ref: entry.ref, height: { height },
                    targeted: { isTargeted = $0 }, before: { insertBefore = $0 }
                ))
        } else {
            content
        }
    }
}

private struct BlockDropDelegate: DropDelegate {
    let model: DocumentModel
    let ref: NodeRef
    let height: () -> CGFloat
    let targeted: (Bool) -> Void
    let before: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        model.isEditable && info.hasItemsConforming(to: DragPayload.types)
    }

    func dropEntered(info: DropInfo) {
        targeted(true)
        before(info.location.y < height() / 2)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        before(info.location.y < height() / 2)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        targeted(false)
    }

    /// Carries the page: a block dragged from another window's page (iPad) must not move one here with its identity.
    static func prefix(_ model: DocumentModel) -> String { "docmost-block:\(model.page.id)/" }

    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        let insertBefore = info.location.y < height() / 2
        let model = model
        let ref = ref
        return DragPayload.load(info, prefix: Self.prefix(model)) { identity in
            Task { await model.moveBlock(identity: identity, relativeTo: ref, before: insertBefore) }
        }
    }
}
