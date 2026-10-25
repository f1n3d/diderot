import SwiftUI
import DocmostKit

extension EnvironmentValues {
    /// Font for paragraphs below, e.g. smaller in footnotes; `nil` = body text.
    @Entry var paragraphFont: Font?
}

// MARK: - Footnotes

/// Page-end footnotes, editable as on the web; the engine adds and removes them with their references.
struct FootnotesNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            ForEach(NodeEntry.entries(node.children, parentPath: ref.path)) { footnote in
                let index = footnote.ref.path.last ?? 0
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                    NodeListView(model: model, nodes: footnote.node.children, parentPath: footnote.ref.path, spacing: 4)
                        .environment(\.paragraphFont, .footnote)
                }
                // Same anchor as the reader (`ContentParser`), so footnote links scroll here.
                .id(footnote.node.string("id") ?? "p\(ref.path.map(String.init).joined(separator: ".")).\(index)")
            }
        }
    }
}

// MARK: - Columns

/// Columns as on the web: side by side at regular width (split by `layout` or the columns' `width`), stacked when
/// narrow (Notion does too). With the cursor inside, a frame and the column bar appear.
struct ColumnsNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isActive: Bool { model.activeAncestorPath(ofType: "columns") == ref.path }
    private var sideBySide: Bool { sizeClass == .regular }

    var body: some View {
        let columns = NodeEntry.entries(node.children, parentPath: ref.path)
        // One AnyLayout for both widths, so a size-class change (rotation, iPad window) keeps content and cursor.
        let layout = sideBySide ? AnyLayout(WeightedColumnsLayout(weights: weights, spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        VStack(alignment: .leading, spacing: isActive ? 14 : 6) {
            if isActive, model.isEditable {
                ColumnsBar(model: model, path: ref.path, count: columns.count, layout: node.string("layout") ?? "", sideBySide: sideBySide)
            }
            layout {
                ForEach(columns) { column(for: $0, count: columns.count) }
            }
        }
    }

    private func column(for entry: NodeEntry, count: Int) -> some View {
        let index = entry.ref.path.last ?? 0
        return NodeListView(model: model, nodes: entry.node.children, parentPath: entry.ref.path)
            // Side by side, the last column has the top right corner; stacked, the first.
            .clearOfBlockActions(applies: sideBySide ? index == count - 1 : index == 0)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if isActive, !sideBySide {
                    Text("Column \(index + 1) of \(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Color(.systemBackground))
                        .offset(x: 6, y: -14)
                        .allowsHitTesting(false)
                }
            }
    }

    private var weights: [CGFloat] { ContentParser.columnWeights(of: node).map { CGFloat($0) } }
}

/// Bar above active columns, like the web's column bar: count, layout preset (side by side only) and delete.
private struct ColumnsBar: View {
    let model: DocumentModel
    let path: [Int]
    let count: Int
    let layout: String
    let sideBySide: Bool
    @State private var confirmsDelete = false

    private struct Preset: Identifiable {
        let layout: String
        let title: LocalizedStringKey
        let symbol: String
        var id: String { layout }
    }

    private var presets: [Preset] {
        switch count {
        case 2:
            [Preset(layout: "two_equal", title: "Equal columns", symbol: "rectangle.split.2x1"),
             Preset(layout: "two_left_sidebar", title: "Left sidebar", symbol: "sidebar.left"),
             Preset(layout: "two_right_sidebar", title: "Right sidebar", symbol: "sidebar.right")]
        case 3:
            [Preset(layout: "three_equal", title: "Equal columns", symbol: "rectangle.split.3x1"),
             Preset(layout: "three_with_sidebars", title: "Wide center", symbol: "rectangle.center.inset.filled"),
             Preset(layout: "three_left_wide", title: "Left wide", symbol: "rectangle.leadinghalf.inset.filled"),
             Preset(layout: "three_right_wide", title: "Right wide", symbol: "rectangle.trailinghalf.inset.filled")]
        default: []
        }
    }

    var body: some View {
        FloatingBlockBar {
            Text("Columns")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            ForEach(2...5, id: \.self) { number in
                let selected = number == count
                Button {
                    Task { await model.setColumnCount(number, at: path) }
                } label: {
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(number) Columns"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("columns-count-\(number)")
            }
            if sideBySide, !presets.isEmpty {
                Divider().frame(height: 18)
                ForEach(presets) { preset in
                    let selected = preset.layout == layout || (layout.isEmpty && preset.layout.hasSuffix("_equal"))
                    Button {
                        Task { await model.setAttributes(of: NodeRef(path: path, id: nil), ["layout": .string(preset.layout)]) }
                    } label: {
                        Image(systemName: preset.symbol)
                            .font(.caption.weight(.medium))
                            .frame(width: 30, height: 30)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Divider().frame(height: 18)
            Button {
                confirmsDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete columns")
            .accessibilityIdentifier("columns-delete")
            // On the button: iOS shows the confirmation as a popover from the view it's attached to.
            .confirmationDialog("Delete these columns and their content?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.deactivate()
                    Task { await model.delete(NodeRef(path: path, id: nil)) }
                }
            }
        }
    }
}

// MARK: - Synced blocks

/// Synced block source: editable in place, with the web's menu (copy to paste elsewhere, usage, unsync, delete).
struct SyncedBlockNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @State private var showsUsage = false
    @State private var confirmsDelete = false

    private var transclusionId: String? { node.string("id") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Synced block")
                Spacer(minLength: 0)
                if model.isEditable {
                    Menu {
                        Button("Copy Synced Block", systemImage: "doc.on.doc") { copy() }
                            .disabled(transclusionId == nil)
                        Button("Pages Using It", systemImage: "doc.text.magnifyingglass") { showsUsage = true }
                            .disabled(transclusionId == nil)
                        Divider()
                        Button("Unsync", systemImage: "link.badge.plus") {
                            Task { await model.unsyncSource(ref) }
                        }
                        Button("Delete Synced Block", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Synced block actions")
                    .accessibilityIdentifier("synced-block-menu")
                    // On the menu: iOS shows the confirmation as a popover from the view it's attached to.
                    .confirmationDialog("Delete this synced block? Pages that embed it show that it no longer exists.", isPresented: $confirmsDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            model.deactivate()
                            Task { await model.delete(ref) }
                        }
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            NodeListView(model: model, nodes: node.children, parentPath: ref.path)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5))
        .sheet(isPresented: $showsUsage) {
            if let transclusionId {
                SyncedBlockUsageSheet(sourcePageId: model.page.id, transclusionId: transclusionId, currentPageId: model.page.id)
            }
        }
    }

    private func copy() {
        guard let transclusionId else { return }
        SyncedBlockClipboard.copy(.init(sourcePageId: model.page.id, transclusionId: transclusionId), text: node.plainText)
        model.notice = String(localized: "Copied. Paste on any page to embed this synced block.")
    }
}

/// Synced block embedded from another page: read-only (edits happen in the source), with the web's actions.
struct SyncedReferenceNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @Environment(\.renderContext) private var context
    @Environment(ReaderNavigation.self) private var navigation
    @State private var refreshToken = 0
    @State private var showsUsage = false
    @State private var isUnsyncing = false

    private var sourcePageId: String? { node.string("sourcePageId") }
    private var transclusionId: String? { node.string("transclusionId") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Synced block")
                Spacer(minLength: 0)
                if isUnsyncing { ProgressView().controlSize(.small) }
                if model.isEditable {
                    Menu {
                        if let sourcePageId {
                            Button("Edit Original", systemImage: "pencil") { navigation.open(PageSelection(pageId: sourcePageId)) }
                        }
                        Button("Refresh", systemImage: "arrow.clockwise") { refreshToken += 1 }
                        Button("Copy Synced Block", systemImage: "doc.on.doc") { copy() }
                        Button("Pages Using It", systemImage: "doc.text.magnifyingglass") { showsUsage = true }
                        Divider()
                        Button("Unsync", systemImage: "link.badge.plus") { Task { await unsync() } }
                            .disabled(isUnsyncing)
                        Button("Remove from Page", systemImage: "trash", role: .destructive) {
                            model.deactivate()
                            Task { await model.delete(ref) }
                        }
                        .disabled(isUnsyncing)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .disabled(sourcePageId == nil || transclusionId == nil)
                    .accessibilityLabel("Synced block actions")
                    .accessibilityIdentifier("synced-reference-menu")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            TransclusionReferenceView(sourcePageId: sourcePageId, transclusionId: transclusionId, refreshToken: refreshToken, showsIcon: false)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        .sheet(isPresented: $showsUsage) {
            if let sourcePageId, let transclusionId {
                SyncedBlockUsageSheet(sourcePageId: sourcePageId, transclusionId: transclusionId, currentPageId: model.page.id)
            }
        }
    }

    private func copy() {
        guard let sourcePageId, let transclusionId else { return }
        SyncedBlockClipboard.copy(.init(sourcePageId: sourcePageId, transclusionId: transclusionId), text: nil)
        model.notice = String(localized: "Copied. Paste on any page to embed this synced block.")
    }

    /// Web parity: the server copies the attachments and returns the content that replaces the reference.
    private func unsync() async {
        guard let client = context.client, let sourcePageId, let transclusionId else { return }
        isUnsyncing = true
        defer { isUnsyncing = false }
        do {
            let result = try await client.send(Endpoints.Transclusions.unsyncReference(
                referencePageId: model.page.id, sourcePageId: sourcePageId, transclusionId: transclusionId
            ))
            let nodes = result.nodes
            await model.unsyncReference(node, at: ref, content: nodes.isEmpty ? [PMNode(type: "paragraph")] : nodes)
        } catch {
            model.notice = error.userMessage
        }
    }
}

/// Pages using a synced block (source and embeds), as on the web.
struct SyncedBlockUsageSheet: View {
    let sourcePageId: String
    let transclusionId: String
    let currentPageId: String
    @Environment(\.renderContext) private var context
    @Environment(ReaderNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<TransclusionReferences> = .idle

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let error):
                    Text(error.userMessage).foregroundStyle(.secondary)
                case .loaded(let usage):
                    if let source = usage.source {
                        Section("Original") { row(source) }
                    }
                    Section("Synced to") {
                        if usage.references.isEmpty {
                            Text("Not embedded on other pages yet.").foregroundStyle(.secondary)
                        }
                        ForEach(usage.references) { row($0) }
                    }
                }
            }
            .navigationTitle("Pages Using It")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ page: PageRef) -> some View {
        Button {
            dismiss()
            if page.id != currentPageId { navigation.open(PageSelection(pageId: page.id, title: page.title)) }
        } label: {
            HStack(spacing: 8) {
                PageIconView(icon: page.icon, size: 18)
                Text(page.displayTitle).foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                if page.id == currentPageId {
                    Text("This page").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        guard let client = context.client else { return }
        state = .loading
        do {
            state = .loaded(try await client.send(Endpoints.Transclusions.references(sourcePageId: sourcePageId, transclusionId: transclusionId)))
        } catch is CancellationError {
        } catch {
            state = .failed(error)
        }
    }
}

// MARK: - Diagrams, math, embeds

/// Draw.io or Excalidraw: an image once drawn; tapping an empty one (inserted in the app) opens the web editor to draw.
struct DiagramNodeView: View {
    let model: DocumentModel
    let node: PMNode

    var body: some View {
        if (node.string("src") ?? "").isEmpty {
            Button {
                model.deactivate()
                model.requestsWebEditor = true
            } label: {
                PlaceholderCard(
                    icon: node.type == "drawio" ? "pencil.and.outline" : "scribble.variable",
                    title: node.type == "drawio" ? String(localized: "Draw.io diagram") : String(localized: "Excalidraw drawing"),
                    detail: model.isEditable ? String(localized: "Tap to draw it in the web editor.") : String(localized: "Empty diagram")
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.isEditable)
            .accessibilityIdentifier("diagram-placeholder")
        } else {
            ReaderNodeView(node: node)
        }
    }
}

/// Math block: rendered as in the reader; tap to edit.
struct MathBlockNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef

    var body: some View {
        let latex = node.string("text") ?? ""
        Group {
            if latex.isEmpty {
                PlaceholderCard(icon: "x.squareroot", title: String(localized: "Math block"), detail: String(localized: "Empty equation"))
            } else {
                MathBlockView(latex: latex)
            }
        }
        // Above the WebView, which would otherwise take the taps.
        .overlay {
            if model.isEditable {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.deactivate()
                        model.editorSheet = .mathBlock(.edit(ref), latex: latex)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("Edit equation"))
                    .accessibilityIdentifier("math-block")
            }
        }
    }
}

/// Embed: the reader's card (tap opens the browser). Without a link (created on the web, never filled in), tap opens
/// the link sheet.
struct EmbedNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef

    var body: some View {
        let provider = EmbedProvider(rawValue: node.string("provider") ?? "") ?? .iframe
        if (node.string("src") ?? "").isEmpty, model.isEditable {
            Button {
                model.deactivate()
                model.editorSheet = .embed(.edit(ref), provider: provider, link: "")
            } label: {
                PlaceholderCard(icon: provider.symbol, title: String(localized: "Embed \(provider.name)"),
                                detail: String(localized: "Tap to add the link."))
            }
            .buttonStyle(.plain)
        } else {
            ReaderNodeView(node: node)
        }
    }
}

/// Sub-pages while editing: on Docmost 0.97 and newer the block's sort order can be changed, as on the web.
struct SubpagesNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef

    var body: some View {
        let model = model, ref = ref
        SubpagesBlockView(
            sortBy: node.string("sortBy").flatMap(SubpagesSort.init(rawValue:)) ?? .manual,
            sort: model.isEditable && model.hasDocmost097Features ? { order in
                Task { await model.setAttributes(of: ref, ["sortBy": .string(order.rawValue)]) }
            } : nil
        )
    }
}

extension SubpagesSort {
    var title: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .titleAscending: String(localized: "A–Z")
        case .recent: String(localized: "Recent")
        }
    }
}
