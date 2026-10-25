import Foundation
import Observation
import SwiftUI
import DocmostKit

/// Node identity in the view: UniqueID (paragraphs, headings) or path from the root.
struct NodeRef: Hashable, Sendable {
    let path: [Int]
    let id: String?
    /// Source node's type, so a path target misses another kind of block; not part of the identity.
    var type: String?

    init(path: [Int], node: PMNode) {
        self.path = path
        // A tab may have an empty id until Docmost gives it one: no identity.
        self.id = node.string("id").flatMap { $0.isEmpty ? nil : $0 }
        self.type = node.type
    }

    init(path: [Int], id: String?) {
        self.path = path
        self.id = id
    }

    static func == (lhs: NodeRef, rhs: NodeRef) -> Bool { lhs.path == rhs.path && lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(id)
    }

    var identity: String { id ?? "path:" + path.map(String.init).joined(separator: ".") }
    var target: BlockTarget { id.map { .id($0) } ?? .path(path, type: type) }
    /// Anchor ID as in the reader (`ContentParser`): UniqueID or path "0.3.1".
    var anchorId: String { id ?? path.map(String.init).joined(separator: ".") }
    var isTopLevel: Bool { path.count == 1 }
}

/// Node plus its identity for `ForEach`.
struct NodeEntry: Identifiable {
    let ref: NodeRef
    let node: PMNode
    var id: String { ref.identity }

    static func entries(_ nodes: [PMNode], parentPath: [Int]) -> [NodeEntry] {
        nodes.enumerated().map { NodeEntry(ref: NodeRef(path: parentPath + [$0.offset], node: $0.element), node: $0.element) }
    }
}

enum CursorRequest: Equatable {
    case start, end
    case offset(Int)
    /// A tap, relative to the block's text (top left of its first line): the text position there, once the editor
    /// shows the block. Not the window: a table's bar appears above it on activation and moves the text down.
    case point(CGPoint)
}

/// Templates for new blocks.
enum BlockTemplate: String, CaseIterable, Identifiable {
    case paragraph, heading1, heading2, heading3, bulletList, orderedList, taskList, quote, callout, toggle, codeBlock, table, divider

    var id: String { rawValue }

    /// Localized title (key = English title) for the toolbar and the insert menu.
    var titleResource: LocalizedStringResource {
        switch self {
        case .paragraph: "Paragraph"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulletList: "Bullet list"
        case .orderedList: "Numbered list"
        case .taskList: "Task list"
        case .quote: "Quote"
        case .callout: "Callout"
        case .toggle: "Toggle"
        case .codeBlock: "Code block"
        case .table: "Table"
        case .divider: "Divider"
        }
    }

    var symbol: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1: "1.square"
        case .heading2: "2.square"
        case .heading3: "3.square"
        case .bulletList: "list.bullet"
        case .orderedList: "list.number"
        case .taskList: "checklist"
        case .quote: "text.quote"
        case .callout: "info.bubble"
        case .toggle: "chevron.right.square"
        case .codeBlock: "chevron.left.forwardslash.chevron.right"
        case .table: "tablecells"
        case .divider: "minus"
        }
    }

    /// New node, optionally with existing inline content (when converting).
    func node(inlines: [PMNode]? = nil, attrs: [String: JSONValue]? = nil) -> PMNode {
        let content = inlines?.isEmpty == false ? inlines : nil
        let paragraph = PMNode(type: "paragraph", attrs: attrs, content: content)
        switch self {
        case .paragraph: return paragraph
        case .heading1, .heading2, .heading3:
            var headingAttrs = attrs ?? [:]
            headingAttrs["level"] = .number(Double(self == .heading1 ? 1 : self == .heading2 ? 2 : 3))
            return PMNode(type: "heading", attrs: headingAttrs, content: content)
        case .bulletList: return PMNode(type: "bulletList", content: [PMNode(type: "listItem", content: [paragraph])])
        case .orderedList: return PMNode(type: "orderedList", attrs: ["start": 1], content: [PMNode(type: "listItem", content: [paragraph])])
        case .taskList: return PMNode(type: "taskList", content: [PMNode(type: "taskItem", attrs: ["checked": false], content: [paragraph])])
        case .quote: return PMNode(type: "blockquote", content: [paragraph])
        case .callout: return PMNode(type: "callout", attrs: ["type": "info"], content: [paragraph])
        case .toggle:
            return PMNode(type: "details", attrs: ["open": true], content: [
                PMNode(type: "detailsSummary", content: content),
                PMNode(type: "detailsContent", content: [PMNode(type: "paragraph")]),
            ])
        case .codeBlock:
            let text = inlines.map { PMNode(type: "doc", content: $0).plainText } ?? ""
            return PMNode(type: "codeBlock", attrs: ["language": .null], content: text.isEmpty ? nil : [PMNode(type: "text", text: text)])
        case .table:
            func cell(_ type: String) -> PMNode { PMNode(type: type, attrs: ["colspan": 1, "rowspan": 1], content: [PMNode(type: "paragraph")]) }
            let header = PMNode(type: "tableRow", content: [cell("tableHeader"), cell("tableHeader"), cell("tableHeader")])
            let rows = (0..<2).map { _ in PMNode(type: "tableRow", content: [cell("tableCell"), cell("tableCell"), cell("tableCell")]) }
            return PMNode(type: "table", content: [header] + rows)
        case .divider: return PMNode(type: "horizontalRule")
        }
    }

    /// Path (relative to the new node) of the first editable text.
    var firstTextPath: [Int]? {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3, .codeBlock: []
        case .bulletList, .orderedList, .taskList: [0, 0]
        case .quote, .callout, .toggle: [0]
        case .table: [0, 0, 0]
        case .divider: nil
        }
    }
}

/// Mention suggestion: a person or a page.
struct MentionSuggestion: Identifiable, Hashable {
    enum Kind: Hashable { case user, page }

    let kind: Kind
    let entityId: String
    let title: String
    let subtitle: String?
    let icon: String?
    let avatarUrl: String?
    let slugId: String?

    var id: String { (kind == .user ? "user-" : "page-") + entityId }

    static func from(_ suggestions: SearchSuggestions) -> [MentionSuggestion] {
        let users = (suggestions.users ?? []).map {
            MentionSuggestion(kind: .user, entityId: $0.id, title: $0.name?.isEmpty == false ? $0.name! : ($0.email ?? ""), subtitle: $0.email, icon: nil, avatarUrl: $0.avatarUrl, slugId: nil)
        }
        let pages = (suggestions.pages ?? []).map {
            MentionSuggestion(kind: .page, entityId: $0.id, title: PageTitle.display($0.title), subtitle: $0.space?.name, icon: $0.icon, avatarUrl: nil, slugId: $0.slugId)
        }
        return pages + users
    }
}

/// Media picker the model asks the UI for.
enum PendingMediaAction: Equatable {
    /// Photo library.
    case images, videos
    case camera
    /// Files app.
    case audio, pdf
    /// Any file, always as an attachment card (like "File attachment" on the web).
    case attachment
}

/// Media pick request; its own ID makes a repeat of the same kind (e.g. after a cancel) reopen the picker.
struct MediaRequest: Equatable {
    let id = UUID()
    let action: PendingMediaAction
}

/// Where the files of a closed media picker go.
struct MediaTarget {
    let placement: BlockPlacement
    let asAttachment: Bool
}

/// Where a new block goes.
enum BlockPlacement: Equatable {
    /// In place of the block if it is an empty paragraph, else after it (same container).
    case replaceOrAfter(NodeRef)
    /// After the top-level block containing `NodeRef`, or in its place if that is an empty paragraph.
    case afterTopLevel(NodeRef)
    /// End of the document, before the footnotes.
    case end
}

/// Where the cursor lands after inserting a block.
enum InsertFocus: Equatable {
    /// End of the new block's first text (path relative to the block).
    case inside([Int])
    /// Start of the next block (as the web does after a divider): a paragraph is added if no block follows; editing
    /// ends if the next block isn't text.
    case after
}

/// Editor input sheet (status, math, embed) for inserting or editing.
enum EditorSheet: Identifiable, Equatable {
    /// Inline atom target: insert at the active block's cursor, or edit the block's `index`-th atom of this type.
    enum AtomTarget: Equatable {
        case insert(offset: Int)
        case edit(ref: NodeRef, index: Int)
    }

    /// Block target: insert a new one or change an existing one.
    enum BlockSlot: Equatable {
        case insert(BlockPlacement)
        case edit(NodeRef)
    }

    case status(AtomTarget, text: String, color: String)
    case mathInline(AtomTarget, latex: String)
    case mathBlock(BlockSlot, latex: String)
    case embed(BlockSlot, provider: EmbedProvider, link: String)

    var id: String {
        switch self {
        case .status: "status"
        case .mathInline: "math-inline"
        case .mathBlock: "math-block"
        case .embed: "embed"
        }
    }
}

/// Page view state: the document (REST snapshot, later the engine's), one active text block as a `TextEditor`, and
/// block operations through the engine. Return/Backspace split or join blocks.
@MainActor
@Observable
final class DocumentModel {
    enum ReadOnlyReason: Equatable {
        case noPermission, trash, offline, notConnected
        /// The server runs this Docmost version, newer than the bundled editor (`ReadySession.newerServerVersion`).
        case newerServer(String)
    }

    struct Active: Equatable {
        let ref: NodeRef
        let type: String
        let attrs: [String: JSONValue]?
        /// Path of the enclosing list item (`listItem`/`taskItem`), if any.
        let itemPath: [Int]?
    }

    static let editableTextTypes: Set<String> = ["paragraph", "heading", "detailsSummary"]

    let page: Page
    let engine: (any DocumentEngine)?
    private(set) var document: PMNode
    private(set) var isLive = false
    private(set) var readOnlyReason: ReadOnlyReason?
    private(set) var active: Active?
    var activeText = AttributedString()
    var activeSelection = AttributedTextSelection()
    /// Font the active text block draws with (set by its `TextNodeView`); saving compares system bold against it.
    @ObservationIgnored var activeFont = Font.body
    /// The active code block's text. It lives in `activeText` (without formatting), so the page's one editor edits
    /// code like text and stays the same view from a code block to a text block and back.
    var activeCode: String {
        get { String(activeText.characters) }
        set { activeText = AttributedString(newValue) }
    }
    var cursorRequest: CursorRequest?
    /// Coordinate space of the scroll content; the active editor is measured in it.
    nonisolated static let documentSpace = "document"
    /// Active editor frame (incl. slash/mention menu) in the document space, to center it above the keyboard;
    /// `.zero` until the new editor is measured.
    var activeBlockFrame: CGRect = .zero
    /// Where the page's one text editor lies (`PageEditor`, document space): over the text of the block that reported
    /// it last. Until the newly active block reports its place, the editor stays hidden at the old one.
    var editorFrame: (ref: NodeRef, frame: CGRect)?
    /// How tall the page's text editor draws the active block's text. The block takes this height for its hidden copy
    /// of the text: the copy breaks lines on its own (it hyphenates long words, the editor doesn't), and its height
    /// alone let the typed text hang out of a callout.
    var editorHeight: (ref: NodeRef, height: CGFloat)?
    /// How the page's text editor draws the active block's text.
    var editorStyle = EditorStyle(font: .body, leading: 0, alignment: .leading)
    /// The page text editor's text view, for Backspace at the text's start (`TextInputHooks`).
    @ObservationIgnored weak var editorTextView: UITextView?
    /// Text after "/" before the cursor (at block start or after whitespace, web parity); `nil` = no slash menu.
    private(set) var slashQuery: String?
    /// Character offset of the "/" in the active text.
    @ObservationIgnored private var slashOffset: Int?
    /// Insert menu from the keyboard toolbar "+": the "/" list, but inserting after the block.
    private(set) var showsPlusMenu = false
    /// The insert menu below the active block is open.
    var showsInsertMenu: Bool { slashQuery != nil || showsPlusMenu }
    /// Text after "@" before the cursor; `nil` = no mention suggestions.
    private(set) var mentionQuery: String?
    private(set) var mentionSuggestions: [MentionSuggestion] = []
    /// Suggestions for mentions and page links (set by the page view).
    @ObservationIgnored var suggest: (@MainActor (String) async throws -> SearchSuggestions)?
    @ObservationIgnored var currentUserId: String?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    /// Media picker for the UI; `mediaPlacement` (where files go) stays until the upload; a cancel need not reset it.
    private(set) var pendingMedia: MediaRequest?
    private(set) var mediaPlacement: BlockPlacement?
    /// Open input sheet (status, math, embed); the active block stays active meanwhile.
    var editorSheet: EditorSheet?
    /// Block from the math or embed sheet, inserted once the sheet has closed (`editorSheetDismissed`): switching
    /// editors while it slides away can leave a UIKit animation that never ends, or end editing.
    @ObservationIgnored private var blockAfterSheet: (node: PMNode, placement: BlockPlacement)?
    /// The emoji keyboard is open; the chosen emoji goes into the active text at `emojiOffset`.
    var editsEmoji = false
    @ObservationIgnored private var emojiOffset: Int?
    /// Just after an emoji pick: keeps the block in edit mode until the emoji keyboard is fully gone.
    private(set) var emojiReturning = false
    /// The page should open in the app's web editor (Draw.io and Excalidraw drawings are made there).
    var requestsWebEditor = false
    /// Workspace has the `bases` license feature.
    var canCreateBases = false
    /// The server is Docmost 0.97 or newer: tabs, integration links and sorted sub-pages can be added (an older
    /// server's web couldn't show them).
    var hasDocmost097Features = false
    /// Creates a database (base) as a subpage (`template` "kanban" or `nil`) and returns its page ID.
    @ObservationIgnored var createBase: (@MainActor (String?) async throws -> String)?
    private(set) var isCreatingBase = false
    /// Inline command from the floating "+": runs once the paragraph created for it at the end is active.
    @ObservationIgnored private var pendingInlineCommand: InsertCommand?
    /// Notice after an action (e.g. "Copied"); the page view shows it briefly.
    var notice: String?
    private(set) var errorMessage: String?
    /// Block and time of the link just opened in its text, so the tap doesn't also open the editor.
    var linkTapped: (ref: NodeRef, at: Date)?
    /// The link sheet is open: its URL field takes focus, but editing the block doesn't end.
    var editsLink = false
    /// Same for the comment sheet for the selected text.
    var editsComment = false
    /// A sheet (or the emoji keyboard) has taken focus from the editor, but the block stays active.
    var editsInSheet: Bool { editsLink || editsComment || editorSheet != nil || editsEmoji || emojiReturning }
    /// Set by the page view from the permissions.
    var canComment = false
    /// Read-only pages: toggle blocks the reader opened or closed, by path; not saved (web parity).
    var readerToggles: [[Int]: Bool] = [:]

    /// Offers "Comment" for text selected in the active text block. Not while a sheet (link, comment) has focus: its
    /// text fields would get the menu item too.
    var canCommentOnSelection: Bool {
        guard canComment, !editsInSheet, let active, Self.editableTextTypes.contains(active.type),
              case .ranges(let ranges) = activeSelection.indices(in: activeText)
        else { return false }
        return ranges.ranges.contains { !$0.isEmpty }
    }

    private var overrides: [String: PMNode] = [:]
    @ObservationIgnored private var saveRefused = false
    /// The active block's input that the engine's ended web process took with it; written once the engine syncs again.
    @ObservationIgnored private var unsavedAtEnd: (ref: NodeRef, node: PMNode)?
    private var commitTask: Task<Void, Never>?
    private var pendingFocus: (path: [Int], cursor: CursorRequest)?
    /// The block became active through Return or Backspace in the previous one: the page keeps its place and only
    /// keeps the caret visible, while a tapped block is centered.
    @ObservationIgnored private(set) var activatedByTyping = false
    /// Return and Backspace operations still running (quick typing overlaps them).
    @ObservationIgnored private var typingSwitches = 0
    /// Return or Backspace is switching blocks; meanwhile the old editor briefly shows the line break as a second line.
    var isSwitchingByTyping: Bool { typingSwitches > 0 }
    /// Active block state adopted on undo/redo; writing it back would add a history step and lose "Redo".
    @ObservationIgnored private var adoptedText: AttributedString?
    @ObservationIgnored private var adoptedCode: String?

    init(page: Page, initialDocument: PMNode?, engine: (any DocumentEngine)?, readOnlyReason: ReadOnlyReason?) {
        self.page = page
        self.document = initialDocument ?? PMNode(json: page.content ?? .null) ?? PMNode(type: "doc")
        self.engine = engine
        self.readOnlyReason = readOnlyReason
        if case .newerServer(let version) = readOnlyReason {
            errorMessage = String(localized: "This server runs Docmost \(version). This version of the app can only show its pages; you can edit them in the web editor.")
        }
        // Like a failed start: read-only, and `resume` tries again.
        engine?.onFailure = { [weak self] failure in
            self?.readOnlyReason = .notConnected
            self?.errorMessage = switch failure {
            case .unsupportedContent:
                String(localized: "This page has content that this version of the app can't edit yet. You can edit it in the web editor.")
            case .connectionRefused:
                String(localized: "The server refused the live connection. The page is read-only.")
            }
        }
        // Restart only if live: a page that left reopens on return; one still opening tries again when the app becomes
        // active (or on refresh). Input the engine hadn't saved yet goes in once it is back.
        engine?.onTerminated = { [weak self] in
            guard let self else { return }
            if let active, overrides[active.ref.identity] != nil, let node = currentActiveNode() {
                unsavedAtEnd = (active.ref, node)
            }
            guard isLive else { return }
            suspend()
            resume()
        }
    }

    var isEditable: Bool { engine != nil && isLive && readOnlyReason == nil }
    /// No blocks, or read-only with one empty paragraph. Not `plainText`: a lone mention, image or divider is content.
    var showsEmptyPlaceholder: Bool {
        let blocks = document.children
        return blocks.isEmpty || (!isEditable && blocks.count == 1 && blocks[0].type == "paragraph" && blocks[0].children.isEmpty)
    }
    var status: EngineStatus { engine?.status ?? .idle }
    var participants: [EngineParticipant] { engine?.participants ?? [] }
    var topLevel: [NodeEntry] { NodeEntry.entries(document.children, parentPath: []) }
    /// Top-level blocks without the footnotes list (always last); the arrange sheet's row indices refer to this list.
    var contentBlocks: [NodeEntry] { topLevel.filter { $0.node.type != "footnotes" } }

    // MARK: - Engine

    /// Serializes engine open/close: leaving while it opens (or returning while it closes) never leaves it half-open.
    @ObservationIgnored private var engineStep: Task<Void, Never>?

    /// Opens the engine unless it is open: when the page appears, after `suspend`, and to retry a failed start.
    func resume() {
        let previous = engineStep
        engineStep = Task {
            await previous?.value
            guard let engine, engine.status == .idle || readOnlyReason == .notConnected else { return }
            // Read-only until the reopened engine sends its document, even if one arrived while it was closing.
            isLive = false
            if readOnlyReason == .notConnected {
                readOnlyReason = nil
                errorMessage = nil
            }
            do {
                try await engine.open(pageId: page.id)
            } catch {
                readOnlyReason = .notConnected
                errorMessage = error.userMessage
            }
        }
    }

    /// Page left the screen (closed, under a pushed page, tab switch): read-only until `resume` reopens the engine.
    @discardableResult
    func suspend() -> Task<Void, Never> {
        // Commits pending input in a task queued ahead of the stop below, so the stored document includes it.
        deactivate()
        isLive = false
        let previous = engineStep
        let step = Task {
            await previous?.value
            await stop()
        }
        engineStep = step
        return step
    }

    /// The app went to the background: keeps unsent changes as leaving the page would, with pending input.
    func saveUnsentChanges() async {
        guard let engine, isLive else { return }
        await flush()
        await engine.saveUnsentChanges()
    }

    /// Adopts the engine state; local, unconfirmed changes take precedence.
    func syncFromEngine() {
        guard let engine, let incoming = engine.document else { return }
        document = withOverrides(incoming)
        followMovedBlocks()
        isLive = true
        if let unsaved = unsavedAtEnd {
            unsavedAtEnd = nil
            Task { await commit(unsaved.ref, node: unsaved.node) }
        }
        if let pendingFocus, let node = node(at: pendingFocus.path) {
            self.pendingFocus = nil
            activate(NodeRef(path: pendingFocus.path, node: node), node: node, cursor: pendingFocus.cursor)
            // Floating "+" inline command: runs shortly after the new paragraph's editor has focus; an emoji
            // keyboard or sheet appearing sooner would take that focus away.
            if let command = pendingInlineCommand, let ref = active?.ref {
                pendingInlineCommand = nil
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, self.active?.ref == ref else { return }
                    self.insertInline(command, at: self.activeText.characters.count)
                }
            }
        }
    }

    /// Focuses `path` once the operation that created it is applied; set earlier, `pendingFocus` could hit the old
    /// block in a document event still in flight (e.g. from the commit just before).
    private func focusAfterOperation(_ path: [Int], _ cursor: CursorRequest) async {
        guard await engine?.currentDocument() != nil else { return }
        pendingFocus = (path, cursor)
        syncFromEngine()
        // Not in the engine's current document (gone again at once): a later block there, e.g. a collaborator's, must
        // not jump into editing.
        pendingFocus = nil
    }

    /// Shows and returns whether a block operation applied. Most engine failures carry no error (e.g. a block a
    /// collaborator just deleted), hence one fixed message; the next applied change clears it, but a refused save's
    /// only the next save (Return's new line applying after it must not hide it).
    @discardableResult
    private func report(_ applied: Bool) -> Bool {
        if !applied {
            errorMessage = String(localized: "The change could not be applied.")
        } else if !saveRefused {
            errorMessage = nil
        }
        return applied
    }

    /// The active block follows by its UniqueID when its path shifts; otherwise the editor would edit another block.
    private func followMovedBlocks() {
        if let active, let id = active.ref.id, node(at: active.ref.path)?.string("id") != id {
            if let path = path(where: { $0.string("id") == id }) {
                self.active = Active(ref: NodeRef(path: path, id: id), type: active.type, attrs: active.attrs, itemPath: enclosingItemPath(path))
            } else {
                // A collaborator deleted it. Its editor used to vanish with it; the page's one editor stays, so end here.
                overrides[active.ref.identity] = nil
                commitTask?.cancel()
                deactivate()
            }
        }
        // Without an id (code block, toggle title), another block type or none at the path means a collaborator
        // added or removed a block before it; its input would replace that block, so editing ends unsaved.
        if let active, active.ref.id == nil, node(at: active.ref.path)?.type != active.type {
            overrides[active.ref.identity] = nil
            commitTask?.cancel()
            deactivate()
        }
    }

    /// Path of the first node in document order that `matches`.
    private func path(where matches: (PMNode) -> Bool) -> [Int]? {
        func search(_ node: PMNode, _ path: [Int]) -> [Int]? {
            for (index, child) in node.children.enumerated() {
                if matches(child) { return path + [index] }
                if let found = search(child, path + [index]) { return found }
            }
            return nil
        }
        return search(document, [])
    }

    private func stop() async {
        await flush()
        if let engine {
            // Until its first document (after the sync) the engine holds an empty editor, which would hide the page.
            if engine.document != nil, let latest = await engine.currentDocument() {
                LiveDocuments.store(latest, for: page.id)
            }
            await engine.close()
        }
    }

    // MARK: - Active text

    func activate(_ ref: NodeRef, node: PMNode, cursor: CursorRequest = .end) {
        guard isEditable else { return }
        if active?.ref == ref { return }
        if active != nil { commitPendingNow() }
        let itemPath = enclosingItemPath(ref.path)
        activeBlockFrame = .zero
        activatedByTyping = typingSwitches > 0
        active = Active(ref: ref, type: node.type, attrs: node.attrs, itemPath: itemPath)
        if node.type == "codeBlock" {
            activeCode = node.plainText
        } else {
            activeText = Self.editorText(from: node.children)
        }
        // The page's one editor keeps its selection from block to block; the old indices don't fit this text.
        activeSelection = AttributedTextSelection(insertionPoint: activeText.endIndex)
        slashQuery = nil
        showsPlusMenu = false
        mentionQuery = nil
        mentionSuggestions = []
        cursorRequest = cursor
    }

    /// Editor instance with focus (see `editorFocusChanged`).
    @ObservationIgnored private var focusedEditor: UUID?

    /// Focus change of a text or code editor. Losing focus ends editing only if no instance regains it shortly:
    /// SwiftUI sometimes rebuilds the editor (e.g. scrolled into view in the lazy list); the new one takes focus back.
    func editorFocusChanged(_ focused: Bool, instance: UUID, ref: NodeRef) {
        if focused {
            focusedEditor = instance
            return
        }
        if focusedEditor == instance { focusedEditor = nil }
        if active?.ref == ref {
            guard !editsInSheet else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.active?.ref == ref, self.focusedEditor == nil, !self.editsInSheet else { return }
                self.deactivate()
            }
        }
    }

    func deactivate() {
        guard active != nil else { return }
        commitPendingNow()
        active = nil
        editorHeight = nil
        slashQuery = nil
        showsPlusMenu = false
        mentionQuery = nil
        mentionSuggestions = []
    }

    /// Tap below the last block: cursor to its end if it is text, else a new paragraph at the end.
    func activateTrailing() async {
        guard isEditable else { return }
        if let last = contentBlocks.last, Self.editableTextTypes.contains(last.node.type) {
            if active?.ref == last.ref {
                cursorRequest = .end
            } else {
                activate(last.ref, node: last.node, cursor: .end)
            }
        } else {
            await insertTemplate(.paragraph, placement: .end)
        }
    }

    /// Path of the active block's nearest ancestor of the given type (e.g. a callout).
    func activeAncestorPath(ofType type: String) -> [Int]? {
        active.flatMap { ancestorPath(of: $0.ref.path, types: [type]) }
    }

    /// Sets attributes of a block (`NodeRef(path:id: nil)` targets it by position).
    func setAttributes(of ref: NodeRef, _ attributes: [String: JSONValue]) async {
        guard let engine else { return }
        // The active block's commits are built from its attrs; a stale copy would write the old value back.
        if let active, active.ref.path == ref.path {
            var attrs = active.attrs ?? [:]
            attrs.merge(attributes) { $1 }
            self.active = Active(ref: active.ref, type: active.type, attrs: attrs, itemPath: active.itemPath)
            if overrides[active.ref.identity] != nil { scheduleCommit() }
        }
        report(await engine.setAttributes(ref.target, attributes: attributes))
    }

    /// Backspace with the cursor at the text's start (`TextInputHooks`; the text doesn't change, so `activeTextChanged`
    /// can't notice it): joins the block with the one before, as on the web. False leaves the key to the text view.
    func backspaceAtStart() -> Bool {
        guard let active, active.type != "codeBlock" else { return false }
        Task {
            typingSwitches += 1
            defer { typingSwitches -= 1 }
            await mergeWithPrevious(active)
        }
        return true
    }

    /// Called after every `activeText` change: Return or typing.
    func activeTextChanged() {
        guard let active, active.type != "codeBlock" else { return }
        let characters = activeText.characters
        if let newline = characters.firstIndex(of: "\n") {
            // Return with the slash menu open picks the first enabled item (web parity); the line break is dropped.
            if slashQuery != nil, let first = insertMatches.first(where: isEnabled) {
                let offset = characters.distance(from: characters.startIndex, to: newline)
                activeText.removeSubrange(newline..<characters.index(after: newline))
                activeSelection = AttributedTextSelection(insertionPoint: activeText.characters.index(activeText.startIndex, offsetBy: offset))
                perform(first)
                return
            }
            // Right away: the editor would show the line break as a second line until the next update.
            Task.immediate {
                typingSwitches += 1
                defer { typingSwitches -= 1 }
                await handleReturn(active)
            }
            return
        }
        // Typing closes the "+" menu; the slash menu follows the text.
        showsPlusMenu = false
        updateSlashQuery()
        updateMentionQuery()
        if let adopted = adoptedText {
            adoptedText = nil
            if adopted == activeText { return }
        }
        scheduleCommit()
    }

    /// Called after every `activeSelection` change. The "/" and "@" lists follow the cursor: moved away from their query
    /// without typing, they close. Typed text takes the previous character's link, but at a link's end it continues
    /// outside it, as on the web (the link mark isn't inclusive).
    func activeSelectionChanged() {
        updateSlashQuery()
        updateMentionQuery()
        guard case .insertionPoint(let index) = activeSelection.indices(in: activeText) else { return }
        var typing = activeSelection.typingAttributes(in: activeText)
        guard let link = typing.link, activeText[index...].runs.first?.link != link else { return }
        typing.link = nil
        activeSelection = AttributedTextSelection(insertionPoint: index, typingAttributes: typing)
    }

    // MARK: - Mentions

    private func updateMentionQuery() {
        guard let active, active.type != "codeBlock", slashQuery == nil,
              let newQuery = trigger("@", maxLength: 30, cursor: insertionIndex())?.query
        else {
            mentionQuery = nil
            return
        }
        guard newQuery != mentionQuery else { return }
        mentionQuery = newQuery
        suggestTask?.cancel()
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let suggest = self.suggest else { return }
            if let result = try? await suggest(newQuery), self.mentionQuery == newQuery {
                self.mentionSuggestions = MentionSuggestion.from(result)
            }
        }
    }

    /// Replaces "@query" before the cursor with a mention.
    func insertMention(_ suggestion: MentionSuggestion) {
        guard let query = mentionQuery else { return }
        let cursor = insertionIndex()
        // Only "@query" right before the cursor is replaced, as for "/": anything else would turn other text (or a
        // mention) into the new mention.
        guard let start = activeText.characters.index(cursor, offsetBy: -(query.count + 1), limitedBy: activeText.startIndex),
              String(activeText[start..<cursor].characters) == "@" + query
        else {
            mentionQuery = nil
            mentionSuggestions = []
            return
        }
        var attrs: [String: JSONValue] = [
            "id": .string(UUID().uuidString.lowercased()),
            "label": .string(suggestion.title),
            "entityType": .string(suggestion.kind == .user ? "user" : "page"),
            "entityId": .string(suggestion.entityId),
            "slugId": suggestion.slugId.map { .string($0) } ?? .null,
        ]
        if let currentUserId { attrs["creatorId"] = .string(currentUserId) }
        let node = PMNode(type: "mention", attrs: attrs)
        var run = Self.editorText(from: [node])
        run.append(AttributedString(" "))
        let insertedCount = run.characters.count
        let offset = activeText.characters.distance(from: activeText.startIndex, to: start)
        activeText.transform(updating: &activeSelection) { text in
            text.replaceSubrange(start..<cursor, with: run)
        }
        let newIndex = activeText.characters.index(activeText.startIndex, offsetBy: min(offset + insertedCount, activeText.characters.count))
        activeSelection = AttributedTextSelection(insertionPoint: newIndex)
        mentionQuery = nil
        mentionSuggestions = []
        scheduleCommit(debounce: .zero)
    }

    // MARK: - Insert ("/" and "+")

    /// Where the active block sits: decides which commands fit and where new blocks go.
    enum InsertLocation: Equatable {
        case topLevel
        /// In a list item (its first paragraph must stay a paragraph).
        case listItem
        case tableCell
        /// Footnote text (only paragraphs are allowed there).
        case footnote
        /// Title line of a toggle block.
        case summary
        /// In a callout, quote, toggle block, column or synced block: new blocks go inside it.
        case container
    }

    func insertLocation(of active: Active) -> InsertLocation {
        if active.ref.isTopLevel { return .topLevel }
        if active.type == "detailsSummary" { return .summary }
        let ancestors = ancestorTypes(of: active.ref.path)
        if ancestors.contains("footnotes") { return .footnote }
        if active.itemPath != nil { return .listItem }
        if ancestors.contains("tableCell") || ancestors.contains("tableHeader") { return .tableCell }
        return .container
    }

    /// Types of a node's ancestors, excluding the node.
    func ancestorTypes(of path: [Int]) -> Set<String> {
        var types: Set<String> = []
        var current = document
        for index in path.dropLast() {
            guard current.children.indices.contains(index) else { break }
            current = current.children[index]
            types.insert(current.type)
        }
        return types
    }

    /// Commands that fit at the active block's position; all of them without an active block (floating "+").
    func availableCommands() -> [InsertCommand] {
        var commands = InsertCommand.all
        if !CameraPicker.isAvailable { commands.removeAll { $0 == .camera } }
        if SyncedBlockClipboard.hasAppContent, let index = commands.firstIndex(of: .syncedBlock) {
            commands.insert(.pasteSyncedBlock, at: index + 1)
        }
        if !hasDocmost097Features { commands.removeAll { $0 == .tabs } }
        guard let active else { return commands }
        if active.type == "codeBlock" { commands.removeAll { $0.isInline } }
        let location = insertLocation(of: active)
        if location == .footnote {
            return commands.filter { $0.isInline && $0 != .footnote }
        }
        let ancestors = ancestorTypes(of: active.ref.path)
        if ancestors.contains("transclusionSource") {
            // Nor tabs: synced blocks don't hold them (nor do table cells).
            commands.removeAll { $0 == .syncedBlock || $0 == .pasteSyncedBlock || $0 == .tabs }
        }
        if location == .tableCell { commands.removeAll { $0 == .tabs } }
        if ancestors.contains("columns") || location == .tableCell {
            commands.removeAll { if case .columns = $0 { true } else { false } }
        }
        return commands
    }

    /// Commands of the open menu; for the slash menu, filtered by the query.
    var insertMatches: [InsertCommand] {
        guard showsInsertMenu else { return [] }
        let available = availableCommands()
        guard let slashQuery else { return available }
        return InsertCommand.filtered(available, query: slashQuery)
    }

    /// Database and kanban board need the `bases` license feature; without it they are grayed out (web parity).
    func isEnabled(_ command: InsertCommand) -> Bool {
        switch command {
        case .base, .kanban: canCreateBases && createBase != nil
        default: true
        }
    }

    func togglePlusMenu() {
        guard active != nil, slashQuery == nil else { return }
        showsPlusMenu.toggle()
    }

    private func updateSlashQuery() {
        let found = currentSlash()
        if slashQuery != found?.query { slashQuery = found?.query }
        slashOffset = found?.offset
        if found != nil, showsPlusMenu { showsPlusMenu = false }
    }

    private func currentSlash() -> (query: String, offset: Int)? {
        guard let active, active.type != "codeBlock",
              case .insertionPoint(let cursor) = activeSelection.indices(in: activeText)
        else { return nil }
        return trigger("/", maxLength: 24, cursor: cursor)
    }

    /// `mark` ("/" or "@") before the cursor, at block start or after whitespace (incl. the line break U+2028),
    /// followed by at most `maxLength` non-whitespace characters. The limits only end a menu once a longer word is
    /// typed: 24 is above every command keyword ("/"), 30 above most names ("@").
    private func trigger(_ mark: Character, maxLength: Int, cursor: AttributedString.Index) -> (query: String, offset: Int)? {
        let text = activeText
        let before = Array(text[text.startIndex..<cursor].characters)
        guard let offset = before.lastIndex(of: mark) else { return nil }
        let query = before[(offset + 1)...]
        guard query.count <= maxLength, !query.contains(where: \.isWhitespace) else { return nil }
        guard offset == 0 || before[offset - 1].isWhitespace else { return nil }
        // Mark and query are typed text, never an atom's: a user mention shows as "@label", a status or math may
        // contain either, and an atom between mark and cursor would be lost with the pick.
        let index = text.characters.index(text.startIndex, offsetBy: offset)
        if text[index..<cursor].runs.contains(where: { $0.docmost.inlineNode != nil }) { return nil }
        return (String(query), offset)
    }

    /// Removes "/query" from the active text and returns the offset where it was.
    private func removeSlashQuery() -> Int {
        guard let offset = slashOffset, let query = slashQuery else { return cursorOffset() }
        let characters = activeText.characters
        let length = query.count + 1
        guard offset + length <= characters.count else { return cursorOffset() }
        let start = characters.index(activeText.startIndex, offsetBy: offset)
        let end = characters.index(start, offsetBy: length)
        guard String(activeText[start..<end].characters) == "/" + query else { return cursorOffset() }
        activeText.removeSubrange(start..<end)
        activeSelection = AttributedTextSelection(insertionPoint: activeText.characters.index(activeText.startIndex, offsetBy: offset))
        // Saved like typing: typing usually saved the query, which commands that only end editing (media) would keep.
        scheduleCommit()
        return offset
    }

    /// Cursor offset in the active text, in characters.
    private func cursorOffset() -> Int {
        activeText.characters.distance(from: activeText.startIndex, to: insertionIndex())
    }

    /// Runs a menu item. From "/", block types convert the block where allowed and new blocks go `.replaceOrAfter` at
    /// top level and in containers; otherwise (and from "+") `.afterTopLevel`.
    func perform(_ command: InsertCommand) {
        guard isEnabled(command) else { return }
        guard let active else {
            performAtEnd(command)
            return
        }
        let fromSlash = slashQuery != nil
        let offset = fromSlash ? removeSlashQuery() : cursorOffset()
        slashQuery = nil
        slashOffset = nil
        showsPlusMenu = false
        if command.isInline {
            insertInline(command, at: offset)
            return
        }
        let location = insertLocation(of: active)
        let placement: BlockPlacement = fromSlash && (location == .topLevel || location == .container)
            ? .replaceOrAfter(active.ref) : .afterTopLevel(active.ref)
        if let template = command.conversionTemplate {
            if fromSlash, conversionTemplates.contains(template) {
                convertActive(to: template)
            } else {
                Task { await insertTemplate(template, placement: placement) }
            }
            return
        }
        performBlock(command, placement: placement)
    }

    /// Floating "+" (no active block): blocks go to the end, inline commands into a new paragraph there.
    func performAtEnd(_ command: InsertCommand) {
        guard isEnabled(command) else { return }
        if command.isInline {
            pendingInlineCommand = command
            Task {
                await insertTemplate(.paragraph, placement: .end)
                // Taken once the new paragraph has focus; after a failed insert it must not go into a later block.
                pendingInlineCommand = nil
            }
            return
        }
        if let template = command.conversionTemplate {
            Task { await insertTemplate(template, placement: .end) }
            return
        }
        performBlock(command, placement: .end)
    }

    /// Block types the active block can be turned into in place, for "/" and the toolbar.
    var conversionTemplates: [BlockTemplate] {
        guard let active else { return [] }
        let text: [BlockTemplate] = [.paragraph, .heading1, .heading2, .heading3]
        let lists: [BlockTemplate] = [.bulletList, .orderedList, .taskList]
        switch insertLocation(of: active) {
        case .topLevel, .container: return text + lists + [.quote, .callout, .toggle, .codeBlock]
        case .tableCell: return text + lists
        // An item's content is "paragraph block*": a heading can't start it. As on the web, the item's only line then
        // leaves the list as the heading (`liftLine`); a first line with more below it stays a paragraph.
        case .listItem:
            guard let itemPath = active.itemPath, active.ref.path == itemPath + [0] else { return text + lists }
            return node(at: itemPath)?.children.count == 1 ? text + lists : [.paragraph] + lists
        // A replacement would split the toggle, or ProseMirror turns the footnote text back into a paragraph.
        case .summary, .footnote: return []
        }
    }

    /// Turns the active block into `template`; a list kind on a list item converts the item's whole list.
    func convertActive(to template: BlockTemplate) {
        guard let active else { return }
        if let itemPath = active.itemPath, [.bulletList, .orderedList, .taskList].contains(template) {
            Task { await convertList(itemPath: itemPath, to: template) }
        } else if let itemPath = active.itemPath, active.ref.path == itemPath + [0], [.heading1, .heading2, .heading3].contains(template) {
            Task { await liftLine(itemPath: itemPath, into: template) }
        } else {
            Task { await convert(active.ref, to: template) }
        }
    }

    private func performBlock(_ command: InsertCommand, placement: BlockPlacement) {
        switch command {
        case .block(.divider):
            Task { await insertBlocks([PMNode(type: "horizontalRule")], placement: placement, focus: .after) }
        case .block(.table):
            Task { await insertBlocks([BlockTemplate.table.node()], placement: placement, focus: .inside([0, 0, 0])) }
        case .pageBreak:
            Task { await insertBlocks([PMNode(type: "pageBreak")], placement: placement, focus: .after) }
        case .subpages:
            Task { await insertBlocks([PMNode(type: "subpages")], placement: placement, focus: .after) }
        case .tabs:
            Task { await insertBlocks([Self.tabsNode()], placement: placement, focus: .inside([0, 1, 0])) }
        case .drawio, .excalidraw:
            Task { await insertBlocks([PMNode(type: command == .drawio ? "drawio" : "excalidraw")], placement: placement, focus: .after) }
        case .mermaid:
            // Web parity: a code block with a sample; the page shows the diagram while the code isn't being edited.
            let sample = PMNode(type: "text", text: "flowchart LR\n    A --> B")
            Task { await insertBlocks([PMNode(type: "codeBlock", attrs: ["language": "mermaid"], content: [sample])], placement: placement, focus: .inside([])) }
        case .syncedBlock:
            Task { await insertBlocks([PMNode(type: "transclusionSource", content: [PMNode(type: "paragraph")])], placement: placement, focus: .inside([0])) }
        case .columns(let count):
            Task { await insertBlocks([Self.columnsNode(count: count)], placement: placement, focus: .inside([0, 0])) }
        case .image: requestMedia(.images, placement: placement)
        case .camera: requestMedia(.camera, placement: placement)
        case .video: requestMedia(.videos, placement: placement)
        case .audio: requestMedia(.audio, placement: placement)
        case .pdf: requestMedia(.pdf, placement: placement)
        case .attachment: requestMedia(.attachment, placement: placement)
        case .mathBlock: editorSheet = .mathBlock(.insert(placement), latex: "")
        case .embed(let provider): editorSheet = .embed(.insert(placement), provider: provider, link: "")
        case .base, .kanban: Task { await insertBase(kanban: command == .kanban, placement: placement) }
        case .pasteSyncedBlock: Task { await pasteSyncedBlock(placement: placement) }
        default: break
        }
    }

    // MARK: Inline

    private func insertInline(_ command: InsertCommand, at offset: Int) {
        switch command {
        case .date: insertIntoActiveText(AttributedString(Date.now.formatted(.dateTime.day().month(.wide).year())), offset: offset)
        case .time: insertIntoActiveText(AttributedString(Date.now.formatted(.dateTime.hour().minute())), offset: offset)
        case .emoji:
            emojiOffset = offset
            editsEmoji = true
        case .status: editorSheet = .status(.insert(offset: offset), text: "", color: "gray")
        case .mathInline: editorSheet = .mathInline(.insert(offset: offset), latex: "")
        case .footnote:
            let node = PMNode(type: "footnoteReference", attrs: [
                "data-id": .string(Self.newNodeId()), "referenceNumber": .string("\(footnoteNumber(at: offset))"),
            ])
            insertAtom(node, offset: offset)
        default: break
        }
    }

    /// Inserts text at a character offset of the active text, cursor after it. `plainAfter`: continue unformatted
    /// (after an atom, whose color new text would take on).
    private func insertIntoActiveText(_ run: AttributedString, offset: Int, plainAfter: Bool = false) {
        guard active != nil else { return }
        let count = activeText.characters.count
        let position = min(max(offset, 1), count)
        let index = activeText.characters.index(activeText.startIndex, offsetBy: position)
        activeText.insert(run, at: index)
        let end = activeText.characters.index(activeText.startIndex, offsetBy: min(position + run.characters.count, activeText.characters.count))
        activeSelection = AttributedTextSelection(insertionPoint: end, typingAttributes: plainAfter ? AttributeContainer() : nil)
        scheduleCommit(debounce: .zero)
    }

    /// Inserts an inline atom (status, math, footnote reference) into the active text.
    func insertAtom(_ node: PMNode, offset: Int) {
        insertIntoActiveText(Self.editorText(from: [node]), offset: offset, plainAfter: true)
    }

    // MARK: Integration links (Docmost 0.97)

    /// A tapped integration mention while editing: the page offers to open it or show it otherwise.
    struct MentionTarget: Identifiable, Equatable {
        let ref: NodeRef
        let index: Int
        let url: String
        let provider: String
        var id: String { "\(ref.identity)/\(index)" }
    }

    var mentionActions: MentionTarget?

    enum IntegrationDisplay {
        case card, mention, link
    }

    static func integrationMention(url: String, provider: String) -> PMNode {
        PMNode(type: "integrationMention", attrs: ["url": .string(url), "provider": .string(provider)])
    }

    static func integrationCard(url: String, provider: String) -> PMNode {
        PMNode(type: "integrationCard", attrs: ["url": .string(url), "provider": .string(provider)])
    }

    /// The link as text, with its service as the web keeps it.
    static func integrationLinkText(url: String, provider: String) -> PMNode {
        var attrs: [String: JSONValue] = ["href": .string(url), "target": "_blank", "internal": false]
        if !provider.isEmpty { attrs["integrationProvider"] = .string(provider) }
        return PMNode(type: "text", marks: [PMMark(type: "link", attrs: attrs)], text: url)
    }

    /// Shows an integration card as a mention or a link, in a paragraph of its own.
    func showIntegrationCard(_ ref: NodeRef, as display: IntegrationDisplay) async {
        guard display != .card, let (_, card) = locate(ref) else { return }
        let url = card.string("url") ?? "", provider = card.string("provider") ?? ""
        let inline = display == .mention ? Self.integrationMention(url: url, provider: provider) : Self.integrationLinkText(url: url, provider: provider)
        await replace(ref, withNodes: [PMNode(type: "paragraph", content: [inline])])
    }

    /// Shows a mention as a link in its place, or as a card that splits its paragraph there (`blockReplacement`).
    func showMention(_ target: MentionTarget, as display: IntegrationDisplay) async {
        switch display {
        case .mention:
            return
        case .link:
            await replaceAtom(ofType: "integrationMention", in: target.ref, index: target.index,
                              with: Self.integrationLinkText(url: target.url, provider: target.provider))
        case .card:
            guard let nodes = cardReplacement(for: target) else { return }
            await replace(target.ref, withNodes: nodes)
        }
    }

    /// Whether the mention can become a card where it is.
    func canShowAsCard(_ target: MentionTarget) -> Bool {
        cardReplacement(for: target) != nil
    }

    private func cardReplacement(for target: MentionTarget) -> [PMNode]? {
        guard let (_, block) = locate(target.ref) else { return nil }
        var seen = -1
        guard let position = block.children.firstIndex(where: { child in
            guard child.type == "integrationMention" else { return false }
            seen += 1
            return seen == target.index
        }) else { return nil }
        return blockReplacement(Self.integrationCard(url: target.url, provider: target.provider), paragraph: target.ref,
                                before: Array(block.children[..<position]), after: Array(block.children[(position + 1)...]))
    }

    /// The service of the link at `range` of the active text that the workspace can show as a card or mention: the
    /// link's own (`integrationProvider`) or its host's, if that integration is installed, as on the web.
    func integrationProvider(ofLinkIn range: Range<AttributedString.Index>) -> String? {
        guard hasDocmost097Features, let previews = linkPreviews, let run = activeText[range].runs.first, let url = run.link
        else { return nil }
        let provider = run.docmost.linkProvider
            ?? IntegrationLinks.describe(url.absoluteString, unfurlHosts: previews.unfurlHosts).provider?.rawValue
        guard let provider, previews.installedTypes.contains(provider) else { return nil }
        return provider
    }

    /// Whether the link at `range` of the active text can become a card where it is.
    func canShowLinkAsCard(in range: Range<AttributedString.Index>) -> Bool {
        guard let active else { return false }
        let (before, after) = activeInlines(around: range)
        return blockReplacement(PMNode(type: "integrationCard"), paragraph: active.ref, before: before, after: after) != nil
    }

    /// Shows the link at `range` of the active text as a mention or a card, as the web's "Display as" does.
    func showLink(in range: Range<AttributedString.Index>, provider: String, as display: IntegrationDisplay) {
        guard let url = activeText[range].runs.first?.link?.absoluteString else { return }
        switch display {
        case .link:
            return
        case .mention:
            let offset = activeText.characters.distance(from: activeText.startIndex, to: range.lowerBound)
            activeText.removeSubrange(range)
            insertIntoActiveText(Self.editorText(from: [Self.integrationMention(url: url, provider: provider)]), at: offset)
        case .card:
            placeBlockInActiveText(Self.integrationCard(url: url, provider: provider), replacing: range)
        }
    }

    // MARK: Blocks in a paragraph (cards, inline databases)

    /// The blocks that take a paragraph's place when a card or inline database goes into it, as on the web: the text
    /// before (without its trailing spaces), the block, the text after (without its leading spaces), each part only if
    /// it isn't empty. Nil where the web places none: outside a paragraph, in table cells, synced blocks and footnotes,
    /// and in place of a list item's first line.
    private func blockReplacement(_ block: PMNode, paragraph ref: NodeRef, before: [PMNode], after: [PMNode]) -> [PMNode]? {
        guard ref.type == "paragraph", let (path, paragraph) = locate(ref),
              ancestorTypes(of: path).isDisjoint(with: ["tableCell", "tableHeader", "transclusionSource", "footnote", "footnotes"])
        else { return nil }
        let before = Self.trimmingSpaces(before, atEnd: true), after = Self.trimmingSpaces(after, atEnd: false)
        if before.isEmpty, path.last == 0, let parent = node(at: Array(path.dropLast())), ["listItem", "taskItem"].contains(parent.type) {
            return nil
        }
        return (before.isEmpty ? [] : [PMNode(type: "paragraph", attrs: paragraph.attrs, content: before)]) + [block]
            + (after.isEmpty ? [] : [PMNode(type: "paragraph", attrs: paragraph.attrs, content: after)])
    }

    /// Inline nodes without the spaces at one end (text nodes only, as the web trims them).
    private static func trimmingSpaces(_ inlines: [PMNode], atEnd: Bool) -> [PMNode] {
        var inlines = inlines
        while let index = atEnd ? inlines.indices.last : inlines.indices.first, inlines[index].type == "text" {
            let text = inlines[index].text ?? ""
            let trimmed = atEnd ? String(text.reversed().drop(while: \.isWhitespace).reversed()) : String(text.drop(while: \.isWhitespace))
            if !trimmed.isEmpty {
                inlines[index] = PMNode(type: "text", marks: inlines[index].marks, text: trimmed)
                break
            }
            inlines.remove(at: index)
        }
        return inlines
    }

    /// The active text's inline nodes before and after `range`.
    private func activeInlines(around range: Range<AttributedString.Index>) -> (before: [PMNode], after: [PMNode]) {
        (Self.inlines(from: AttributedString(activeText[activeText.startIndex..<range.lowerBound]), base: activeFont),
         Self.inlines(from: AttributedString(activeText[range.upperBound..<activeText.endIndex]), base: activeFont))
    }

    /// Whether a card or inline database can take the place of `length` characters at the active text's `offset`.
    private func blockFits(replacing offset: Int, length: Int = 0) -> Bool {
        guard let active, offset >= 0, offset + length <= activeText.characters.count else { return false }
        let start = activeText.characters.index(activeText.startIndex, offsetBy: offset)
        let (before, after) = activeInlines(around: start..<activeText.characters.index(start, offsetBy: length))
        return blockReplacement(PMNode(type: "integrationCard"), paragraph: active.ref, before: before, after: after) != nil
    }

    /// Puts a card or inline database in place of `range` of the active text (an empty range: at the cursor), splitting
    /// the paragraph there (`blockReplacement`). The cursor goes to the text after it: the paragraph's rest, else the
    /// next text block, else a new paragraph if nothing follows (as after inserting other blocks).
    @discardableResult
    private func placeBlockInActiveText(_ block: PMNode, replacing range: Range<AttributedString.Index>) -> Bool {
        guard let engine, let active, let (path, paragraph) = locate(active.ref) else { return false }
        let (before, after) = activeInlines(around: range)
        guard var nodes = blockReplacement(block, paragraph: active.ref, before: before, after: after),
              let blockOffset = nodes.firstIndex(of: block)
        else { return false }
        let parentPath = Array(path.dropLast()), index = path[path.count - 1]
        let afterPath = parentPath + [index + blockOffset + 1]
        var focus: [Int]? = afterPath
        if nodes.last == block {
            let siblings = parentPath.isEmpty ? document.children : node(at: parentPath)?.children ?? []
            if siblings.indices.contains(index + 1), siblings[index + 1].type != "footnotes" {
                if !Self.editableTextTypes.contains(siblings[index + 1].type) { focus = nil }
            } else {
                nodes.append(PMNode(type: "paragraph"))
            }
        }
        // The new blocks hold the active text: its pending input isn't written on its own.
        dropActive()
        slashQuery = nil
        showsPlusMenu = false
        let target = NodeRef(path: path, node: paragraph).target
        Task {
            if report(await engine.replaceBlock(target, withNodes: nodes)), let focus {
                await focusAfterOperation(focus, .start)
            }
        }
        return true
    }

    // MARK: Pasted links

    /// A pasted link the page asks about, where the web's paste menu offers a choice (Docmost 0.97): a link of an
    /// installed integration (card, mention or the link itself) or a link to a database page (its mention or an inline
    /// database). The paste is in already (`text` at `offset`: the link, or the page's mention); a choice replaces it.
    struct PastedLink: Identifiable, Equatable {
        let url: URL
        let provider: IntegrationLinks.Provider?
        /// The database page the link points to.
        let base: LinkedPage?
        /// A card or inline database can take the paste's place (`blockReplacement`).
        let allowsBlock: Bool
        let ref: NodeRef
        let offset: Int
        /// What the paste put in, to find it again.
        let text: String
        var id: String { url.absoluteString }
    }

    /// A page of this server a pasted link points to, for its mention.
    struct LinkedPage: Equatable {
        let id: String
        let slugId: String?
        let title: String
        let anchor: String?
    }

    enum PasteChoice {
        case card, mention, link, embeddedBase
    }

    /// Asked by the page while set (`finishPastedLink`).
    private(set) var pastedLink: PastedLink?
    /// The server's installed integrations; set by the page.
    @ObservationIgnored var linkPreviews: LinkPreviewStore?
    /// The page a link of this server points to (page mentions, database links); set by the page.
    @ObservationIgnored var lookUpPage: (@MainActor (String) async -> Page?)?
    @ObservationIgnored var serverURL: URL?

    /// The paste proxy's question for clipboard text that is a single web link: true if the page inserts it itself, as
    /// the web does, false for a plain paste. Over selected text the link goes onto that text. Otherwise the link goes in
    /// as a link at once; then a link of an installed integration (Docmost 0.97, in a paragraph) asks how to show it,
    /// and a link to a page of this server becomes a mention of the page once found (a database page then offers to
    /// embed it, on 0.97). The paste always changes the text right away: text changed only after a paste that inserted
    /// nothing left the editor's text view sending typed characters nowhere.
    func pasteLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let active, active.type != "codeBlock", !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        if linkSelection(to: url) { return true }
        let offset = cursorOffset()
        var provider: IntegrationLinks.Provider?
        if hasDocmost097Features, active.type == "paragraph", let previews = linkPreviews {
            provider = IntegrationLinks.provider(of: trimmed, installed: previews.installedTypes, unfurlHosts: previews.unfurlHosts)
        }
        let pasted = insertLinkText(url, provider: provider, at: offset)
        if let provider {
            pastedLink = PastedLink(url: url, provider: provider, base: nil, allowsBlock: blockFits(replacing: offset, length: pasted.count),
                                    ref: active.ref, offset: offset, text: pasted)
            return true
        }
        guard let serverURL, let lookUpPage, let slugId = Self.pageSlugId(of: url, serverURL: serverURL) else { return true }
        let ref = active.ref
        Task {
            // A page that can't be found (or not seen) stays a link, as on the web.
            guard let page = await lookUpPage(slugId), self.active?.ref == ref, let range = activeRange(offset: offset, text: pasted)
            else { return }
            let linked = LinkedPage(id: page.id, slugId: page.slugId, title: page.title ?? "", anchor: url.fragment)
            let mention = Self.editorText(from: [pageMention(linked)])
            replaceActiveText(range, with: mention)
            keyboardFollowsText()
            if hasDocmost097Features, page.isBase == true, blockFits(replacing: offset, length: mention.characters.count) {
                pastedLink = PastedLink(url: url, provider: nil, base: linked, allowsBlock: true, ref: ref, offset: offset,
                                        text: String(mention.characters))
            }
        }
        return true
    }

    /// The page a link of this server points to, as the web matches it: a query such as `?commentId=` or a database
    /// entry's `?row=` doesn't count.
    private static func pageSlugId(of url: URL, serverURL: URL) -> String? {
        switch ContentLinkRouter.destination(for: url, serverURL: serverURL) {
        case .page(let slugId, _), .comment(let slugId, _): slugId
        case .databaseEntry(let basePageId, _): basePageId
        default: nil
        }
    }

    /// A mention of the page, as the web makes one from a pasted link ("Untitled" unlocalized as there).
    private func pageMention(_ page: LinkedPage) -> PMNode {
        var attrs: [String: JSONValue] = [
            "id": .string(UUID().uuidString.lowercased()),
            "label": .string(page.title.isEmpty ? "Untitled" : page.title),
            "entityType": "page",
            "entityId": .string(page.id),
            "slugId": page.slugId.map { .string($0) } ?? .null,
        ]
        if let currentUserId { attrs["creatorId"] = .string(currentUserId) }
        if let anchor = page.anchor, !anchor.isEmpty { attrs["anchorId"] = .string(anchor) }
        return PMNode(type: "mention", attrs: attrs)
    }

    /// Replaces the paste as chosen; nil (the question dismissed) keeps it.
    func finishPastedLink(_ choice: PasteChoice?) {
        guard let link = pastedLink else { return }
        pastedLink = nil
        guard let choice, active?.ref == link.ref, let range = activeRange(offset: link.offset, text: link.text) else { return }
        let url = link.url.absoluteString, provider = link.provider?.rawValue ?? ""
        switch choice {
        case .card:
            placeBlockInActiveText(Self.integrationCard(url: url, provider: provider), replacing: range)
        case .embeddedBase:
            if let base = link.base {
                placeBlockInActiveText(PMNode(type: "base", attrs: ["pageId": .string(base.id)]), replacing: range)
            }
        case .mention:
            // A database link is its mention already.
            if link.base == nil {
                replaceActiveText(range, with: Self.editorText(from: [Self.integrationMention(url: url, provider: provider)]))
            }
        case .link:
            break
        }
    }

    /// After the active text changed without the user (an answer arriving), the keyboard still works on the old text:
    /// what was typed next went nowhere until the user moved the cursor. Reloading it makes it read the text again,
    /// once the text view shows the new text (reloaded before, it read the old one again).
    private func keyboardFollowsText() {
        let expected = String(activeText.characters)
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let view = self?.editorTextView else { return }
                if view.text == expected {
                    view.reloadInputViews()
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// The range of `text` at `offset` of the active text, if it is still there.
    private func activeRange(offset: Int, text: String) -> Range<AttributedString.Index>? {
        guard offset >= 0, offset + text.count <= activeText.characters.count else { return nil }
        let start = activeText.characters.index(activeText.startIndex, offsetBy: offset)
        let end = activeText.characters.index(start, offsetBy: text.count)
        return String(activeText[start..<end].characters) == text ? start..<end : nil
    }

    /// Replaces part of the active text, the cursor staying where it is; right after the new part, typing continues
    /// plain (not as part of an atom).
    private func replaceActiveText(_ range: Range<AttributedString.Index>, with run: AttributedString) {
        let cursorAtEnd = insertionIndex() == range.upperBound
        let start = activeText.characters.distance(from: activeText.startIndex, to: range.lowerBound)
        activeText.transform(updating: &activeSelection) { $0.replaceSubrange(range, with: run) }
        if cursorAtEnd {
            let end = activeText.characters.index(activeText.startIndex, offsetBy: start + run.characters.count)
            activeSelection = AttributedTextSelection(insertionPoint: end, typingAttributes: AttributeContainer())
        }
        scheduleCommit(debounce: .zero)
    }

    /// A link pasted over selected text links that text, as on the web.
    private func linkSelection(to url: URL) -> Bool {
        guard case .ranges(let ranges) = activeSelection.indices(in: activeText) else { return false }
        let selected = ranges.ranges.filter { !$0.isEmpty }
        guard !selected.isEmpty else { return false }
        for range in selected { activeText[range].link = url }
        scheduleCommit(debounce: .zero)
        return true
    }

    /// The link as linked text, remembering its service as the web does (`integrationProvider`); returns the text.
    @discardableResult
    private func insertLinkText(_ url: URL, provider: IntegrationLinks.Provider?, at offset: Int) -> String {
        var run = AttributedString(url.absoluteString)
        run.link = url
        if let provider { run.docmost.linkProvider = provider.rawValue }
        insertIntoActiveText(run, at: offset)
        return url.absoluteString
    }

    /// Inserts at `offset` (0: the start) and puts the cursor after it, with plain typing attributes.
    private func insertIntoActiveText(_ run: AttributedString, at offset: Int) {
        guard active != nil else { return }
        let position = min(max(offset, 0), activeText.characters.count)
        activeText.insert(run, at: activeText.characters.index(activeText.startIndex, offsetBy: position))
        let end = activeText.characters.index(activeText.startIndex, offsetBy: min(position + run.characters.count, activeText.characters.count))
        activeSelection = AttributedTextSelection(insertionPoint: end, typingAttributes: AttributeContainer())
        scheduleCommit(debounce: .zero)
    }

    /// Applies the emoji keyboard's pick (`nil`: closed without one). The editor regains focus only once that
    /// keyboard is fully gone; otherwise focus flips back and forth and editing ends.
    func finishEmoji(_ emoji: String?) {
        guard editsEmoji else { return }
        let offset = emojiOffset
        emojiOffset = nil
        editsEmoji = false
        emojiReturning = true
        if let emoji, let offset { insertIntoActiveText(AttributedString(emoji), offset: offset) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.emojiReturning = false
        }
    }

    /// Result of the status or math sheet: insert, replace, or (for `nil`) remove.
    func applyAtom(_ node: PMNode?, type: String, target: EditorSheet.AtomTarget) async {
        switch target {
        case .insert(let offset):
            if let node { insertAtom(node, offset: offset) }
        case .edit(let ref, let index):
            await replaceAtom(ofType: type, in: ref, index: index, with: node)
        }
    }

    func atom(ofType type: String, in ref: NodeRef, index: Int) -> PMNode? {
        guard let (_, node) = locate(ref) else { return nil }
        let atoms = node.children.filter { $0.type == type }
        return atoms.indices.contains(index) ? atoms[index] : nil
    }

    /// Replaces or removes the `index`-th atom of type `type` in a (non-active) block.
    func replaceAtom(ofType type: String, in ref: NodeRef, index: Int, with replacement: PMNode?) async {
        guard let engine, let (path, node) = locate(ref) else { return }
        var children = node.children
        var seen = -1
        guard let position = children.firstIndex(where: { child in
            guard child.type == type else { return false }
            seen += 1
            return seen == index
        }) else { return }
        if let replacement { children[position] = replacement } else { children.remove(at: position) }
        let updated = PMNode(type: node.type, attrs: node.attrs, content: children.isEmpty ? nil : children)
        report(await engine.replaceBlock(NodeRef(path: path, node: node).target, with: updated))
    }

    /// Number for a new footnote reference: references before it plus one (the engine renumbers afterwards).
    private func footnoteNumber(at offset: Int) -> Int {
        guard let active else { return 1 }
        var count = 0
        func walk(_ node: PMNode, path: [Int]) {
            for (index, child) in node.children.enumerated() where child.type != "footnotes" {
                if child.type == "footnoteReference" {
                    if Self.precedes(path, active.ref.path) { count += 1 }
                } else {
                    walk(child, path: path + [index])
                }
            }
        }
        walk(document, path: [])
        let position = min(max(offset, 0), activeText.characters.count)
        let end = activeText.characters.index(activeText.startIndex, offsetBy: position)
        for run in activeText[activeText.startIndex..<end].runs {
            if let json = run.docmost.inlineNode, json.contains("\"footnoteReference\"") { count += 1 }
        }
        return count + 1
    }

    /// New ID like `generateNodeId` in the web client (12 lowercase letters).
    static func newNodeId() -> String {
        String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    }

    // MARK: Blocks

    /// Inserts blocks at `placement`, then moves the cursor per `focus`; without `focus`, editing ends.
    func insertBlocks(_ nodes: [PMNode], placement: BlockPlacement, focus: InsertFocus?) async {
        guard let engine, !nodes.isEmpty else { return }
        let anchor: NodeRef?
        switch placement {
        case .replaceOrAfter(let ref):
            anchor = locate(ref).map { NodeRef(path: $0.path, node: $0.node) }
        case .afterTopLevel(let ref):
            let top = [ref.path[0]]
            anchor = node(at: top).map { NodeRef(path: top, node: $0) }
        case .end:
            // The empty paragraph the editor keeps at the end becomes the new paragraph; other blocks go before it.
            // Never replaced: this copy can lag behind the engine, and a collaborator may just have typed there.
            anchor = contentBlocks.last.flatMap { last in
                last.node.type == "paragraph" && last.node.children.isEmpty && active?.ref != last.ref ? last.ref : nil
            }
            if let anchor, nodes == [PMNode(type: "paragraph")] {
                await focusAfterOperation(anchor.path, .end)
                return
            }
        }
        let before = placement == .end
        var replace = false
        if !before, let anchor, let latest = latestNode(at: anchor.path), latest.type == "paragraph", latest.children.isEmpty {
            replace = true
        }
        let newPath: [Int]
        let next: PMNode?
        if let anchor {
            let index = anchor.path[anchor.path.count - 1]
            let parentPath = Array(anchor.path.dropLast())
            let siblings = parentPath.isEmpty ? document.children : node(at: parentPath)?.children ?? []
            let nextIndex = before ? index : index + 1
            newPath = parentPath + [replace ? index : nextIndex]
            next = siblings.indices.contains(nextIndex) ? siblings[nextIndex] : nil
        } else {
            newPath = [contentBlocks.count]
            next = nil
        }
        var blocks = nodes
        var focusTarget: (path: [Int], cursor: CursorRequest)?
        var afterPath = newPath
        afterPath[afterPath.count - 1] += nodes.count
        switch focus {
        case .inside(let relative):
            focusTarget = (newPath + relative, .end)
        case .after:
            if let next, next.type != "footnotes" {
                if Self.editableTextTypes.contains(next.type) { focusTarget = (afterPath, .start) }
            } else {
                blocks.append(PMNode(type: "paragraph"))
                focusTarget = (afterPath, .start)
            }
        case nil:
            break
        }
        if let active {
            if replace, active.ref.path == anchor?.path {
                // The block goes away: stop writing its input.
                dropActive()
                slashQuery = nil
                showsPlusMenu = false
            } else if focusTarget == nil {
                deactivate()
            }
            // Otherwise it stays active until the new block takes focus (the keyboard stays up).
        }
        let applied: Bool
        if replace, let anchor {
            applied = await engine.replaceBlock(anchor.target, withNodes: blocks)
        } else if let anchor {
            applied = await engine.insertBlocks(blocks, relativeTo: anchor.target, position: before ? .before : .after)
        } else {
            applied = await engine.insertBlocks(blocks, relativeTo: nil, position: .after)
        }
        if report(applied), let focusTarget {
            await focusAfterOperation(focusTarget.path, focusTarget.cursor)
        }
    }

    /// Inserts an empty `template` block and puts the cursor in its first text.
    func insertTemplate(_ template: BlockTemplate, placement: BlockPlacement) async {
        await insertBlocks([template.node()], placement: placement, focus: template.firstTextPath.map { .inside($0) } ?? .after)
    }

    static func columnsNode(count: Int) -> PMNode {
        PMNode(type: "columns", attrs: ["layout": .string(defaultColumnsLayout(count))],
               content: (0..<count).map { _ in PMNode(type: "column", content: [PMNode(type: "paragraph")]) })
    }

    static func defaultColumnsLayout(_ count: Int) -> String {
        switch count {
        case 3: "three_equal"
        case 4: "four_equal"
        case 5: "five_equal"
        default: "two_equal"
        }
    }

    /// Result of the math block sheet: insert, change, or (for `nil`) delete.
    func applyMathBlock(_ latex: String?, slot: EditorSheet.BlockSlot) {
        switch slot {
        case .insert(let placement):
            guard let latex, !latex.isEmpty else { return }
            blockAfterSheet = (PMNode(type: "mathBlock", attrs: ["text": .string(latex)]), placement)
        case .edit(let ref):
            Task { if let latex { await setAttributes(of: ref, ["text": .string(latex)]) } else { await delete(ref) } }
        }
    }

    /// Result of the embed sheet: a new embed as in the web client (`setEmbed`) or a changed link.
    func applyEmbed(provider: EmbedProvider, link: String, slot: EditorSheet.BlockSlot) {
        switch slot {
        case .insert(let placement):
            let node = PMNode(type: "embed", attrs: [
                "src": .string(link), "provider": .string(provider.rawValue), "align": "center", "width": 800, "height": 600,
            ])
            blockAfterSheet = (node, placement)
        case .edit(let ref):
            Task { await setAttributes(of: ref, ["src": .string(link)]) }
        }
    }

    /// The editor sheet closed (applied, canceled or swiped down): a block from it goes in now.
    func editorSheetDismissed() {
        guard let block = blockAfterSheet else { return }
        blockAfterSheet = nil
        Task { await insertBlocks([block.node], placement: block.placement, focus: .after) }
    }

    /// Creates a database (base) or kanban board as a subpage, like the web client, and embeds it.
    private func insertBase(kanban: Bool, placement: BlockPlacement) async {
        guard let createBase else { return }
        isCreatingBase = true
        defer { isCreatingBase = false }
        do {
            let pageId = try await createBase(kanban ? "kanban" : nil)
            await insertBlocks([PMNode(type: "base", attrs: ["pageId": .string(pageId)])], placement: placement, focus: .after)
        } catch {
            notice = String(localized: "The database could not be created: \(error.userMessage)")
        }
    }

    // MARK: Media

    /// Picks media (photo library, camera, Files app); after uploading, the files go to `placement`.
    func requestMedia(_ action: PendingMediaAction, placement: BlockPlacement) {
        if active != nil { deactivate() }
        mediaPlacement = placement
        pendingMedia = MediaRequest(action: action)
    }

    /// Takes the request's placement and kind once its picker has closed: a second media command during the upload
    /// then gets its own instead of taking over (and clearing) this one.
    func takeMediaTarget() -> MediaTarget {
        defer { cancelMedia() }
        return MediaTarget(placement: mediaPlacement ?? .end, asAttachment: pendingMedia?.action == .attachment)
    }

    /// Inserts uploads in selection order: as attachment cards after "File attachment" (like the web client),
    /// otherwise embedded by type.
    func insertUploads(_ attachments: [Attachment], to target: MediaTarget) async {
        guard !attachments.isEmpty else { return }
        await insertBlocks(attachments.map { $0.contentNode(asAttachment: target.asAttachment) }, placement: target.placement, focus: nil)
    }

    func cancelMedia() {
        mediaPlacement = nil
        pendingMedia = nil
    }

    // MARK: Synced blocks

    /// Embeds a synced block copied in the app at the placement.
    func pasteSyncedBlock(placement: BlockPlacement) async {
        guard let reference = SyncedBlockClipboard.read() else {
            notice = String(localized: "There is no synced block on the clipboard.")
            return
        }
        await insertSyncedReference(reference, placement: placement)
    }

    func insertSyncedReference(_ reference: SyncedBlockClipboard.Reference, placement: BlockPlacement) async {
        let node = PMNode(type: "transclusionReference", attrs: [
            "sourcePageId": .string(reference.sourcePageId), "transclusionId": .string(reference.transclusionId),
        ])
        await insertBlocks([node], placement: placement, focus: .after)
    }

    /// Reference pasted into the active text: embeds it as a synced block in its place (or after it).
    func pasteSyncedReferenceIntoActive(_ reference: SyncedBlockClipboard.Reference) {
        guard let active else { return }
        let location = insertLocation(of: active)
        let placement: BlockPlacement = location == .topLevel || location == .container ? .replaceOrAfter(active.ref) : .afterTopLevel(active.ref)
        Task { await insertSyncedReference(reference, placement: placement) }
    }

    /// Turns the active top-level block into a synced block (like "Turn into" in the web client).
    func wrapActiveInSyncedBlock() async {
        guard let engine, let active, active.ref.isTopLevel, let node = latestNode(at: active.ref.path) else { return }
        dropActive()
        if report(await engine.replaceBlock(active.ref.target, with: PMNode(type: "transclusionSource", content: [node]))) {
            await focusAfterOperation(active.ref.path + [0], .end)
        }
    }

    /// Unsyncs a synced block's source: its content, including unsaved input inside, stays as normal blocks.
    func unsyncSource(_ ref: NodeRef) async {
        guard let (path, _) = locate(ref), let latest = latestNode(at: path) else { return }
        await replace(ref, withNodes: latest.children.isEmpty ? [PMNode(type: "paragraph")] : latest.children)
    }

    /// Unsyncs an embedded synced block once the server returned its content. It has no id, so it is looked up
    /// again: a collaborator (or an edit before it) may have moved or removed it meanwhile.
    func unsyncReference(_ reference: PMNode, at ref: NodeRef, content nodes: [PMNode]) async {
        guard let path = node(at: ref.path) == reference ? ref.path : path(where: { $0 == reference }) else { return }
        await replace(NodeRef(path: path, node: reference), withNodes: nodes)
    }

    /// Replaces a block with others (unsyncing: the content instead of the wrapper or the reference).
    func replace(_ ref: NodeRef, withNodes nodes: [PMNode]) async {
        guard let engine, let (path, node) = locate(ref) else { return }
        if active != nil { deactivate() }
        report(await engine.replaceBlock(NodeRef(path: path, node: node).target, withNodes: nodes))
    }

    // MARK: Columns

    /// Changes the column count like the web client: new columns are empty, removed ones merge into the last kept one.
    func setColumnCount(_ count: Int, at path: [Int]) async {
        guard let engine, (2...5).contains(count), let columns = latestNode(at: path), columns.type == "columns",
              count != columns.children.count
        else { return }
        let current = columns.children
        var children: [PMNode]
        if count > current.count {
            children = current + (current.count..<count).map { _ in PMNode(type: "column", content: [PMNode(type: "paragraph")]) }
        } else {
            children = Array(current.prefix(count - 1))
            var merged = current[count - 1].children
            for column in current[count...] {
                merged += column.children.filter { $0.type != "paragraph" || !$0.children.isEmpty }
            }
            children.append(PMNode(type: "column", content: merged))
        }
        var attrs = columns.attrs ?? [:]
        attrs["layout"] = .string(Self.defaultColumnsLayout(count))
        if let active, active.ref.path.starts(with: path), active.ref.path.count > path.count, active.ref.path[path.count] >= count - 1 {
            // The active block is in a column that gets merged: end editing.
            deactivate()
        }
        report(await engine.replaceBlock(.path(path), with: PMNode(type: "columns", attrs: attrs, content: children)))
    }

    // MARK: Tabs

    /// A new tabs block as the web makes it: "Tab 1" and "Tab 2", each with an empty paragraph.
    static func tabsNode() -> PMNode {
        PMNode(type: "tabs", content: [tabNode(label: "Tab 1"), tabNode(label: "Tab 2")])
    }

    /// A tab without an id (Docmost gives it one): its label and a panel with an empty paragraph.
    static func tabNode(label: String, panel: [PMNode] = [PMNode(type: "paragraph")]) -> PMNode {
        PMNode(type: "tab", content: [
            PMNode(type: "tabLabel", content: label.isEmpty ? nil : [PMNode(type: "text", text: label)]),
            PMNode(type: "tabPanel", content: panel),
        ])
    }

    /// The label of a tab node as plain text.
    static func tabLabel(of tab: PMNode) -> String {
        tab.children.first { $0.type == "tabLabel" }?.plainText ?? ""
    }

    /// Adds a tab at the end like the web's "+" ("Tab N", unlocalized as there); returns its path.
    @discardableResult
    func addTab(to tabsRef: NodeRef) async -> [Int]? {
        guard let engine, let (path, tabs) = locate(tabsRef), let last = tabs.children.last else { return nil }
        if active != nil { deactivate() }
        let lastRef = NodeRef(path: path + [tabs.children.count - 1], node: last)
        let tab = Self.tabNode(label: "Tab \(tabs.children.count + 1)")
        return report(await engine.insertBlock(tab, relativeTo: lastRef.target, position: .after)) ? path + [tabs.children.count] : nil
    }

    /// Sets a tab's label; empty or unchanged labels are left alone, as on the web.
    func renameTab(_ tabRef: NodeRef, to label: String) async {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, let (path, tab) = locate(tabRef), !label.isEmpty, label != Self.tabLabel(of: tab),
              let index = tab.children.firstIndex(where: { $0.type == "tabLabel" })
        else { return }
        let labelRef = NodeRef(path: path + [index], node: tab.children[index])
        report(await engine.replaceBlock(labelRef.target, with: PMNode(type: "tabLabel", content: [PMNode(type: "text", text: label)])))
    }

    /// A copy right after the tab, as the web's "Duplicate": same label and content, new ids.
    func duplicateTab(_ tabRef: NodeRef) async {
        await duplicate(tabRef)
    }

    /// Moves a tab before or after another tab of the same block.
    func moveTab(_ tabRef: NodeRef, to destination: NodeRef, before: Bool) async {
        guard let engine, tabRef != destination else { return }
        if active != nil { deactivate() }
        report(await engine.moveBlock(tabRef.target, to: destination.target, position: before ? .before : .after))
    }

    /// Deletes a tab; deleting the last one removes the tabs block, as on the web.
    func deleteTab(_ tabRef: NodeRef, in tabsRef: NodeRef) async {
        guard let (_, tabs) = locate(tabsRef) else { return }
        if let active, active.ref.path.starts(with: tabs.children.count == 1 ? tabsRef.path : tabRef.path) { deactivate() }
        await delete(tabs.children.count == 1 ? tabsRef : tabRef)
    }

    // MARK: Footnotes

    /// Tap on a footnote number: cursor to the end of its text in the page-end list (like a double-click on the web).
    @discardableResult
    func focusFootnote(dataId: String) -> Bool {
        guard isEditable, let listIndex = document.children.firstIndex(where: { $0.type == "footnotes" }) else { return false }
        let footnotes = document.children[listIndex]
        guard let index = footnotes.children.firstIndex(where: { $0.string("data-id") == dataId }),
              let paragraph = footnotes.children[index].children.last, Self.editableTextTypes.contains(paragraph.type)
        else { return false }
        let path = [listIndex, index, footnotes.children[index].children.count - 1]
        activate(NodeRef(path: path, node: paragraph), node: paragraph, cursor: .end)
        return true
    }

    // MARK: Inline atoms

    /// Tap on a status or math atom in the text (`AtomLink`): opens the sheet to edit it.
    func editAtom(blockIdentity: String, type: String, index: Int) {
        guard isEditable, let ref = ref(forIdentity: blockIdentity), let node = atom(ofType: type, in: ref, index: index) else { return }
        switch type {
        case "status":
            editorSheet = .status(.edit(ref: ref, index: index), text: node.string("text") ?? "", color: node.string("color") ?? "gray")
        case "mathInline":
            editorSheet = .mathInline(.edit(ref: ref, index: index), latex: node.string("text") ?? "")
        case "integrationMention":
            mentionActions = MentionTarget(ref: ref, index: index, url: node.string("url") ?? "", provider: node.string("provider") ?? "")
        default:
            break
        }
    }

    /// Block for an identity (`NodeRef.identity`), e.g. from a link to an atom.
    func ref(forIdentity identity: String) -> NodeRef? {
        if identity.hasPrefix("path:") {
            let path = identity.dropFirst(5).split(separator: ".").compactMap { Int($0) }
            return node(at: path).map { NodeRef(path: path, node: $0) }
        }
        return locate(NodeRef(path: [], id: identity)).map { NodeRef(path: $0.path, node: $0.node) }
    }

    // MARK: Active text

    func activeCodeChanged() {
        guard let active, active.type == "codeBlock" else { return }
        if let adopted = adoptedCode {
            adoptedCode = nil
            if adopted == activeCode { return }
        }
        scheduleCommit()
    }

    /// Inserts a soft line break at the cursor.
    func insertLineBreak() {
        guard active != nil else { return }
        let index = insertionIndex()
        activeText.transform(updating: &activeSelection) { text in
            text.insert(AttributedString(String(InlineAttributedText.lineBreak)), at: index)
        }
        if let after = activeText.characters.index(index, offsetBy: 1, limitedBy: activeText.endIndex) {
            activeSelection = AttributedTextSelection(insertionPoint: after)
        }
        scheduleCommit()
    }

    /// Cursor at the end of the active text block (the usual case while writing); false for code blocks.
    var isCursorAtEnd: Bool {
        guard let active, active.type != "codeBlock" else { return false }
        return insertionIndex() == activeText.endIndex
    }

    private func insertionIndex() -> AttributedString.Index {
        switch activeSelection.indices(in: activeText) {
        case .insertionPoint(let index): return index
        case .ranges(let ranges): return ranges.ranges.last?.upperBound ?? activeText.endIndex
        }
    }

    // MARK: - Commit

    private func currentActiveNode() -> PMNode? {
        guard let active else { return nil }
        if active.type == "codeBlock" {
            return PMNode(type: "codeBlock", attrs: active.attrs, content: activeCode.isEmpty ? nil : [PMNode(type: "text", text: activeCode)])
        }
        let inlines = Self.inlines(from: activeText, base: activeFont)
        return PMNode(type: active.type, attrs: active.attrs, content: inlines.isEmpty ? nil : inlines)
    }

    private func scheduleCommit(debounce: Duration = .milliseconds(400)) {
        guard let active, let node = currentActiveNode() else { return }
        overrides[active.ref.identity] = node
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.commit(active.ref, node: node)
        }
    }

    /// Ends editing without writing the active block's pending input (the block is being replaced or removed).
    private func dropActive() {
        guard let active else { return }
        commitTask?.cancel()
        overrides[active.ref.identity] = nil
        self.active = nil
    }

    private func commitPendingNow() {
        guard let active, overrides[active.ref.identity] != nil, let node = currentActiveNode() else { return }
        commitTask?.cancel()
        commitTask = nil
        let ref = active.ref
        Task { await commit(ref, node: node) }
    }

    func flush() async {
        commitTask?.cancel()
        commitTask = nil
        if let active, let node = currentActiveNode(), overrides[active.ref.identity] != nil {
            await commit(active.ref, node: node)
        }
    }

    private func commit(_ ref: NodeRef, node: PMNode) async {
        guard let engine else { return }
        let pending = overrides[ref.identity]
        let saved = await engine.replaceBlock(ref.target, with: node)
        saveRefused = !saved
        if report(saved) {
            // Input typed during the save stored a newer override; it stays pending so its commit or `flush` writes it.
            if overrides[ref.identity] == pending { overrides[ref.identity] = nil }
        } else if active?.ref != ref {
            // Refused for a block no longer edited: its text must not stay over the saved one, nor be written later
            // into another block that takes its place.
            overrides[ref.identity] = nil
            syncFromEngine()
        }
    }

    // MARK: - Return and Backspace

    private func handleReturn(_ active: Active) async {
        guard let engine else { return }
        let full = activeText
        guard let newline = full.characters.firstIndex(of: "\n") else { return }
        let before = AttributedString(full[full.startIndex..<newline])
        let afterStart = full.characters.index(after: newline)
        let after = AttributedString(full[afterStart..<full.endIndex])
        activeText = before
        commitTask?.cancel()

        let beforeInlines = Self.inlines(from: before, base: activeFont)
        let afterInlines = Self.inlines(from: after, base: activeFont)
        let currentNode = PMNode(type: active.type, attrs: active.attrs, content: beforeInlines.isEmpty ? nil : beforeInlines)

        // A toggle title (also in a list item) stays whole: an empty paragraph starts an open toggle's content or
        // follows a closed one (web parity); right after the title it would split the toggle (only title + content).
        let detailsPath = Array(active.ref.path.dropLast())
        if active.type == "detailsSummary", let details = node(at: detailsPath), details.type == "details" {
            activeText = before + after
            let titleInlines = Self.inlines(from: before + after, base: activeFont)
            let title = PMNode(type: active.type, attrs: active.attrs, content: titleInlines.isEmpty ? nil : titleInlines)
            overrides[active.ref.identity] = title
            await commit(active.ref, node: title)
            let newNode = PMNode(type: "paragraph")
            let newPath: [Int]
            let applied: Bool
            if details.bool("open") == true, let content = node(at: detailsPath + [1]) {
                newPath = detailsPath + [1, 0]
                applied = await (content.children.isEmpty
                    ? engine.replaceBlock(.path(detailsPath + [1]), with: PMNode(type: "detailsContent", content: [newNode]))
                    : engine.insertBlock(newNode, relativeTo: .path(detailsPath + [1, 0]), position: .before))
            } else {
                var afterPath = detailsPath
                afterPath[afterPath.count - 1] += 1
                newPath = afterPath
                applied = await engine.insertBlock(newNode, relativeTo: .path(detailsPath), position: .after)
            }
            if report(applied) {
                await focusAfterOperation(newPath, .start)
            }
            return
        }

        if beforeInlines.isEmpty, afterInlines.isEmpty, await liftEmptyLine(active) { return }

        // The item's own lines. An empty first line leaves the list only if the item has no further blocks, as they
        // would go with it.
        if let itemPath = active.itemPath, active.ref.path.count == itemPath.count + 1 {
            if beforeInlines.isEmpty && afterInlines.isEmpty && node(at: itemPath)?.children.count == 1 {
                await exitList(itemPath: itemPath)
                return
            }
            overrides[active.ref.identity] = currentNode
            await commit(active.ref, node: currentNode)
            guard let item = node(at: itemPath) else { return }
            let attrs: [String: JSONValue]? = item.type == "taskItem" ? ["checked": false] : nil
            let newItem = PMNode(type: item.type, attrs: attrs, content: [PMNode(type: "paragraph", content: afterInlines.isEmpty ? nil : afterInlines)])
            var newPath = itemPath
            newPath[newPath.count - 1] += 1
            if report(await engine.insertBlock(newItem, relativeTo: .path(itemPath), position: .after)) {
                await focusAfterOperation(newPath + [0], .start)
            }
            return
        }

        overrides[active.ref.identity] = currentNode
        await commit(active.ref, node: currentNode)
        let newNode = PMNode(type: "paragraph", content: afterInlines.isEmpty ? nil : afterInlines)
        var newPath = active.ref.path
        newPath[newPath.count - 1] += 1
        if report(await engine.insertBlock(newNode, relativeTo: active.ref.target, position: .after)) {
            await focusAfterOperation(newPath, .start)
        }
    }

    /// Empty list item + Return (or Backspace in an empty first item): continues in a new paragraph.
    private func exitList(itemPath: [Int]) async {
        guard let index = itemPath.last else { return }
        await lift(at: Array(itemPath.dropLast()), index: index, replacement: PMNode(type: "paragraph"), cursor: .start, removing: itemPath)
    }

    /// A heading for an item's only line: the line leaves the list as that heading, as on the web.
    private func liftLine(itemPath: [Int], into template: BlockTemplate) async {
        guard let active, let line = latestNode(at: active.ref.path), let index = itemPath.last else { return }
        let attrs = line.attrs?.filter { ["textAlign", "indent"].contains($0.key) }
        let heading = template.node(inlines: Self.inlineContent(of: line), attrs: attrs)
        await lift(at: Array(itemPath.dropLast()), index: index, replacement: heading, cursor: .end, removing: itemPath)
    }

    /// Return on an empty line that the web lifts out of its container: a quote's or callout's line, a toggle's last
    /// line of several, an item's last line below its first. False where Return adds a line as usual.
    private func liftEmptyLine(_ active: Active) async -> Bool {
        let path = active.ref.path
        guard path.count >= 2, let index = path.last else { return false }
        let parentPath = Array(path.dropLast())
        guard let parent = node(at: parentPath) else { return false }
        let paragraph = PMNode(type: "paragraph")
        let isLast = index == parent.children.count - 1
        if ["blockquote", "callout"].contains(parent.type) {
            await lift(at: parentPath, index: index, replacement: paragraph, cursor: .start, removing: path)
        } else if parent.type == "detailsContent", isLast, parent.children.count > 1, let contentIndex = parentPath.last {
            // After the toggle; its content keeps a block.
            await lift(at: Array(parentPath.dropLast()), index: contentIndex, replacement: paragraph, cursor: .start, removing: path)
        } else if ["listItem", "taskItem"].contains(parent.type), index > 0, isLast, let itemIndex = parentPath.last {
            await lift(at: Array(parentPath.dropLast()), index: itemIndex, replacement: paragraph, cursor: .start, removing: path)
        } else {
            return false
        }
        return true
    }

    /// Puts `replacement` where the web lifts the active line out of the list, quote, callout or toggle at
    /// `containerPath`, at its child `index`. A child that goes (an item, a quote's line) is replaced before the
    /// container if it's the first, else after; one that stays (an item keeping its first line, a toggle's content) gets
    /// it after itself. In between, the container is split after the child. `removing` (a path in the old document)
    /// goes once the replacement is active, taking the container along if it was its only child.
    private func lift(at containerPath: [Int], index: Int, replacement: PMNode, cursor: CursorRequest, removing: [Int]) async {
        guard let engine, let previous = active, let container = node(at: containerPath) else { return }
        commitTask?.cancel()
        overrides[previous.ref.identity] = nil
        let count = container.children.count
        let replacesChild = removing.count == containerPath.count + 1
        if index < count - 1, index > 0 || !replacesChild {
            guard report(await engine.splitContainer(after: .path(containerPath + [index], type: container.children[index].type))) else { return }
        }
        let before = replacesChild && index == 0 && count > 1
        var targetPath = containerPath, containerNowPath = containerPath
        if before { containerNowPath[containerNowPath.count - 1] += 1 } else { targetPath[targetPath.count - 1] += 1 }
        guard report(await engine.insertBlock(replacement, relativeTo: .path(containerPath, type: container.type),
                                              position: before ? .before : .after))
        else { return }
        await focusAfterOperation(targetPath, cursor)
        // A collaborator may have moved things meanwhile: only the block that still holds the old line goes. No emptiness
        // check: the engine can still hold text deleted just before Return (its save was dropped).
        let removingNow = containerNowPath + removing.dropFirst(containerPath.count)
        guard let containerNow = node(at: containerNowPath), let gone = node(at: removingNow),
              gone.string("id") == previous.ref.id || (gone.children.count == 1 && gone.children[0].string("id") == previous.ref.id)
        else { return }
        if replacesChild, containerNow.children.count <= 1 {
            _ = await engine.deleteBlock(.path(containerNowPath, type: containerNow.type))
        } else {
            _ = await engine.deleteBlock(.path(removingNow, type: gone.type))
        }
    }

    /// Backspace at block start: joins with the previous text block or removes an empty block.
    private func mergeWithPrevious(_ active: Active) async {
        guard let engine else { return }
        let currentInlines = Self.inlines(from: activeText, base: activeFont)
        let path = active.ref.path
        var previousPath = path
        // An item's first paragraph joins the previous item's last paragraph, any other block its previous sibling.
        if let itemPath = active.itemPath, path == itemPath + [0] {
            // Its further blocks would be removed with it, or remain without the paragraph a list item starts with.
            guard node(at: itemPath)?.children.count == 1 else { return }
            var previousItem = itemPath
            previousItem[previousItem.count - 1] = itemPath[itemPath.count - 1] - 1
            guard itemPath[itemPath.count - 1] > 0, let item = node(at: previousItem), !item.children.isEmpty else {
                if currentInlines.isEmpty { await exitList(itemPath: itemPath) }
                return
            }
            previousPath = previousItem + [item.children.count - 1]
        } else {
            guard let index = path.last, index > 0 else { return }
            previousPath[previousPath.count - 1] = index - 1
        }
        guard let previous = node(at: previousPath) else { return }
        if Self.editableTextTypes.contains(previous.type) {
            let merged = PMNode(type: previous.type, attrs: previous.attrs, content: (previous.children + currentInlines).isEmpty ? nil : previous.children + currentInlines)
            let offset = previous.plainText.count
            overrides[active.ref.identity] = nil
            commitTask?.cancel()
            // Activate the previous block now with the merged text; the merged block goes afterwards.
            let previousRef = NodeRef(path: previousPath, node: previous)
            activate(previousRef, node: merged, cursor: .offset(offset))
            guard report(await engine.replaceBlock(previousRef.target, with: merged)) else {
                deactivate()
                return
            }
            await deleteMergedBlock(active)
        } else if currentInlines.isEmpty {
            // Empty paragraph after an image, table, divider …: continue at the end of the text before it (a table's
            // last cell), removing the paragraph. With no text before it, the keyboard closes.
            commitTask?.cancel()
            overrides[active.ref.identity] = nil
            if let target = lastTextBlock(before: path), let targetNode = node(at: target.path) {
                activate(target, node: targetNode, cursor: .end)
            } else {
                deactivate()
            }
            await deleteMergedBlock(active)
        }
    }

    /// Removes the block after merging; if it is a list item's only content, removes the whole item.
    private func deleteMergedBlock(_ active: Active) async {
        guard let engine else { return }
        let path = active.ref.path
        // The item goes by its path only while it still holds the block: a collaborator may have moved it meanwhile.
        if let itemPath = active.itemPath, path.count == itemPath.count + 1, let item = node(at: itemPath), item.children.count <= 1,
           item.children.first?.string("id") == active.ref.id {
            _ = await engine.deleteBlock(.path(itemPath, type: item.type))
        } else {
            _ = await engine.deleteBlock(active.ref.target)
        }
    }

    /// Containers whose content is edited directly (unlike columns, synced blocks, etc.).
    private static let inPlaceContainers: Set<String> = [
        "bulletList", "orderedList", "listItem", "taskList", "taskItem", "blockquote", "callout",
        "details", "detailsContent", "table", "tableRow", "tableCell", "tableHeader",
    ]

    /// Last directly editable text or non-mermaid code block before `path` in document order: in a table its last
    /// cell, for a collapsed toggle its summary.
    private func lastTextBlock(before path: [Int]) -> NodeRef? {
        var result: NodeRef?
        /// Visits the children in document order; returns `false` once `path` is reached.
        func visit(_ node: PMNode, at nodePath: [Int]) -> Bool {
            for (index, child) in node.children.enumerated() {
                let childPath = nodePath + [index]
                let isAncestor = childPath.count < path.count && path.starts(with: childPath)
                guard isAncestor || Self.precedes(childPath, path) else { return false }
                if Self.editableTextTypes.contains(child.type) || (child.type == "codeBlock" && child.string("language") != "mermaid") {
                    if !isAncestor { result = NodeRef(path: childPath, node: child) }
                } else if child.type == "details", child.bool("open") != true, !isAncestor {
                    if let summary = child.children.first, summary.type == "detailsSummary" {
                        result = NodeRef(path: childPath + [0], node: summary)
                    }
                } else if Self.inPlaceContainers.contains(child.type) {
                    if !visit(child, at: childPath) { return false }
                }
            }
            return true
        }
        _ = visit(document, at: [])
        return result
    }

    /// `a` comes before `b` in document order and is neither `b` itself nor an ancestor of it.
    private static func precedes(_ a: [Int], _ b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return false
    }

    // MARK: - Block operations

    func convert(_ ref: NodeRef, to template: BlockTemplate) async {
        // Uses the latest text: the pending commit is discarded below.
        guard let engine, let node = latestNode(at: ref.path) else { return }
        let attrs = node.attrs?.filter { ["id", "textAlign", "indent"].contains($0.key) }
        let replacement = template.node(inlines: Self.inlineContent(of: node), attrs: attrs)
        if active?.ref == ref { dropActive() }
        if report(await engine.replaceBlock(ref.target, with: replacement)), let first = template.firstTextPath {
            await focusAfterOperation(ref.path + first, .end)
        }
    }

    /// Converts the list containing the active item (bullet ↔ numbered ↔ task).
    func convertList(itemPath: [Int], to template: BlockTemplate) async {
        guard let engine else { return }
        let listPath = Array(itemPath.dropLast())
        guard let list = latestNode(at: listPath) else { return }
        let listType: String
        let itemType: String
        switch template {
        case .bulletList: (listType, itemType) = ("bulletList", "listItem")
        case .orderedList: (listType, itemType) = ("orderedList", "listItem")
        case .taskList: (listType, itemType) = ("taskList", "taskItem")
        default: return
        }
        guard list.type != listType else { return }
        let items = list.children.map { item in
            let attrs: [String: JSONValue]? = itemType == "taskItem" ? ["checked": .bool(item.bool("checked") ?? false)] : nil
            return PMNode(type: itemType, attrs: attrs, content: item.content)
        }
        let attrs: [String: JSONValue]? = listType == "orderedList" ? ["start": 1] : nil
        let focusPath = active?.ref.path ?? itemPath + [0]
        dropActive()
        if report(await engine.replaceBlock(.path(listPath), with: PMNode(type: listType, attrs: attrs, content: items))) {
            await focusAfterOperation(focusPath, .end)
        }
    }

    func toggleTask(itemPath: [Int]) async {
        guard let engine, let item = node(at: itemPath) else { return }
        _ = await engine.setAttributes(.path(itemPath), attributes: ["checked": .bool(!(item.bool("checked") ?? false))])
    }

    func delete(_ ref: NodeRef) async {
        guard let engine else { return }
        // Otherwise a pending commit would write into the deleted block and show an error.
        if active?.ref == ref { dropActive() }
        overrides[ref.identity] = nil
        report(await engine.deleteBlock(ref.target))
    }

    func duplicate(_ ref: NodeRef) async {
        // Uses the latest text, even if the last input hasn't reached the engine yet.
        guard let engine, let node = latestNode(at: ref.path) else { return }
        if active != nil { deactivate() }
        report(await engine.insertBlock(Self.strippingIds(node), relativeTo: ref.target, position: .after))
    }

    func moveBlocks(from source: IndexSet, to destination: Int) async {
        guard let engine, let sourceIndex = source.first else { return }
        let blocks = contentBlocks
        guard blocks.indices.contains(sourceIndex) else { return }
        let targetIndex = destination > sourceIndex ? destination - 1 : destination
        guard targetIndex != sourceIndex, blocks.indices.contains(targetIndex) else { return }
        report(await engine.moveBlock(blocks[sourceIndex].ref.target, to: blocks[targetIndex].ref.target, position: targetIndex > sourceIndex ? .after : .before))
    }

    /// Moves a block (drag/drop) before or after another top-level block.
    func moveBlock(identity: String, relativeTo destination: NodeRef, before: Bool) async {
        guard let engine, let source = topLevel.first(where: { $0.ref.identity == identity }), source.ref != destination else { return }
        if active != nil { deactivate() }
        report(await engine.moveBlock(source.ref.target, to: destination.target, position: before ? .before : .after))
    }

    // MARK: - Tables

    struct TablePosition: Equatable {
        let tablePath: [Int]
        let row: Int
        let column: Int
    }

    /// Table, row and column of the active block (if it is in a cell).
    var activeTablePosition: TablePosition? {
        guard let path = active?.ref.path, let table = ancestorPath(of: path, types: ["table"]), path.count >= table.count + 2 else { return nil }
        return TablePosition(tablePath: table, row: path[table.count], column: path[table.count + 1])
    }

    enum TableEdit {
        case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight, deleteRow, deleteColumn, deleteTable
        case toggleHeaderRow, toggleHeaderColumn
    }

    /// Whether the active table's first row / first column consists of header cells.
    var activeTableHeaders: (row: Bool, column: Bool) {
        guard let position = activeTablePosition, let table = node(at: position.tablePath), let first = table.children.first else { return (false, false) }
        let row = !first.children.isEmpty && first.children.allSatisfy { $0.type == "tableHeader" }
        let column = table.children.allSatisfy { $0.children.first?.type == "tableHeader" }
        return (row, column)
    }

    func editTable(_ edit: TableEdit) async {
        guard let engine, let position = activeTablePosition, let table = latestNode(at: position.tablePath) else { return }
        var rows = table.children
        guard rows.indices.contains(position.row) else { return }
        var focusRow = position.row
        var focusColumn = position.column

        func emptyCell(like cell: PMNode?, type: String) -> PMNode {
            var attrs: [String: JSONValue] = ["colspan": 1, "rowspan": 1]
            if let width = cell?.attr("colwidth") { attrs["colwidth"] = width }
            return PMNode(type: type, attrs: attrs, content: [PMNode(type: "paragraph")])
        }

        switch edit {
        case .insertRowAbove, .insertRowBelow:
            let template = rows[position.row]
            let cells = template.children.map { emptyCell(like: $0, type: "tableCell") }
            let index = edit == .insertRowAbove ? position.row : position.row + 1
            rows.insert(PMNode(type: "tableRow", content: cells), at: index)
            focusRow = index
        case .insertColumnLeft, .insertColumnRight:
            let index = edit == .insertColumnLeft ? position.column : position.column + 1
            rows = rows.map { row in
                var cells = row.children
                let reference = cells.indices.contains(position.column) ? cells[position.column] : cells.last
                cells.insert(emptyCell(like: reference, type: reference?.type ?? "tableCell"), at: min(index, cells.count))
                return PMNode(type: row.type, attrs: row.attrs, content: cells)
            }
            focusColumn = index
        case .deleteRow:
            rows.remove(at: position.row)
            focusRow = min(position.row, rows.count - 1)
        case .deleteColumn:
            rows = rows.map { row in
                var cells = row.children
                if cells.indices.contains(position.column) { cells.remove(at: position.column) }
                return PMNode(type: row.type, attrs: row.attrs, content: cells)
            }
            focusColumn = max(0, min(position.column, (rows.first?.children.count ?? 1) - 1))
            if rows.first?.children.isEmpty ?? true { rows = [] }
        case .deleteTable:
            rows = []
        case .toggleHeaderRow:
            let makeHeader = !(rows.first?.children.allSatisfy { $0.type == "tableHeader" } ?? false)
            let first = rows[0]
            rows[0] = PMNode(type: first.type, attrs: first.attrs, content: first.children.map {
                PMNode(type: makeHeader ? "tableHeader" : "tableCell", attrs: $0.attrs, content: $0.content)
            })
        case .toggleHeaderColumn:
            let makeHeader = !rows.allSatisfy { $0.children.first?.type == "tableHeader" }
            rows = rows.map { row in
                var cells = row.children
                if let cell = cells.first {
                    cells[0] = PMNode(type: makeHeader ? "tableHeader" : "tableCell", attrs: cell.attrs, content: cell.content)
                }
                return PMNode(type: row.type, attrs: row.attrs, content: cells)
            }
        }

        // The new table has the cell's latest text; its pending commit could target a deleted cell and show an error.
        dropActive()
        if rows.isEmpty {
            report(await engine.deleteBlock(.path(position.tablePath)))
            return
        }
        if report(await engine.replaceBlock(.path(position.tablePath), with: PMNode(type: "table", attrs: table.attrs, content: rows))) {
            await focusAfterOperation(position.tablePath + [focusRow, focusColumn, 0], .end)
        }
    }

    func undo() async { await stepHistory(redo: false) }
    func redo() async { await stepHistory(redo: true) }

    /// Undo/redo through the engine's Yjs history (like the web editor), after flushing pending input into it. The
    /// active editor then adopts its block's new state, or it would keep its old text and write it back on typing.
    private func stepHistory(redo: Bool) async {
        guard let engine else { return }
        await flush()
        if redo { await engine.redo() } else { await engine.undo() }
        guard let latest = await engine.currentDocument() else { return }
        document = withOverrides(latest)
        adoptActiveBlock()
    }

    /// Adopts the active block's type, attrs and content from the document (cursor kept); ends editing if it is gone.
    private func adoptActiveBlock() {
        guard let current = active else { return }
        guard let (path, node) = locate(current.ref) else {
            deactivate()
            return
        }
        let offset = activeText.characters.distance(from: activeText.startIndex, to: insertionIndex())
        active = Active(ref: NodeRef(path: path, node: node), type: node.type, attrs: node.attrs, itemPath: enclosingItemPath(path))
        if node.type == "codeBlock" {
            activeCode = node.plainText
            adoptedCode = activeCode
        } else {
            activeText = Self.editorText(from: node.children)
            adoptedText = activeText
            cursorRequest = .offset(offset)
        }
    }

    /// Path and node of a block: by its ID (stable when something before it changes), otherwise by path.
    private func locate(_ ref: NodeRef) -> (path: [Int], node: PMNode)? {
        guard let id = ref.id else { return node(at: ref.path).map { (ref.path, $0) } }
        return path(where: { $0.string("id") == id }).flatMap { path in node(at: path).map { (path, $0) } }
    }

    /// A block's current state, including unsaved input.
    private func latestNode(at path: [Int]) -> PMNode? {
        if let active, active.ref.path == path, let node = currentActiveNode() { return node }
        return node(at: path, in: withOverrides(document))
    }

    // MARK: - Helpers

    func node(at path: [Int], in root: PMNode? = nil) -> PMNode? {
        var current = root ?? document
        for index in path {
            guard current.children.indices.contains(index) else { return nil }
            current = current.children[index]
        }
        return current
    }

    /// Path of the nearest ancestor (not the node itself) whose type is one of `types`.
    private func ancestorPath(of path: [Int], types: Set<String>) -> [Int]? {
        for length in stride(from: path.count - 1, through: 1, by: -1) {
            let prefix = Array(path.prefix(length))
            if let type = node(at: prefix)?.type, types.contains(type) { return prefix }
        }
        return nil
    }

    private func enclosingItemPath(_ path: [Int]) -> [Int]? {
        ancestorPath(of: path, types: ["listItem", "taskItem"])
    }

    /// A document with the local, unconfirmed changes applied.
    private func withOverrides(_ root: PMNode) -> PMNode {
        overrides.isEmpty ? root : applyOverrides(to: root, path: [])
    }

    private func applyOverrides(to node: PMNode, path: [Int]) -> PMNode {
        let ref = NodeRef(path: path, node: node)
        // Kept by path for a block without an id: it stands only for a block of its type.
        if !path.isEmpty, let override = overrides[ref.identity], override.type == node.type { return override }
        guard let content = node.content else { return node }
        let children = content.enumerated().map { applyOverrides(to: $0.element, path: path + [$0.offset]) }
        return PMNode(type: node.type, attrs: node.attrs, content: children, marks: node.marks, text: node.text)
    }

    static func inlineContent(of node: PMNode) -> [PMNode]? {
        switch node.type {
        case "paragraph", "heading", "detailsSummary": return node.content
        case "codeBlock": return node.plainText.isEmpty ? nil : [PMNode(type: "text", text: node.plainText)]
        default:
            if let first = node.children.first { return inlineContent(of: first) }
            return nil
        }
    }

    static func strippingIds(_ node: PMNode) -> PMNode {
        var attrs = node.attrs
        attrs?["id"] = nil
        return PMNode(type: node.type, attrs: attrs?.isEmpty == true ? nil : attrs, content: node.content?.map(strippingIds), marks: node.marks, text: node.text)
    }

    /// Inline nodes from the editor text (with the formatting that arrives only as SwiftUI attributes while typing).
    static func inlines(from text: AttributedString, base: Font) -> [PMNode] {
        InlineAttributedText.inlines(from: EditorText.normalized(text, base: base))
    }

    /// Editor text from inline nodes (with the SwiftUI attributes that make the formatting visible while editing).
    static func editorText(from inlines: [PMNode]) -> AttributedString {
        EditorText.display(InlineAttributedText.attributedString(from: inlines))
    }

    #if DEBUG
    /// Test hooks (`DOCMOST_DEBUG_FOCUS`, `DOCMOST_DEBUG_TYPE`, `DOCMOST_DEBUG_EDIT`), run after the first sync.
    func applyDebugHooks() async {
        if let text = DebugLaunch.editText, let engine {
            _ = await engine.insertBlock(PMNode(type: "paragraph", content: [PMNode(type: "text", text: text)]), relativeTo: nil, position: .after)
        }
        if let target = DebugLaunch.focusTarget {
            var path = [target.block]
            if let item = target.item { path += [item, 0] }
            // Descend to the first text node (e.g. table → row → cell → paragraph).
            while let node = node(at: path), !Self.editableTextTypes.contains(node.type), node.type != "codeBlock", !node.children.isEmpty {
                path.append(0)
            }
            if let node = node(at: path) {
                activate(NodeRef(path: path, node: node), node: node)
                if let typed = DebugLaunch.typeText {
                    try? await Task.sleep(for: .milliseconds(300))
                    activeText.append(AttributedString(typed))
                    activeTextChanged()
                }
            }
        }
    }
    #endif
}

/// How the page's one text editor draws the active block's text: as the block would (font, leading, alignment).
struct EditorStyle: Equatable {
    var font: Font
    var leading: CGFloat
    var alignment: TextAlignment
    /// A code block: no autocorrection or capitalization.
    var isCode = false
}
