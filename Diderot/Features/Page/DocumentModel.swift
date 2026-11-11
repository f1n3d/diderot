import Foundation
import Observation
import SwiftUI
import DocmostKit

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

    let page: Page
    /// The page's engine from opening to closing: where it is, why the page is read-only, the unsent changes and uploads.
    let connection: EngineConnection
    var engine: (any DocumentEngine)? { connection.engine }
    private(set) var document: PMNode
    var lifecycle: EngineConnection.Lifecycle { connection.lifecycle }
    var isLive: Bool { connection.isLive }
    var readOnlyReason: ReadOnlyReason? { connection.readOnlyReason }
    /// The page's one text editor and its input on the way to the engine: the block being edited, its text and
    /// selection, the input not yet saved, and the saves.
    let session: ActiveTextSession
    private(set) var active: Active? {
        get { session.active }
        set { session.active = newValue }
    }
    /// A block is being edited. Changes only when editing starts or ends, so every block can watch it (not `active`).
    var hasActiveBlock: Bool { session.hasActiveBlock }
    var activeText: AttributedString {
        get { session.text }
        set { session.text = newValue }
    }
    var activeSelection: AttributedTextSelection {
        get { session.selection }
        set { session.selection = newValue }
    }
    /// Font the active text block draws with (set by its `TextNodeView`); saving compares system bold against it.
    var activeFont: Font {
        get { session.font }
        set { session.font = newValue }
    }
    /// The active code block's text, in `activeText` without formatting (`ActiveTextSession.code`).
    var activeCode: String {
        get { session.code }
        set { session.code = newValue }
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
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    /// Media picker for the UI; `mediaPlacement` (where files go) stays until the upload; a cancel need not reset it.
    private(set) var pendingMedia: MediaRequest?
    private(set) var mediaPlacement: BlockPlacement?
    /// Uploads running for this page (`upload`); the page shows "Uploading…", and `leave` keeps its engine open for them.
    var uploads: Int { connection.uploads }
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
    private(set) var isCreatingBase = false
    /// Inline command from the floating "+": waits for the paragraph created for it at the end to be active.
    @ObservationIgnored private var pendingInlineCommand: InsertCommand?
    /// That command, run once its paragraph's editor has focus (`editorFocusChanged`): an emoji keyboard or sheet
    /// appearing sooner would take that focus away.
    @ObservationIgnored private var commandAfterFocus: (command: InsertCommand, ref: NodeRef)?
    /// Notice after an action (e.g. "Copied"); the page view shows it briefly.
    var notice: String?
    private(set) var errorMessage: String?
    /// Why the engine couldn't keep the unsent changes on the device (a full disk), until a later save keeps them.
    var unsentNotKept: String? { connection.unsentNotKept }
    /// The page's banner for it, while the server hasn't confirmed every change: once it has, nothing is at risk.
    var unsentWarning: String? { connection.unsentWarning }
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
        guard canComment, !editsInSheet, let active, PMNode.editableTextTypes.contains(active.type),
              case .ranges(let ranges) = activeSelection.indices(in: activeText)
        else { return false }
        return ranges.ranges.contains { !$0.isEmpty }
    }

    /// The comment `commentId` was deleted: its passage loses its mark, as on the web (`unsetComment`). The server's
    /// `comments/delete` leaves the page alone, so the passage stayed marked for everyone, and a tap on it opened nothing.
    /// From the text being edited too, saved first: its input would bring the mark back with its next save.
    func removeMarks(ofComment commentId: String) async {
        if active != nil {
            let marked = activeText.runs[DocmostAttributes.CommentAttribute.self].filter { $0.0 == commentId }.map(\.1)
            for range in marked {
                activeText[range].docmost.comment = nil
                activeText[range].docmost.commentResolved = nil
            }
            if !marked.isEmpty {
                activeTextChanged()
                await flush()
            }
        }
        guard let engine else { return }
        report(await engine.unsetComment(commentId))
    }

    /// Where the cursor goes once the document holds the block at `path`, read in that block.
    private var pendingFocus: (path: [Int], cursor: (PMNode) -> CursorRequest)?
    /// A table edit is under way. It puts the cursor into a cell itself, so a document event meanwhile neither ends
    /// editing (the keyboard and its table row would go and come back) nor takes the edit for a collaborator's change.
    @ObservationIgnored private var editsTable = false
    /// The block became active through Return or Backspace in the previous one: the page keeps its place and only
    /// keeps the caret visible, while a tapped block is centered.
    @ObservationIgnored private(set) var activatedByTyping = false
    /// Return and Backspace operations still running (quick typing overlaps them). They put the cursor where it goes
    /// themselves, so a document event meanwhile doesn't end editing when the block goes (leaving a list, joining
    /// blocks): its editor would vanish and the keyboard hide and show again. One that ends without placing it ends
    /// editing then, if the block is gone (`typingSwitchEnded`).
    @ObservationIgnored private var typingSwitches = 0
    /// Return or Backspace is switching blocks; meanwhile the old editor briefly shows the line break as a second line.
    var isSwitchingByTyping: Bool { typingSwitches > 0 }
    @ObservationIgnored private var adoptsChange = false

    /// What the model needs from outside its page; tests change it.
    @ObservationIgnored var dependencies: Dependencies

    init(page: Page, initialDocument: PMNode?, engine: (any DocumentEngine)?, readOnlyReason: ReadOnlyReason?,
         dependencies: Dependencies = Dependencies()) {
        self.page = page
        self.dependencies = dependencies
        self.document = initialDocument ?? PMNode(json: page.content ?? .null) ?? PMNode(type: "doc")
        self.connection = EngineConnection(page: page, engine: engine, readOnlyReason: readOnlyReason)
        self.session = ActiveTextSession(engine: engine)
        if case .newerServer(let version) = readOnlyReason {
            errorMessage = String(localized: "This server runs Docmost \(version). This version of the app can only show its pages; you can edit them in the web editor.")
        }
        connection.owner = self
        session.owner = self
    }

    var isEditable: Bool { engine != nil && isLive && readOnlyReason == nil }
    /// Nothing but an empty first line, as the web's `editor.isEmpty`: the page offers to start with a template or a
    /// database (`GetStartedRow`).
    var isBlank: Bool {
        let blocks = document.children
        return blocks.isEmpty || (blocks.count == 1 && blocks[0].type == "paragraph" && blocks[0].children.isEmpty)
    }
    /// No blocks, or read-only with one empty paragraph. Not `plainText`: a lone mention, image or divider is content.
    var showsEmptyPlaceholder: Bool {
        let blocks = document.children
        return blocks.isEmpty || (!isEditable && blocks.count == 1 && blocks[0].type == "paragraph" && blocks[0].children.isEmpty)
    }
    var status: EngineStatus { engine?.status ?? .idle }
    /// The server hasn't confirmed every change (`DocumentEngine.unconfirmedChanges`).
    var hasUnconfirmedChanges: Bool { connection.hasUnconfirmedChanges }
    var participants: [EngineParticipant] { engine?.participants ?? [] }
    var topLevel: [NodeEntry] { NodeEntry.entries(document.children, parentPath: []) }
    /// Top-level blocks without the footnotes list (always last).
    var contentBlocks: [NodeEntry] { topLevel.filter { $0.node.type != "footnotes" } }
    /// What a person moves, arranges and deletes one by one: the top-level blocks, a list as its items, as the web's
    /// handle takes each item of a list. The arrange sheet's row indices refer to this list.
    var elements: [NodeEntry] {
        contentBlocks.flatMap { PMNode.listTypes.contains($0.node.type) ? NodeEntry.entries($0.node.children, parentPath: $0.ref.path) : [$0] }
    }

    // MARK: - Engine

    /// The engine's document the page shows, without local input over it: a refused save for a block no longer edited
    /// shows the block from it again.
    @ObservationIgnored private var engineDocument: PMNode?

    /// Opens the engine unless it is open: when the page appears, after `suspend`, and to retry a failed start.
    func resume() {
        connection.resume()
    }

    /// The page left the screen (closed, under a pushed page, tab switch); uploads still running keep its engine open.
    func leave() {
        connection.leave()
    }

    /// Read-only until `resume` reopens the engine.
    @discardableResult
    func suspend() -> Task<Void, Never> {
        connection.suspend()
    }

    /// The app went to the background: keeps unsent changes as leaving the page would, with pending input.
    func saveUnsentChanges() async {
        await connection.saveUnsentChanges()
    }

    /// Shows the engine's document with local input over it.
    private func show(_ incoming: PMNode) {
        engineDocument = incoming
        document = withOverrides(incoming)
    }

    /// Adopts the engine's document; local, unconfirmed changes take precedence.
    private func adopt(_ incoming: PMNode) {
        show(incoming)
        followMovedBlocks()
        // Every local change brings a document event, also those that bypass the session's saves (inserts, moves,
        // undo): unconfirmed, it is kept soon.
        connection.documentShown()
        session.writeUnsaved()
        if let pendingFocus, let node = node(at: pendingFocus.path) {
            self.pendingFocus = nil
            activate(NodeRef(path: pendingFocus.path, node: node), node: node, cursor: pendingFocus.cursor(node))
            // Floating "+" inline command: runs once the new paragraph's editor has focus.
            if let command = pendingInlineCommand, let ref = active?.ref {
                pendingInlineCommand = nil
                commandAfterFocus = (command, ref)
            }
        }
        adoptCollaboratorsChangeIfAny()
        // What fits around the block, and what its table allows, may have changed.
        if active != nil { refreshAnswers() }
    }

    /// The engine's version of the block being edited differs from the one its editor text was made from (a
    /// collaborator's change), and nothing of the user's waits for it or would break: no pending save, no Return or
    /// Backspace on its way, no sheet holding ranges of the text, no marked text (dictation, Japanese input).
    private func collaboratorChangedActiveBlock() -> Bool {
        guard let active, let base = session.base, session.overrides[active.ref.identity] == nil, typingSwitches == 0, !editsInSheet,
              editorTextView?.markedTextRange == nil, let (_, node) = document.locate(active.ref)
        else { return false }
        return !looksTheSame(node, base)
    }

    /// Whether two versions of a block look the same in the editor; the engine's JSON can differ in details from the app's
    /// (it fills in attributes the app leaves out, such as a new link's `rel` or a new line break's direction), so inline
    /// content compares as the editor shows it.
    private func looksTheSame(_ a: PMNode, _ b: PMNode) -> Bool {
        guard a.type == b.type, a.attrs == b.attrs else { return false }
        if a.type == "codeBlock" { return a.plainText == b.plainText }
        return shownInlines(a.children) == shownInlines(b.children)
    }

    /// The inlines as the editor shows them: without their marks and line breaks' attributes as stored
    /// (`InlineAttributedText`), which a save writes back.
    private func shownInlines(_ inlines: [PMNode]) -> [PMNode] {
        var text = Self.editorText(from: inlines)
        text.docmost.storedMarks = nil
        text.docmost.storedBreak = nil
        return Self.inlines(from: text, base: activeFont)
    }

    /// Shows a collaborator's change of the block being edited; the cursor moves with the text around it. From the
    /// engine's current document: a document event from before the user's own last save would roll the editor back.
    private func adoptCollaboratorsChange() async {
        defer { adoptsChange = false }
        guard let engine, let latest = await engine.currentDocument() else { return }
        show(latest)
        followMovedBlocks()
        guard collaboratorChangedActiveBlock() else { return }
        adoptActiveBlock(followingChange: true)
    }

    /// Focuses `path` once the operation that created it is applied; set earlier, `pendingFocus` could hit the old
    /// block in a document event still in flight (e.g. from the commit just before).
    private func focusAfterOperation(_ path: [Int], _ cursor: CursorRequest) async {
        await focusAfterOperation(path) { _ in cursor }
    }

    /// Focuses where Return or Backspace left the cursor (`EngineCursor`); its offset counts as the engine's do, read in
    /// the block it lands in.
    private func focusAfterOperation(_ cursor: EngineCursor) async {
        await focusAfterOperation(cursor.path) { .offset(Self.editorOffset(in: $0, at: cursor.offset)) }
    }

    private func focusAfterOperation(_ path: [Int], cursor: @escaping (PMNode) -> CursorRequest) async {
        guard let latest = await engine?.currentDocument() else { return }
        pendingFocus = (path, cursor)
        adopt(latest)
        // Not in the engine's current document (gone again at once): a later block there, e.g. a collaborator's, must
        // not jump into editing.
        pendingFocus = nil
    }

    /// Shows and returns whether a block operation applied. A refusal carries no reason (e.g. a block a collaborator
    /// just deleted or changed), hence one fixed message; the next applied change clears it, but a refused save's only
    /// the next save (a table edit or a conversion, which sends the input first, must not hide it). No engine to take it
    /// says nothing: the restart shows in the status, and input waits for it (`ActiveTextSession`).
    @discardableResult
    private func report(_ result: EngineResult) -> Bool {
        switch result {
        case .applied: if !session.saveRefused { errorMessage = nil }
        case .refused: errorMessage = String(localized: "The change could not be applied.")
        case .unavailable: break
        }
        return result.isApplied
    }

    private func typingSwitchEnded() {
        typingSwitches -= 1
        guard typingSwitches == 0 else { return }
        followMovedBlocks()
        // A collaborator's change a document event brought meanwhile shows now: it waited for the key, and without another
        // event it stayed hidden. Backspace in a line the page had empty can join their words into the block before.
        adoptCollaboratorsChangeIfAny()
    }

    /// Shows a collaborator's change of the block being edited, if there is one that nothing of the user's waits for
    /// (`collaboratorChangedActiveBlock`).
    private func adoptCollaboratorsChangeIfAny() {
        guard !adoptsChange, !editsTable, collaboratorChangedActiveBlock() else { return }
        adoptsChange = true
        Task { await adoptCollaboratorsChange() }
    }

    /// The active block follows by its UniqueID when its path shifts; otherwise the editor would edit another block.
    private func followMovedBlocks() {
        if let active, let id = active.ref.id, node(at: active.ref.path)?.string("id") != id {
            // Not where it was: found by its id, if that is the only block with it (`locate`).
            if let path = document.locate(active.ref)?.path {
                self.active = Active(ref: NodeRef(path: path, id: id), type: active.type, attrs: active.attrs, itemPath: enclosingItemPath(path))
            } else if !editsTable && typingSwitches == 0 {
                // A collaborator deleted it. Its editor used to vanish with it; the page's one editor stays, so end here.
                session.overrides[active.ref.identity] = nil
                session.cancelCommit()
                deactivate()
            }
        }
        // Without an id (code block, toggle title), another block type or none at the path means a collaborator
        // added or removed a block before it; its input would replace that block, so editing ends unsaved. Not while
        // a key is on its way: Backspace turns an empty code block into a paragraph, which takes the cursor next
        // (ending here hid the keyboard in between); the key's end asks again (`typingSwitchEnded`).
        if let active, active.ref.id == nil, node(at: active.ref.path)?.type != active.type, !editsTable, typingSwitches == 0 {
            session.overrides[active.ref.identity] = nil
            session.cancelCommit()
            deactivate()
        }
    }

    // MARK: - Active text

    func activate(_ ref: NodeRef, node: PMNode, cursor: CursorRequest = .end) {
        // Only text and code: the editor's text would replace any other block (a list, quote or image) on the next key.
        guard isEditable, PMNode.editableTextTypes.contains(node.type) || node.type == "codeBlock" else { return }
        if active?.ref == ref { return }
        if active != nil { session.commitPendingNow() }
        // Another block before the command's had focus: it goes nowhere.
        if commandAfterFocus?.ref != ref { commandAfterFocus = nil }
        let itemPath = enclosingItemPath(ref.path)
        activeBlockFrame = .zero
        activatedByTyping = typingSwitches > 0
        active = Active(ref: ref, type: node.type, attrs: node.attrs, itemPath: itemPath)
        session.show(node, as: node.type == "codeBlock" ? AttributedString(node.plainText) : Self.editorText(from: node.children))
        // The page's one editor keeps its selection from block to block; the old indices don't fit this text.
        activeSelection = AttributedTextSelection(insertionPoint: activeText.endIndex)
        slashQuery = nil
        showsPlusMenu = false
        mentionQuery = nil
        mentionSuggestions = []
        cursorRequest = cursor
        refreshAnswers()
    }

    /// Editor instance with focus (see `editorFocusChanged`).
    @ObservationIgnored private var focusedEditor: UUID?

    /// Focus change of a text or code editor. Losing focus ends editing only if no instance regains it shortly:
    /// SwiftUI sometimes rebuilds the editor (e.g. scrolled into view in the lazy list); the new one takes focus back.
    func editorFocusChanged(_ focused: Bool, instance: UUID, ref: NodeRef) {
        if focused {
            focusedEditor = instance
            if let pending = commandAfterFocus, pending.ref == ref, active?.ref == ref {
                commandAfterFocus = nil
                insertInline(pending.command, at: activeText.characters.count)
            }
            return
        }
        if focusedEditor == instance { focusedEditor = nil }
        if active?.ref == ref {
            guard !editsInSheet else { return }
            Task { @MainActor [weak self, clock = dependencies.clock] in
                try? await clock.sleep(for: .milliseconds(150))
                guard let self, self.active?.ref == ref, self.focusedEditor == nil, !self.editsInSheet else { return }
                self.deactivate()
            }
        }
    }

    func deactivate() {
        guard active != nil else { return }
        session.commitPendingNow()
        commandAfterFocus = nil
        active = nil
        session.base = nil
        editorHeight = nil
        slashQuery = nil
        showsPlusMenu = false
        mentionQuery = nil
        mentionSuggestions = []
    }

    /// Tap below the last block: cursor to its end if it is text, else a new paragraph at the end.
    func activateTrailing() async {
        guard isEditable else { return }
        if let last = contentBlocks.last, PMNode.editableTextTypes.contains(last.node.type) {
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
        active.flatMap { document.ancestorPath(of: $0.ref.path, types: [type]) }
    }

    /// Sets attributes of a block (`NodeRef(path:id: nil)` targets it by position).
    func setAttributes(of ref: NodeRef, _ attributes: [String: JSONValue]) async {
        guard let engine else { return }
        // The active block's commits are built from its attrs; a stale copy would write the old value back.
        if let active, active.ref.path == ref.path {
            var attrs = active.attrs ?? [:]
            attrs.merge(attributes) { $1 }
            self.active = Active(ref: active.ref, type: active.type, attrs: attrs, itemPath: active.itemPath)
            if session.overrides[active.ref.identity] != nil { session.scheduleCommit() }
        }
        report(await engine.setAttributes(ref.target, attributes: attributes))
    }

    /// Backspace with the cursor at the text's start (`TextInputHooks`; the text doesn't change, so `activeTextChanged`
    /// can't notice it): joins the block with the one before, as on the web, where an empty code block becomes a
    /// paragraph (one with code keeps the key). False leaves the key to the text view.
    func backspaceAtStart() -> Bool {
        guard let active, active.type != "codeBlock" || activeCode.isEmpty else { return false }
        Task {
            typingSwitches += 1
            defer { typingSwitchEnded() }
            await joinBackward(active)
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
                defer { typingSwitchEnded() }
                await handleReturn(active)
            }
            return
        }
        // Typing closes the "+" menu; the slash menu follows the text.
        showsPlusMenu = false
        updateSlashQuery()
        updateMentionQuery()
        guard session.textChangeIsInput() else { return }
        session.scheduleCommit()
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
              let newQuery = TriggerParser.mention(in: activeText, cursor: insertionIndex())?.query
        else {
            mentionQuery = nil
            return
        }
        guard newQuery != mentionQuery else { return }
        mentionQuery = newQuery
        suggestTask?.cancel()
        suggestTask = Task { [weak self, clock = dependencies.clock] in
            try? await clock.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let suggest = self.dependencies.suggest else { return }
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
        let node = NodeFactory.mention(entityType: suggestion.kind == .user ? "user" : "page", entityId: suggestion.entityId,
                                       label: suggestion.title, slugId: suggestion.slugId, creatorId: dependencies.currentUserId)
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
        session.scheduleCommit(debounce: .zero)
    }

    // MARK: - What the engine says

    /// The engine's answers about the active block, for the menus, the table row of the keyboard toolbar and Backspace,
    /// which show at once: which block types fit where new blocks go, which cards and inline databases can take its
    /// line's place, which table commands apply to its cell, what Backspace at its start does, what it can turn into.
    /// The app kept its own copy of these rules, and it drifted: a synced block was offered page breaks and databases it
    /// can't hold. Asked when a block becomes active and after each document; nil until answered, and for another block.
    struct EngineAnswers: Equatable {
        /// The active block's identity they are for.
        let identity: String
        /// Block types that fit after the active block, and in its place (an empty line a new block replaces), where
        /// "/" puts them at the top level and in containers.
        var afterBlock: Set<String> = []
        var inPlaceOfBlock: Set<String> = []
        /// Block types that fit after its top-level block, where "+" puts them, and "/" in lists and table cells.
        var afterTopLevel: Set<String> = []
        /// Cards and inline databases that can take the place of its line (a paragraph's).
        var inLine: Set<InLine> = []
        /// Table commands, by name, that apply to its cell.
        var tableCommands: Set<String> = []
        /// What Backspace at its start does, empty and with text (`joinBackward` shows it at once).
        var backspace: BackspacePlans?
        /// What it can turn into where it is: `BlockTemplate` raw values, and "syncedBlock".
        var conversions: Set<String>?
    }

    /// A card or inline database in place of a paragraph, with the paragraph's text before and after it, or not
    /// (`blockReplacement`).
    struct InLine: Hashable {
        let type: String
        let textBefore: Bool
        let textAfter: Bool
    }

    private(set) var answers: EngineAnswers?
    @ObservationIgnored private var answersTask: Task<Void, Never>?

    /// The block types the menus put on the page.
    private static let menuBlockTypes = Set(InsertCommand.all.compactMap(\.blockType) + ["transclusionReference"]).sorted()
    /// The table commands the toolbar offers only where they apply.
    private static let tableQuestions: [TableEdit] = [
        .mergeRight, .mergeDown, .split, .moveRowUp, .moveRowDown, .moveColumnLeft, .moveColumnRight, .sort(descending: false),
    ]

    /// Asks the engine about the active block (`answers`); the newest question wins.
    private func refreshAnswers() {
        answersTask?.cancel()
        guard engine != nil, let active, isEditable else {
            answers = nil
            return
        }
        let ref = active.ref, isParagraph = active.type == "paragraph", table = activeTablePosition
        let top = [ref.path[0]]
        let topTarget = node(at: top).map { NodeRef(path: top, node: $0).target } ?? .path(top)
        answersTask = Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            var answers = EngineAnswers(identity: ref.identity)
            let types = Self.menuBlockTypes, blocks = types.map { [PMNode(type: $0)] }
            var fitting: [Set<String>] = []
            for place in [BlockPlace(target: ref.target, position: .after), BlockPlace(target: ref.target, position: .replace),
                          BlockPlace(target: topTarget, position: .after)] {
                // Without an answer the menus offer everything, and the engine refuses what doesn't fit.
                guard let fits = await engine.fits(place, candidates: blocks), fits.count == types.count else { return }
                fitting.append(Set(zip(types, fits).filter(\.1).map(\.0)))
            }
            (answers.afterBlock, answers.inPlaceOfBlock, answers.afterTopLevel) = (fitting[0], fitting[1], fitting[2])
            if isParagraph {
                var lines: [InLine] = []
                for type in ["integrationCard", "base"] {
                    for before in [false, true] {
                        for after in [false, true] { lines.append(InLine(type: type, textBefore: before, textAfter: after)) }
                    }
                }
                let text = PMNode(type: "paragraph")
                let candidates = lines.map { ($0.textBefore ? [text] : []) + [PMNode(type: $0.type)] + ($0.textAfter ? [text] : []) }
                if let fits = await engine.fits(BlockPlace(target: ref.target, position: .replace), candidates: candidates) {
                    answers.inLine = Set(zip(lines, fits).filter(\.1).map(\.0))
                }
            }
            if let table, let apply = await engine.tableCommandsThatApply(ref.target, cell: [table.row, table.column],
                                                                         commands: Self.tableQuestions.map(\.engineCommand)) {
                answers.tableCommands = Set(zip(Self.tableQuestions, apply).filter(\.1).compactMap { $0.0.engineCommand["name"]?.stringValue })
            }
            answers.backspace = await engine.backspacePlans(ref.target)
            answers.conversions = await engine.conversions(ref.target)
            guard !Task.isCancelled, self.active?.ref.identity == ref.identity else { return }
            self.answers = answers
        }
    }

    /// The answers if they are for the active block.
    private var activeAnswers: EngineAnswers? {
        guard let active, let answers, answers.identity == active.ref.identity else { return nil }
        return answers
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
        let ancestors = document.ancestorTypes(of: active.ref.path)
        if ancestors.contains("footnotes") { return .footnote }
        if active.itemPath != nil { return .listItem }
        if ancestors.contains("tableCell") || ancestors.contains("tableHeader") { return .tableCell }
        return .container
    }

    /// Commands that fit at the active block's position; all of them without an active block (floating "+").
    func availableCommands() -> [InsertCommand] {
        var commands = InsertCommand.all
        if !CameraPicker.isAvailable { commands.removeAll { $0 == .camera } }
        if SyncedBlockClipboard.hasAppContent, let index = commands.firstIndex(of: .syncedBlock) {
            commands.insert(.pasteSyncedBlock, at: index + 1)
        }
        if !dependencies.hasDocmost097Features { commands.removeAll { $0 == .tabs } }
        guard let active else { return commands }
        if active.type == "codeBlock" { commands.removeAll { $0.isInline } }
        let location = insertLocation(of: active)
        if location == .footnote {
            return commands.filter { $0.isInline && $0 != .footnote }
        }
        let inPlace = location == .topLevel || location == .container
        // Blocks only where the engine says they fit, where `perform` puts them; all of them until it answered.
        if let answers = activeAnswers {
            let fitting = !inPlace || slashQuery == nil ? answers.afterTopLevel
                : lineIsEmptyButForTheQuery ? answers.inPlaceOfBlock : answers.afterBlock
            commands.removeAll { command in command.blockType.map { !fitting.contains($0) } ?? false }
        }
        // Columns hold columns, but the app puts none into a column.
        if inPlace, slashQuery != nil, document.ancestorTypes(of: active.ref.path).contains("columns") {
            commands.removeAll { if case .columns = $0 { true } else { false } }
        }
        return commands
    }

    /// The active line holds only the "/query": a block from the menu replaces it (`insertBlocks`).
    private var lineIsEmptyButForTheQuery: Bool {
        guard active?.type == "paragraph", let slashQuery else { return false }
        return activeText.characters.count == slashQuery.count + 1
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
        case .base, .kanban: dependencies.canCreateBases && dependencies.createBase != nil
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
        return TriggerParser.slash(in: activeText, cursor: cursor)
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
        session.scheduleCommit()
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

    /// Block types the active block can be turned into in place, for "/" and the toolbar, as the engine says
    /// (`conversions` in Engine/src/conversions.ts): none for a toggle's title or a footnote's text, the list kinds in a
    /// list item (for its whole list), a heading for an item's only line (it leaves the list). Until the engine has
    /// answered, all of them but for a toggle's title or a footnote's text, so the toolbar doesn't change there under the
    /// finger, and the engine refuses what doesn't fit.
    var conversionTemplates: [BlockTemplate] {
        guard let active else { return [] }
        let all: [BlockTemplate] = [.paragraph, .heading1, .heading2, .heading3, .bulletList, .orderedList, .taskList, .quote, .callout, .toggle, .codeBlock]
        guard let kinds = activeAnswers?.conversions else {
            return [.summary, .footnote].contains(insertLocation(of: active)) ? [] : all
        }
        return all.filter { kinds.contains($0.rawValue) }
    }

    /// Turns the active block into `template` where it is (`convert`); a list kind in a list item switches the item's
    /// whole list, which is that kind already when nothing happens.
    func convertActive(to template: BlockTemplate) {
        guard let active else { return }
        if let itemPath = active.itemPath, active.ref.path.count == itemPath.count + 1,
           node(at: Array(itemPath.dropLast()))?.type == template.rawValue { return }
        Task { await convert(active.ref, to: template) }
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
            Task { await insertBlocks([NodeFactory.tabs()], placement: placement, focus: .inside([0, 1, 0])) }
        case .drawio, .excalidraw:
            Task { await insertBlocks([PMNode(type: command == .drawio ? "drawio" : "excalidraw")], placement: placement, focus: .after) }
        case .mermaid:
            // Web parity: a code block with a sample; the page shows the diagram while the code isn't being edited.
            let sample = PMNode(type: "text", text: "flowchart LR\n    A --> B")
            Task { await insertBlocks([PMNode(type: "codeBlock", attrs: ["language": "mermaid"], content: [sample])], placement: placement, focus: .inside([])) }
        case .syncedBlock:
            Task { await insertBlocks([PMNode(type: "transclusionSource", content: [PMNode(type: "paragraph")])], placement: placement, focus: .inside([0])) }
        case .columns(let count):
            Task { await insertBlocks([NodeFactory.columns(count: count)], placement: placement, focus: .inside([0, 0])) }
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
                "data-id": .string(NodeFactory.newNodeId()), "referenceNumber": .string("\(footnoteNumber(at: offset))"),
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
        let position = min(max(offset, 0), count)
        let index = activeText.characters.index(activeText.startIndex, offsetBy: position)
        activeText.insert(run, at: index)
        let end = activeText.characters.index(activeText.startIndex, offsetBy: min(position + run.characters.count, activeText.characters.count))
        activeSelection = AttributedTextSelection(insertionPoint: end, typingAttributes: plainAfter ? AttributeContainer() : nil)
        session.scheduleCommit(debounce: .zero)
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
        /// As the engine said when the mention was tapped (`canShowAsCard`).
        var canShowAsCard = false
        var id: String { "\(ref.identity)/\(index)" }
        /// Whether `node`, the mention at its index by now, is this one: one put before it since links elsewhere.
        func isMeant(_ node: PMNode) -> Bool { node.string("url") == url }
        /// What "Open Link" opens in the in-app browser: web addresses only, as the web treats a mention with another
        /// address as one without a link (Safari's view throws, ending the app, on any other).
        var webURL: URL? {
            URL(string: url).flatMap { ContentLinkRouter.opening(for: $0) == .browser ? $0 : nil }
        }
    }

    var mentionActions: MentionTarget?

    enum IntegrationDisplay {
        case card, mention, link
    }

    /// Shows an integration card as a mention or a link, in a paragraph of its own.
    func showIntegrationCard(_ ref: NodeRef, as display: IntegrationDisplay) async {
        guard display != .card, let (_, card) = document.locate(ref) else { return }
        let url = card.string("url") ?? "", provider = card.string("provider") ?? ""
        let inline = display == .mention ? NodeFactory.integrationMention(url: url, provider: provider) : NodeFactory.integrationLinkText(url: url, provider: provider)
        await replace(ref, withNodes: [PMNode(type: "paragraph", content: [inline])])
    }

    /// Shows a mention as a link in its place, or as a card that splits its paragraph there (`blockReplacement`).
    func showMention(_ target: MentionTarget, as display: IntegrationDisplay) async {
        switch display {
        case .mention:
            return
        case .link:
            await replaceAtom(ofType: "integrationMention", in: target.ref, index: target.index, if: target.isMeant,
                              with: NodeFactory.integrationLinkText(url: target.url, provider: target.provider))
        case .card:
            // From the paragraph as the engine holds it: made from this copy, the card's paragraphs dropped what a
            // collaborator typed in it within the copy's lag.
            await replace(target.ref) { cardReplacement(for: target, in: $0) }
        }
    }

    /// Whether the mention can become a card where it is, as the engine says (`fits`); its paragraph needn't be the one
    /// being edited.
    func canShowAsCard(_ target: MentionTarget) async -> Bool {
        guard let engine, let (_, paragraph) = document.locate(target.ref), let nodes = cardReplacement(for: target, in: paragraph)
        else { return false }
        return await engine.fits(BlockPlace(target: target.ref.target, position: .replace), candidates: [nodes])?.first ?? false
    }

    /// The blocks that take the place of `paragraph` when its mention shows as a card (`blockReplacement`). Nil when the
    /// mention at the target's index links elsewhere: one went in before it since.
    private func cardReplacement(for target: MentionTarget, in paragraph: PMNode) -> [PMNode]? {
        guard let position = paragraph.childPosition(ofType: "integrationMention", index: target.index),
              target.isMeant(paragraph.children[position])
        else { return nil }
        return blockReplacement(NodeFactory.integrationCard(url: target.url, provider: target.provider), paragraph: paragraph,
                                before: Array(paragraph.children[..<position]), after: Array(paragraph.children[(position + 1)...]))
    }

    /// The service of the link at `range` of the active text that the workspace can show as a card or mention: the
    /// link's own (`integrationProvider`) or its host's, if that integration is installed, as on the web.
    func integrationProvider(ofLinkIn range: Range<AttributedString.Index>) -> String? {
        guard dependencies.hasDocmost097Features, let previews = dependencies.linkPreviews, let run = activeText[range].runs.first, let url = run.link
        else { return nil }
        let provider = run.docmost.linkProvider
            ?? IntegrationLinks.describe(url.absoluteString, unfurlHosts: previews.unfurlHosts).provider?.rawValue
        guard let provider, previews.installedTypes.contains(provider) else { return nil }
        return provider
    }

    /// Whether the link at `range` of the active text can become a card where it is.
    func canShowLinkAsCard(in range: Range<AttributedString.Index>) -> Bool {
        blockFitsInActiveLine("integrationCard", around: range)
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
            let mention = NodeFactory.integrationMention(url: url, provider: provider)
            insertIntoActiveText(Self.editorText(from: [mention]), offset: offset, plainAfter: true)
        case .card:
            placeBlockInActiveText(NodeFactory.integrationCard(url: url, provider: provider), replacing: range)
        }
    }

    // MARK: Blocks in a paragraph (cards, inline databases)

    /// The blocks that take a paragraph's place when a card or inline database goes into it, as on the web: the text
    /// before (without its trailing spaces), the block, the text after (without its leading spaces), each part only if
    /// it isn't empty. Nil outside a paragraph. Whether they fit there is the engine's to say, as the web asks its schema
    /// (`getBlockPlacement`): not in table cells, synced blocks and footnotes, nor in place of a list item's first line.
    private func blockReplacement(_ block: PMNode, paragraph: PMNode, before: [PMNode], after: [PMNode]) -> [PMNode]? {
        guard paragraph.type == "paragraph" else { return nil }
        let before = Self.trimmingSpaces(before, atEnd: true), after = Self.trimmingSpaces(after, atEnd: false)
        return (before.isEmpty ? [] : [PMNode(type: "paragraph", attrs: paragraph.attrs, content: before)]) + [block]
            + (after.isEmpty ? [] : [PMNode(type: "paragraph", attrs: paragraph.attrs, content: after)])
    }

    /// Whether a card or inline database of `type` fits in place of the active line, with its text before and after
    /// `range` (`answers`).
    private func blockFitsInActiveLine(_ type: String, around range: Range<AttributedString.Index>) -> Bool {
        guard let answers = activeAnswers else { return false }
        let (before, after) = activeInlines(around: range)
        return answers.inLine.contains(InLine(type: type, textBefore: !Self.trimmingSpaces(before, atEnd: true).isEmpty,
                                              textAfter: !Self.trimmingSpaces(after, atEnd: false).isEmpty))
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

    /// Whether a card or inline database of `type` can take the place of `length` characters at the active text's
    /// `offset`.
    private func blockFits(_ type: String, replacing offset: Int, length: Int = 0) -> Bool {
        guard offset >= 0, offset + length <= activeText.characters.count else { return false }
        let start = activeText.characters.index(activeText.startIndex, offsetBy: offset)
        return blockFitsInActiveLine(type, around: start..<activeText.characters.index(start, offsetBy: length))
    }

    /// Puts a card or inline database in place of `range` of the active text (an empty range: at the cursor), splitting
    /// the paragraph there (`blockReplacement`). The cursor goes to the text after it: the paragraph's rest, else the
    /// next text block, else a new paragraph if nothing follows (as after inserting other blocks).
    @discardableResult
    private func placeBlockInActiveText(_ block: PMNode, replacing range: Range<AttributedString.Index>) -> Bool {
        guard let engine, let active, let line = session.currentNode(), let (path, paragraph) = document.locate(active.ref)
        else { return false }
        let (before, after) = activeInlines(around: range)
        // Asked before the active line's input goes into the new blocks: refused there, it would be lost.
        guard blockFitsInActiveLine(block.type, around: range),
              var nodes = blockReplacement(block, paragraph: line, before: before, after: after),
              let blockOffset = nodes.firstIndex(of: block)
        else { return false }
        let parentPath = Array(path.dropLast()), index = path[path.count - 1]
        // The cursor's block, counted from the first new one where the engine put it (`placeBlocks`).
        var focus: Int? = blockOffset + 1
        if nodes.last == block {
            let siblings = parentPath.isEmpty ? document.children : node(at: parentPath)?.children ?? []
            if siblings.indices.contains(index + 1), siblings[index + 1].type != "footnotes" {
                if !PMNode.editableTextTypes.contains(siblings[index + 1].type) { focus = nil }
            } else {
                nodes.append(PMNode(type: "paragraph"))
            }
        }
        slashQuery = nil
        showsPlusMenu = false
        let ref = active.ref, target = NodeRef(path: path, node: paragraph).target
        Task {
            // The line's input goes in first, with its base, so the engine keeps a collaborator's words in it. The new
            // blocks then take the line's place only while it is what they were made from (`expected`): written over it
            // unchecked, they dropped what a collaborator typed there within this copy's lag. Refused, the line stays as
            // the engine holds it, the input in it.
            await flush()
            guard self.active?.ref.identity == ref.identity, session.overrides[ref.identity] == nil else { return }
            let expected = session.base ?? line
            // The new blocks hold the active text.
            session.dropActive()
            let (applied, placed) = await engine.placeBlocks(nodes, at: target, position: .replace, expected: expected)
            if report(applied), let focus, let placed {
                await focusAfterOperation(Self.sibling(of: placed, offset: focus), .start)
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

    /// The paste proxy's question for clipboard text that is a single web link: true if the page inserts it itself, as
    /// the web does, false for a plain paste. Over selected text the link goes onto that text. Otherwise the link goes in
    /// as a link at once; then a link of an installed integration (Docmost 0.97, in a paragraph) asks how to show it,
    /// and a link to a page of this server becomes a mention of the page once found (a database page then offers to
    /// embed it, on 0.97). The paste always changes the text right away: text changed only after a paste that inserted
    /// nothing left the editor's text view sending typed characters nowhere.
    func pasteLink(_ text: String) -> Bool {
        if pasteLinesIntoTitle(text) { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let active, active.type != "codeBlock", !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        if linkSelection(to: url) { return true }
        let offset = cursorOffset()
        var provider: IntegrationLinks.Provider?
        if dependencies.hasDocmost097Features, active.type == "paragraph", let previews = dependencies.linkPreviews {
            provider = IntegrationLinks.provider(of: trimmed, installed: previews.installedTypes, unfurlHosts: previews.unfurlHosts)
        }
        let pasted = insertLinkText(url, provider: provider, at: offset)
        if let provider {
            pastedLink = PastedLink(url: url, provider: provider, base: nil, allowsBlock: blockFits("integrationCard", replacing: offset, length: pasted.count),
                                    ref: active.ref, offset: offset, text: pasted)
            return true
        }
        guard let serverURL = dependencies.serverURL, let lookUpPage = dependencies.lookUpPage,
              let slugId = Self.pageSlugId(of: url, serverURL: serverURL) else { return true }
        let ref = active.ref
        Task {
            // A page that can't be found (or not seen) stays a link, as on the web. So does one while a sheet holds the text:
            // the link sheet keeps its range in it.
            guard let page = await lookUpPage(slugId), self.active?.ref == ref, !self.editsInSheet,
                  let range = activeRange(offset: offset, text: pasted)
            else { return }
            let linked = LinkedPage(id: page.id, slugId: page.slugId, title: page.title ?? "", anchor: url.fragment)
            let mention = Self.editorText(from: [pageMention(linked)])
            replaceActiveText(range, with: mention)
            keyboardFollowsText()
            if dependencies.hasDocmost097Features, page.isBase == true, blockFits("base", replacing: offset, length: mention.characters.count) {
                pastedLink = PastedLink(url: url, provider: nil, base: linked, allowsBlock: true, ref: ref, offset: offset,
                                        text: String(mention.characters))
            }
        }
        return true
    }

    /// The page a link of this server points to, as the web matches it: a query such as `?commentId=` or a database
    /// entry's `?row=` doesn't count.
    private static func pageSlugId(of url: URL, serverURL: URL) -> String? {
        guard case .page(let selection, _) = LinkTarget.of(url, serverURL: serverURL) else { return nil }
        return selection.pageId
    }

    /// A mention of the page, as the web makes one from a pasted link ("Untitled" unlocalized as there).
    private func pageMention(_ page: LinkedPage) -> PMNode {
        NodeFactory.mention(entityType: "page", entityId: page.id, label: page.title.isEmpty ? "Untitled" : page.title,
                            slugId: page.slugId, creatorId: dependencies.currentUserId, anchorId: page.anchor)
    }

    /// Replaces the paste as chosen; nil (the question dismissed) keeps it.
    func finishPastedLink(_ choice: PasteChoice?) {
        guard let link = pastedLink else { return }
        pastedLink = nil
        guard let choice, active?.ref == link.ref, let range = activeRange(offset: link.offset, text: link.text) else { return }
        let url = link.url.absoluteString, provider = link.provider?.rawValue ?? ""
        switch choice {
        case .card:
            placeBlockInActiveText(NodeFactory.integrationCard(url: url, provider: provider), replacing: range)
        case .embeddedBase:
            if let base = link.base {
                placeBlockInActiveText(PMNode(type: "base", attrs: ["pageId": .string(base.id)]), replacing: range)
            }
        case .mention:
            // A database link is its mention already.
            if link.base == nil {
                replaceActiveText(range, with: Self.editorText(from: [NodeFactory.integrationMention(url: url, provider: provider)]))
            }
        case .link:
            break
        }
    }

    /// After the active text changed without the user (an answer arriving), the keyboard still works on the old text:
    /// what was typed next went nowhere until the user moved the cursor. Reloading it makes it read the text again,
    /// once the text view shows the new text (reloaded before, it read the old one again). And once more a moment
    /// later: the first reload sometimes still found the text view busy with the change, and typing stayed lost (test74,
    /// about one run in four). Key events from outside the on-screen keyboard can still go nowhere after a paste
    /// (BACKLOG).
    private func keyboardFollowsText() {
        let expected = String(activeText.characters)
        Task { @MainActor [weak self, clock = dependencies.clock] in
            for _ in 0..<20 {
                guard let view = self?.editorTextView else { return }
                if view.text == expected {
                    view.reloadInputViews()
                    try? await clock.sleep(for: .milliseconds(300))
                    // Nothing typed meanwhile: then reloading again costs nothing.
                    if view.text == expected, view === self?.editorTextView { view.reloadInputViews() }
                    return
                }
                try? await clock.sleep(for: .milliseconds(25))
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
            // Clamped: a run starting with a combining mark merges with the character before it, so the text can be
            // shorter than both parts.
            let end = activeText.characters.index(activeText.startIndex, offsetBy: min(start + run.characters.count, activeText.characters.count))
            activeSelection = AttributedTextSelection(insertionPoint: end, typingAttributes: AttributeContainer())
        }
        session.scheduleCommit(debounce: .zero)
    }

    /// A link pasted over selected text links that text, as on the web.
    private func linkSelection(to url: URL) -> Bool {
        guard case .ranges(let ranges) = activeSelection.indices(in: activeText) else { return false }
        let selected = ranges.ranges.filter { !$0.isEmpty }
        guard !selected.isEmpty else { return false }
        for range in selected { activeText[range].link = url }
        session.scheduleCommit(debounce: .zero)
        return true
    }

    /// The link as linked text, remembering its service as the web does (`integrationProvider`); returns the text.
    @discardableResult
    private func insertLinkText(_ url: URL, provider: IntegrationLinks.Provider?, at offset: Int) -> String {
        var run = AttributedString(url.absoluteString)
        run.link = url
        if let provider { run.docmost.linkProvider = provider.rawValue }
        insertIntoActiveText(run, offset: offset, plainAfter: true)
        return url.absoluteString
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
        Task { @MainActor [weak self, clock = dependencies.clock] in
            try? await clock.sleep(for: .milliseconds(250))
            self?.emojiReturning = false
        }
    }

    /// Result of the status or math sheet: insert, replace, or (for `nil`) remove.
    func applyAtom(_ node: PMNode?, type: String, target: EditorSheet.AtomTarget) async {
        switch target {
        case .insert(let offset):
            if let node { insertAtom(node, offset: offset) }
        case .edit(let ref, let index, let atom):
            await replaceAtom(ofType: type, in: ref, index: index, if: { $0 == atom }, with: node)
        }
    }

    func atom(ofType type: String, in ref: NodeRef, index: Int) -> PMNode? {
        guard let (_, node) = document.locate(ref), let position = node.childPosition(ofType: type, index: index) else { return nil }
        return node.children[position]
    }

    /// Removes a mention (its menu's "Remove").
    func removeMention(_ target: MentionTarget) async {
        await replaceAtom(ofType: "integrationMention", in: target.ref, index: target.index, if: target.isMeant, with: nil)
    }

    /// Replaces or removes the `index`-th atom of type `type` in a (non-active) block as the engine holds it, while it is
    /// the one meant (`isMeant`). Taken by its index alone, it could be a collaborator's atom put before it while a sheet
    /// was open, and the edit overwrote theirs.
    private func replaceAtom(ofType type: String, in ref: NodeRef, index: Int, if isMeant: (PMNode) -> Bool,
                             with replacement: PMNode?) async {
        guard let engine, let block = await currentBlock(ref) else { return }
        let node = block.latest
        guard let position = node.childPosition(ofType: type, index: index), isMeant(node.children[position]) else {
            report(.refused)
            return
        }
        var children = node.children
        if let replacement { children[position] = replacement } else { children.remove(at: position) }
        let updated = PMNode(type: node.type, attrs: node.attrs, content: children.isEmpty ? nil : children)
        report(await engine.replaceBlock(block.ref.target, with: updated, base: nil, expected: block.source))
    }

    /// Number for a new footnote reference: references before it plus one (the engine renumbers afterwards).
    private func footnoteNumber(at offset: Int) -> Int {
        guard let active else { return 1 }
        var count = 0
        func walk(_ node: PMNode, path: [Int]) {
            for (index, child) in node.children.enumerated() where child.type != "footnotes" {
                if child.type == "footnoteReference" {
                    if path.precedes(active.ref.path) { count += 1 }
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

    // MARK: Blocks

    /// Inserts blocks at `placement`, then moves the cursor per `focus`; without `focus`, editing ends.
    @discardableResult
    func insertBlocks(_ nodes: [PMNode], placement: BlockPlacement, focus: InsertFocus?) async -> EngineResult {
        guard let engine else { return .unavailable }
        guard !nodes.isEmpty else { return .applied }
        var anchor: NodeRef?
        switch placement {
        case .replaceOrAfter(let ref):
            anchor = document.locate(ref).map { NodeRef(path: $0.path, node: $0.node) }
        case .afterTopLevel(let ref):
            let top = [ref.path[0]]
            anchor = node(at: top).map { NodeRef(path: top, node: $0) }
        case .end:
            // The empty paragraph the editor keeps at the end becomes the new paragraph; other blocks go before it.
            // Never replaced: this copy can lag behind the engine, and a collaborator may just have typed there.
            anchor = contentBlocks.last.flatMap { last in
                last.node.type == "paragraph" && last.node.children.isEmpty && active?.ref != last.ref ? last.ref : nil
            }
            if let last = anchor, nodes == [PMNode(type: "paragraph")] {
                // Where the engine has it: a collaborator's blocks above move it. Removed by one meanwhile, a new paragraph
                // goes in at the end; focusing nothing, an inline command waiting for it went nowhere.
                if let (path, _) = await engine.currentDocument()?.locate(last) {
                    await focusAfterOperation(path, .end)
                    return .applied
                }
                anchor = nil
            }
        }
        let before = placement == .end
        var replace = false
        var replacedBlock: PMNode?
        if !before, let candidate = anchor, let latest = latestNode(at: candidate.path), latest.type == "paragraph", latest.children.isEmpty {
            // Replaced only if empty in the engine too: a collaborator may just have typed there.
            guard let block = await currentBlock(candidate) else { return .refused }
            if block.latest.type == "paragraph", block.latest.children.isEmpty {
                replace = true
                replacedBlock = block.source
                anchor = block.ref
            }
        }
        let next: PMNode?
        if let anchor {
            let index = anchor.path[anchor.path.count - 1]
            let parentPath = Array(anchor.path.dropLast())
            let siblings = parentPath.isEmpty ? document.children : node(at: parentPath)?.children ?? []
            let nextIndex = before ? index : index + 1
            next = siblings.indices.contains(nextIndex) ? siblings[nextIndex] : nil
        } else {
            next = nil
        }
        var blocks = nodes
        // Where the cursor goes, from the first new block where the engine put it (`placeBlocks`): into it, or into the
        // block after the new ones.
        var focusTarget: (path: ([Int]) -> [Int], cursor: CursorRequest)?
        let afterThem = { (first: [Int]) in Self.sibling(of: first, offset: nodes.count) }
        switch focus {
        case .inside(let relative):
            focusTarget = ({ $0 + relative }, .end)
        case .after:
            if let next, next.type != "footnotes" {
                if PMNode.editableTextTypes.contains(next.type) { focusTarget = (afterThem, .start) }
            } else {
                blocks.append(PMNode(type: "paragraph"))
                focusTarget = (afterThem, .start)
            }
        case nil:
            break
        }
        if let active {
            if replace, active.ref.identity == anchor?.identity {
                // The block goes away: stop writing its input.
                session.dropActive()
                slashQuery = nil
                showsPlusMenu = false
            } else if focusTarget == nil {
                deactivate()
            }
            // Otherwise it stays active until the new block takes focus (the keyboard stays up).
        }
        let position: BlockPlace.Position = replace ? .replace : before && anchor != nil ? .before : .after
        let (applied, placed) = await engine.placeBlocks(blocks, at: anchor?.target, position: position, expected: replacedBlock)
        if report(applied), let focusTarget, let placed {
            await focusAfterOperation(focusTarget.path(placed), focusTarget.cursor)
        }
        return applied
    }

    /// The path `offset` siblings after `path`.
    private static func sibling(of path: [Int], offset: Int) -> [Int] {
        var path = path
        path[path.count - 1] += offset
        return path
    }

    /// Whether `nodes` fit where `insertBlocks` puts them (in place of an empty line, or after a block), as the engine
    /// says.
    private func fits(_ nodes: [PMNode], at placement: BlockPlacement) async -> Bool {
        guard let engine else { return false }
        let place: BlockPlace
        switch placement {
        case .replaceOrAfter(let ref):
            guard let (path, node) = document.locate(ref) else { return false }
            let empty = node.type == "paragraph" && node.children.isEmpty
            place = BlockPlace(target: NodeRef(path: path, node: node).target, position: empty ? .replace : .after)
        case .afterTopLevel(let ref):
            let top = [ref.path[0]]
            place = BlockPlace(target: node(at: top).map { NodeRef(path: top, node: $0).target } ?? .path(top), position: .after)
        case .end:
            place = BlockPlace(target: nil, position: .after)
        }
        return await engine.fits(place, candidates: [nodes])?.first ?? false
    }

    /// Inserts an empty `template` block and puts the cursor in its first text.
    func insertTemplate(_ template: BlockTemplate, placement: BlockPlacement) async {
        await insertBlocks([template.node()], placement: placement, focus: template.firstTextPath.map { .inside($0) } ?? .after)
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
        guard let createBase = dependencies.createBase else { return }
        // Asked first: its page is created on the server before the block goes in, and stayed there when the block
        // didn't fit (in a synced block).
        guard await fits([PMNode(type: "base")], at: placement) else {
            notice = String(localized: "This can't be placed there.")
            return
        }
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

    /// Prepares, uploads and removes the files one at a time, so a large video isn't staged beside all the others, and
    /// inserts them together at `target`; `file` stages the one at an index in the server's folder (`UploadFile`). Run
    /// here, not in the page's view: uploads outlive the page by design (`leave`), and their errors went to a toast that
    /// closed with it. They go to the whole app now, as does an upload the page can no longer take (it went to the trash
    /// or became a database meanwhile, its engine ended).
    func upload(_ count: Int, to target: MediaTarget, file: @escaping @MainActor (Int, URL) async throws -> UploadFile?) {
        connection.uploadStarted()
        Task {
            defer { connection.uploadEnded() }
            guard let serverURL = dependencies.serverURL, let sendUpload = dependencies.sendUpload else { return }
            var attachments: [Attachment] = []
            for index in 0..<count {
                do {
                    guard let prepared = try await file(index, serverURL) else { continue }
                    defer { prepared.remove() }
                    attachments.append(try await sendUpload(prepared))
                } catch {
                    dependencies.postAppNotice?(String(localized: "Not uploaded: \(error.userMessage)"))
                }
            }
            guard !attachments.isEmpty, await insertUploads(attachments, to: target) != .applied else { return }
            dependencies.postAppNotice?(String(localized: "The upload couldn't be added to “\(connection.noticeTitle)”."))
        }
    }

    /// Inserts uploads in selection order: as attachment cards after "File attachment" (like the web client),
    /// otherwise embedded by type.
    @discardableResult
    func insertUploads(_ attachments: [Attachment], to target: MediaTarget) async -> EngineResult {
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
        guard let active, active.ref.isTopLevel else { return }
        await convert(active.ref, to: "syncedBlock")
    }

    /// Unsyncs a synced block's source: its content, including unsaved input inside, stays as normal blocks (`unsync` in
    /// Engine/src/conversions.ts).
    func unsyncSource(_ ref: NodeRef) async {
        guard let engine else { return }
        await flush()
        if active != nil { deactivate() }
        report(await engine.unsync(ref.target))
    }

    /// Unsyncs an embedded synced block once the server returned its content. It has no id, so the engine finds it where
    /// it is by then (`replaceReference`): a collaborator (or an edit before it) may have moved it meanwhile. Gone from
    /// the page already (a second tap's late answer), nothing happens.
    func unsyncReference(_ reference: PMNode, at ref: NodeRef, content nodes: [PMNode]) async {
        guard let engine, let sourcePageId = reference.string("sourcePageId"), let transclusionId = reference.string("transclusionId"),
              node(at: ref.path) == reference || document.path(where: { $0 == reference }) != nil
        else { return }
        if active != nil { deactivate() }
        report(await engine.replaceReference(at: ref.path, sourcePageId: sourcePageId, transclusionId: transclusionId, with: nodes))
    }

    /// Puts a template's blocks into a blank page, as the web's "Get started with" does; `false` once it isn't blank.
    func fill(with nodes: [PMNode]) async -> Bool {
        guard let engine, isBlank, !nodes.isEmpty else { return false }
        if active != nil { deactivate() }
        guard let first = topLevel.first else {
            return report(await engine.insertBlocks(nodes, relativeTo: nil, position: .after))
        }
        guard let block = await currentBlock(first.ref) else { return false }
        return report(await engine.replaceBlock(block.ref.target, withNodes: nodes, expected: block.source))
    }

    /// Replaces a block with others (unsyncing: the content instead of the wrapper or the reference).
    func replace(_ ref: NodeRef, withNodes nodes: [PMNode]) async {
        await replace(ref) { _ in nodes }
    }

    /// Replaces a block with others made from it as the engine holds it now (`currentBlock`), so they keep what a
    /// collaborator typed in it since; refused when `build` makes nothing of it.
    private func replace(_ ref: NodeRef, building build: (PMNode) -> [PMNode]?) async {
        guard let engine, let block = await currentBlock(ref) else { return }
        guard let nodes = build(block.latest) else {
            report(.refused)
            return
        }
        if active != nil { deactivate() }
        report(await engine.replaceBlock(block.ref.target, withNodes: nodes, expected: block.source))
    }

    // MARK: Columns

    /// Changes the column count like the web client (`setColumnCount` in Engine/src/conversions.ts): new columns are
    /// empty, removed ones merge into the last kept one.
    func setColumnCount(_ count: Int, at path: [Int]) async {
        guard let engine, (2...5).contains(count), let shown = node(at: path), shown.type == "columns", count != shown.children.count
        else { return }
        // Its input goes first: the engine merges the columns it has.
        await flush()
        if let active, active.ref.path.starts(with: path), active.ref.path.count > path.count, active.ref.path[path.count] >= count - 1 {
            // The active block is in a column that gets merged: end editing.
            deactivate()
        }
        report(await engine.setColumnCount(NodeRef(path: path, node: shown).target, count: count))
    }

    // MARK: Tabs

    /// The label of a tab node as plain text.
    static func tabLabel(of tab: PMNode) -> String {
        tab.children.first { $0.type == "tabLabel" }?.plainText ?? ""
    }

    /// Adds a tab at the end like the web's "+" ("Tab N", unlocalized as there); returns its path.
    @discardableResult
    func addTab(to tabsRef: NodeRef) async -> [Int]? {
        guard let engine, let (path, tabs) = document.locate(tabsRef), let last = tabs.children.last else { return nil }
        if active != nil { deactivate() }
        let lastRef = NodeRef(path: path + [tabs.children.count - 1], node: last)
        let tab = NodeFactory.tab(label: "Tab \(tabs.children.count + 1)")
        // Where the engine put it: counted in this copy, a tab a collaborator just added would be shown instead.
        let (applied, placed) = await engine.placeBlocks([tab], at: lastRef.target, position: .after, expected: nil)
        return report(applied) ? placed : nil
    }

    /// Sets a tab's label; empty or unchanged labels are left alone, as on the web.
    func renameTab(_ tabRef: NodeRef, to label: String) async {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, let (path, tab) = document.locate(tabRef), !label.isEmpty, label != Self.tabLabel(of: tab),
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
        guard let (_, tabs) = document.locate(tabsRef) else { return }
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
              let paragraph = footnotes.children[index].children.last, PMNode.editableTextTypes.contains(paragraph.type)
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
            editorSheet = .status(.edit(ref: ref, index: index, atom: node), text: node.string("text") ?? "", color: node.string("color") ?? "gray")
        case "mathInline":
            editorSheet = .mathInline(.edit(ref: ref, index: index, atom: node), latex: node.string("text") ?? "")
        case "integrationMention":
            var target = MentionTarget(ref: ref, index: index, url: node.string("url") ?? "", provider: node.string("provider") ?? "")
            Task {
                target.canShowAsCard = await canShowAsCard(target)
                mentionActions = target
            }
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
        return document.locate(NodeRef(path: [], id: identity)).map { NodeRef(path: $0.path, node: $0.node) }
    }

    // MARK: Active text

    func activeCodeChanged() {
        guard let active, active.type == "codeBlock", session.codeChangeIsInput() else { return }
        session.scheduleCommit()
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
        session.scheduleCommit()
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

    /// Saves the active block's pending input and waits for it (`ActiveTextSession.flush`).
    func flush() async {
        await session.flush()
    }

    // MARK: - Return and Backspace
    //
    // The engine decides where the lines go, from its document as it is when the key arrives, and applies the edit in one
    // transaction (`enter`, `backspace`, Engine/src/keys.ts); the model shows it and puts the cursor where the engine
    // says. The model built these edits from its copy of the page, reading the engine's document for the blocks to send.

    private func handleReturn(_ active: Active) async {
        guard let engine else { return }
        let full = activeText
        guard let newline = full.characters.firstIndex(of: "\n") else { return }
        let afterStart = full.characters.index(after: newline)
        // Text pasted or dictated with line breaks: a typed Return makes one.
        if full.characters[afterStart...].contains("\n") {
            await handleLines(active, text: full, caret: cursorOffset(), tailStaysInTitle: false)
            return
        }
        let before = AttributedString(full[full.startIndex..<newline])
        let after = AttributedString(full[afterStart..<full.endIndex])
        // Where the cursor goes in the new line: its start after a typed Return, where the text ends after two pasted
        // lines (the cursor after the paste, past the line break).
        let caretInAfter = cursorOffset() - full.characters.distance(from: full.startIndex, to: afterStart)
        // A toggle's title stays whole (web parity); any other line keeps the text before the cursor, and the text after
        // it goes to the new line.
        let keepsAll = active.type == "detailsSummary"
        session.adopt(keepsAll ? before + after : before)
        session.cancelCommit()

        let beforeInlines = Self.inlines(from: before, base: activeFont)
        let line = PMNode(type: active.type, attrs: active.attrs, content: beforeInlines.isEmpty ? nil : beforeInlines)
        let kept = session.currentNode() ?? line
        session.overrides[active.ref.identity] = kept
        let base = session.takeBase(of: active.ref, sending: kept)
        let result = await engine.enter(active.ref.target, keeping: line, after: Self.inlines(from: after, base: activeFont), base: base)
        guard case .moved(let cursor) = result else {
            if result == .refused { report(.refused) }
            guard self.active?.ref == active.ref else { return }
            // The line stays as typed, without the line break.
            if session.base == kept { session.base = base }
            if !keepsAll { activeText += after }
            if result == .refused {
                // Saved with the next input or when editing ends: an applied save now would hide the message at once.
                session.overrides[active.ref.identity] = session.currentNode()
            } else {
                // Kept for the engine's return, as any input (`ActiveTextSession`).
                session.scheduleCommit(debounce: .zero)
            }
            return
        }
        // Input typed meanwhile stored a newer override; it stays pending so its commit writes it.
        if session.overrides[active.ref.identity] == kept { session.overrides[active.ref.identity] = nil }
        session.saveRefused = false
        report(.applied)
        let pastedInto = !keepsAll && caretInAfter > 0 && caretInAfter <= after.characters.count
        await focusAfterOperation(cursor.path, pastedInto ? .offset(caretInAfter) : .start)
    }

    /// Line breaks pasted or dictated into the line, `text` its text with them: each line goes where Return puts it, in one
    /// step of the engine (`enterLines`), and the cursor to where the pasted text ends (`caret`, its offset in `text`;
    /// the line's end without it). Key by key, 100 lines took seconds, the editor jumping from line to line, and in a
    /// toggle's title they ran together. `tailStaysInTitle`: what was after the cursor stays in a toggle's title, as on
    /// Return there; only with a `caret` known for sure, as a moved one would cut the title elsewhere.
    private func handleLines(_ active: Active, text: AttributedString, caret: Int?, tailStaysInTitle: Bool) async {
        guard let engine else { return }
        let typed = Self.lines(of: text)
        var lines = typed
        let lastStart = text.characters.count - lines[lines.count - 1].characters.count
        var caretInLast = caret.flatMap { $0 >= lastStart ? $0 - lastStart : nil }
        if active.type == "detailsSummary", tailStaysInTitle, let split = caretInLast {
            let last = lines[lines.count - 1]
            let cut = last.characters.index(last.startIndex, offsetBy: split)
            lines[0] += AttributedString(last[cut...])
            lines[lines.count - 1] = AttributedString(last[..<cut])
            caretInLast = nil
        }
        session.adopt(lines[0])
        session.cancelCommit()

        let firstInlines = Self.inlines(from: lines[0], base: activeFont)
        let line = PMNode(type: active.type, attrs: active.attrs, content: firstInlines.isEmpty ? nil : firstInlines)
        let kept = session.currentNode() ?? line
        session.overrides[active.ref.identity] = kept
        let base = session.takeBase(of: active.ref, sending: kept)
        let rest = lines.dropFirst().map { Self.inlines(from: $0, base: activeFont) }
        let result = await engine.enterLines(active.ref.target, keeping: line, lines: rest, base: base)
        guard case .moved(let cursor) = result else {
            if result == .refused { report(.refused) }
            guard self.active?.ref == active.ref else { return }
            // The text stays in the line as typed, without the line breaks, as after a refused Return.
            if session.base == kept { session.base = base }
            activeText = typed.dropFirst().reduce(typed[0], +)
            if result == .refused {
                session.overrides[active.ref.identity] = session.currentNode()
            } else {
                session.scheduleCommit(debounce: .zero)
            }
            return
        }
        if session.overrides[active.ref.identity] == kept { session.overrides[active.ref.identity] = nil }
        session.saveRefused = false
        report(.applied)
        await focusAfterOperation(cursor.path, caretInLast.map { .offset($0) } ?? .end)
    }

    /// Plain text with line breaks pasted into a toggle's title, at the cursor: what was after the cursor stays in the
    /// title, as on Return there, and the lines go into its content (`handleLines`). Pasted by the text view, a single
    /// break looked like a typed Return, and the lines ran into the title. True if it took the paste.
    private func pasteLinesIntoTitle(_ text: String) -> Bool {
        let pasted = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let active, active.type == "detailsSummary", pasted.contains("\n"),
              case .insertionPoint(let cursor) = activeSelection.indices(in: activeText) else { return false }
        let combined = AttributedString(activeText[..<cursor]) + AttributedString(pasted) + AttributedString(activeText[cursor...])
        let caret = activeText.characters.distance(from: activeText.startIndex, to: cursor) + pasted.count
        Task.immediate {
            typingSwitches += 1
            defer { typingSwitchEnded() }
            await handleLines(active, text: combined, caret: caret, tailStaysInTitle: true)
        }
        return true
    }

    /// The lines of `text`, split at its line breaks, with their formatting. Not at a line break within a line (U+2028,
    /// a hard break).
    private static func lines(of text: AttributedString) -> [AttributedString] {
        var lines: [AttributedString] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.characters.index(after: index)
            if text.characters[index] == "\n" {
                lines.append(AttributedString(text[start..<index]))
                start = next
            }
            index = next
        }
        lines.append(AttributedString(text[start..<text.endIndex]))
        return lines
    }

    /// Backspace at a block's start: joins it with the text block before, removes it (an empty line after an image, a
    /// table …), leaves the list (a first item), turns from an empty code block into a paragraph or does nothing, as the
    /// engine decides (`backspace`). A join or a removal shows at once where the engine said it goes (`answers`), so text
    /// typed right after the key lands there.
    private func joinBackward(_ active: Active) async {
        guard let engine else { return }
        // A code block comes here only empty (`backspaceAtStart`).
        let typed = active.type == "codeBlock" ? [] : Self.inlines(from: activeText, base: activeFont)
        let plan = activeAnswers?.backspace.map { typed.isEmpty ? $0.empty : $0.text }
        if plan == .nothing { return }
        // Its input goes with it: into the text before, or away with the line. With the base it began from, so the engine
        // decides with the line as it holds it: a collaborator's words in it since go along instead of away. Read before
        // the join shows, which makes the block before the active one.
        let base = session.base
        session.cancelCommit()
        session.overrides[active.ref.identity] = nil
        let shown = plan.map { show($0, leaving: active, typed: typed) } ?? false
        let held = PMNode(type: active.type, attrs: active.attrs, content: typed.isEmpty ? nil : typed)
        let result = await engine.backspace(active.ref.target, holding: held, base: base)
        switch result {
        case .done(let done, let cursor):
            // A line that leaves its list with text stays the block being edited (its id goes along): what went with
            // the key is its base now, as after a save. With the base from before that input, the next save took the
            // input for a collaborator's and could write it twice.
            if done == .leave, !typed.isEmpty, self.active?.ref.id == active.ref.id, active.ref.id != nil { session.base = held }
            if shown {
                // Otherwise than shown (the page changed meanwhile): its document shows what happened.
                if case .join? = plan, done != plan { endEditingShownJoin() }
                return
            }
            switch done {
            case .join, .remove:
                if let cursor { await focusAfterOperation(cursor) } else { show(done, leaving: active, typed: typed) }
            case .leave, .plain:
                if let cursor { await focusAfterOperation(cursor) }
            case .nothing:
                session.scheduleCommit()
            }
        case .refused, .unavailable:
            if result == .refused { report(.refused) }
            if case .join? = plan, shown {
                endEditingShownJoin()
            } else if !shown, self.active?.ref == active.ref {
                // Its input stays: saved with the next input or when editing ends (an applied save now would hide the
                // message at once), or once the engine is back.
                if result == .refused { session.overrides[active.ref.identity] = session.currentNode() } else { session.scheduleCommit(debounce: .zero) }
            }
        }
    }

    /// Shows Backspace's join or removal before the engine has done it: the text block before with both texts, the cursor
    /// where they meet; after a removal, the end of the text before (a table's last cell, a closed toggle's title), or no
    /// editing without one. False for what it doesn't show.
    @discardableResult
    private func show(_ plan: BackspacePlan, leaving active: Active, typed: [PMNode]) -> Bool {
        switch plan {
        case .join(let path):
            // Only where the page shows that block right before the line: answers from a document the page doesn't show
            // yet (a collaborator's change above) can name another block there.
            guard document.lastTextBlock(before: active.ref.path)?.path == path, let previous = node(at: path),
                  PMNode.editableTextTypes.contains(previous.type) else { return false }
            let children = previous.children + typed
            // In the editor's characters, the unit `.offset` counts in: a mention or a line break isn't its plain text.
            activate(NodeRef(path: path, node: previous), node: PMNode(type: previous.type, attrs: previous.attrs, content: children.isEmpty ? nil : children),
                     cursor: .offset(Self.editorText(from: previous.children).characters.count))
            return true
        case .remove:
            if let target = document.lastTextBlock(before: active.ref.path), let node = node(at: target.path) {
                activate(target, node: node, cursor: .end)
            } else {
                deactivate()
            }
            return true
        case .leave, .plain, .nothing:
            return false
        }
    }

    /// Ends editing a join shown before the engine refused it or did otherwise, without saving the shown text: it would
    /// put the line's text into the block before a second time.
    private func endEditingShownJoin() {
        if let active { session.overrides[active.ref.identity] = nil }
        session.cancelCommit()
        deactivate()
    }


    // MARK: - Block operations

    /// Turns the line at `ref` into `template` where it is (`convert`).
    func convert(_ ref: NodeRef, to template: BlockTemplate) async {
        await convert(ref, to: template.rawValue)
    }

    /// Turns the line at `ref` into `kind` where it is, from the engine's block then (`convert` in
    /// Engine/src/conversions.ts); the cursor goes to the end of the new block's first line. The model built the new block
    /// from the engine's document read beforehand, and the engine refused it when a collaborator changed the block in
    /// between.
    private func convert(_ ref: NodeRef, to kind: String) async {
        guard let engine else { return }
        // Its input goes first: the engine turns the block it has.
        await flush()
        if active?.ref.identity == ref.identity { session.dropActive() }
        switch await engine.convert(ref.target, to: kind) {
        case .moved(let cursor):
            report(.applied)
            await focusAfterOperation(cursor.path, .end)
        case .refused: report(.refused)
        case .unavailable: break
        }
    }

    func toggleTask(itemPath: [Int]) async {
        guard let engine, let item = node(at: itemPath), item.type == "taskItem" else { return }
        report(await engine.setAttributes(.path(itemPath, type: item.type), attributes: ["checked": .bool(!(item.bool("checked") ?? false))]))
    }

    func delete(_ ref: NodeRef) async {
        guard let engine else { return }
        // Otherwise a pending commit would write into the deleted block and show an error.
        if active?.ref == ref { session.dropActive() }
        session.overrides[ref.identity] = nil
        report(await engine.deleteBlock(ref.target))
    }

    func duplicate(_ ref: NodeRef) async {
        // A list item's first line stands for its item: copied alone, it became a second line of the same item.
        var ref = ref
        if ref.path.last == 0, let around = enclosingItemPath(ref.path), around == Array(ref.path.dropLast()), let item = latestNode(at: around) {
            ref = NodeRef(path: around, node: item)
        }
        // Uses the latest text, even if the last input hasn't reached the engine yet.
        guard let engine, let node = latestNode(at: ref.path) else { return }
        if active != nil { deactivate() }
        report(await engine.insertBlock(node.strippingIds(), relativeTo: ref.target, position: .after))
    }

    /// Moves an element of the arrange sheet (`elements`) to another row. A list's item moves on its own, and a block
    /// moved between a list's items splits it, as the engine's `move` has it (Engine/src/steps.ts).
    func moveBlocks(from source: IndexSet, to destination: Int) async {
        guard let engine, let sourceIndex = source.first else { return }
        let blocks = elements
        guard blocks.indices.contains(sourceIndex) else { return }
        let targetIndex = destination > sourceIndex ? destination - 1 : destination
        guard targetIndex != sourceIndex, blocks.indices.contains(targetIndex) else { return }
        report(await engine.moveBlock(blocks[sourceIndex].ref.target, to: blocks[targetIndex].ref.target, position: targetIndex > sourceIndex ? .after : .before))
    }

    /// Moves an element (drag/drop, `elements`) before or after another.
    func moveBlock(identity: String, relativeTo destination: NodeRef, before: Bool) async {
        guard let engine, let source = elements.first(where: { $0.ref.identity == identity }), source.ref != destination else { return }
        if active != nil { deactivate() }
        report(await engine.moveBlock(source.ref.target, to: destination.target, position: before ? .before : .after))
    }

    // MARK: - Tables

    /// Table, row and column of the active block (if it is in a cell).
    var activeTablePosition: TablePosition? {
        active.flatMap { TablePosition(of: $0.ref.path, in: document) }
    }

    /// What the cell allows (merging, splitting, moving, sorting) is the engine's to say (`answers`); the app kept its own
    /// copy of the grid's rules.
    var activeTableState: TableState? {
        guard let position = activeTablePosition, let table = node(at: position.tablePath),
              let cell = node(at: [position.row, position.column], in: table)
        else { return nil }
        return TableState(table: table, cell: cell, applies: activeAnswers?.tableCommands ?? [],
                          align: active?.attrs?["textAlign"]?.stringValue.flatMap(TextAlign.init(rawValue:)) ?? .left)
    }

    /// Whether the active table's first row / first column consists of header cells.
    var activeTableHeaders: (row: Bool, column: Bool) {
        guard let position = activeTablePosition, let table = node(at: position.tablePath) else { return (false, false) }
        return Self.headers(of: table)
    }

    func editTable(_ edit: TableEdit) async {
        guard let engine, activeTablePosition != nil, !editsTable else { return }
        editsTable = true
        defer { editsTable = false }
        // The cell's typed text goes first: the edit can move its block or remove it.
        await flush()
        guard let cellBlock = active?.ref, let position = activeTablePosition else { return }
        // Through the cell's block, by its id: the table's path in this copy, which lags behind a collaborator's blocks
        // above, could reach the table beside it, and a deletion took that.
        let (result, focus) = await engine.tableCommand(cellBlock.target, cell: [position.row, position.column], command: edit.engineCommand)
        guard report(result), let focus, let latest = await engine.currentDocument() else { return }
        show(latest)
        // The table is gone: deleted, or its only row or column.
        guard !focus.isEmpty else {
            deactivate()
            return
        }
        if !edit.movesCursor, let active, active.ref.id != nil, document.locate(active.ref) != nil {
            // The block stays edited with its cursor, in its new place and with what changed (its alignment). Input
            // typed meanwhile stays: its save keeps the engine's changes (`rebase`).
            if session.overrides[active.ref.identity] == nil { adoptActiveBlock() } else { followMovedBlocks() }
            return
        }
        // To the cell's first text (into a list's first item); a cell starting with an image or formula ends editing.
        let path = document.textPath(from: focus)
        pendingFocus = (path, { _ in .end })
        adopt(latest)
        pendingFocus = nil
        if active?.ref.path != path { deactivate() }
    }

    func undo() async { await stepHistory(redo: false) }
    func redo() async { await stepHistory(redo: true) }

    /// Undo/redo through the engine's Yjs history (like the web editor), after flushing pending input into it. The
    /// active editor then adopts its block's new state, or it would keep its old text and write it back on typing.
    private func stepHistory(redo: Bool) async {
        guard let engine else { return }
        await flush()
        switch redo ? await engine.redo() : await engine.undo() {
        case .applied: break
        // TipTap refuses an empty history; the button used to do nothing without a word.
        case .refused:
            notice = redo ? String(localized: "Nothing to redo.") : String(localized: "Nothing to undo.")
            return
        case .unavailable: return
        }
        guard let latest = await engine.currentDocument() else { return }
        show(latest)
        adoptActiveBlock()
    }

    /// Adopts the active block's type, attrs and content from the document; ends editing if it is gone. After undo or redo
    /// the cursor keeps its offset, after a collaborator's change it moves with the text around it.
    private func adoptActiveBlock(followingChange: Bool = false) {
        guard let current = active else { return }
        guard let (path, node) = document.locate(current.ref) else {
            deactivate()
            return
        }
        var (start, end) = selectedOffsets()
        active = Active(ref: NodeRef(path: path, node: node), type: node.type, attrs: node.attrs, itemPath: enclosingItemPath(path))
        let text = node.type == "codeBlock" ? AttributedString(node.plainText) : Self.editorText(from: node.children)
        if followingChange {
            // Both ends of a selection move with the text around them: with its end alone, as a cursor, a word selected
            // while a collaborator typed in the line was no longer selected. A start where their text goes in moves past it.
            let old = Array(activeText.characters), new = Array(text.characters)
            start = Self.offset(start, movedFrom: old, to: new, after: start < end)
            end = Self.offset(end, movedFrom: old, to: new)
        }
        session.show(node, as: text)
        if followingChange {
            // Right away, in the same update as the text: a cursor request would hide the caret meanwhile, on every change
            // while a collaborator types.
            let count = activeText.characters.count
            let index = { self.activeText.characters.index(self.activeText.startIndex, offsetBy: min($0, count)) }
            activeSelection = start < end ? AttributedTextSelection(range: index(start)..<index(end)) : AttributedTextSelection(insertionPoint: index(end))
        } else if node.type != "codeBlock" {
            cursorRequest = .offset(end)
        }
    }

    /// The selection's start and end as character offsets into the active text; both the cursor's without a selection.
    private func selectedOffsets() -> (start: Int, end: Int) {
        let offset = { self.activeText.characters.distance(from: self.activeText.startIndex, to: $0) }
        let end = offset(insertionIndex())
        guard case .ranges(let ranges) = activeSelection.indices(in: activeText), let first = ranges.ranges.first else { return (end, end) }
        return (offset(first.lowerBound), end)
    }

    /// Where an offset in `old` lies in `new`, `new` being `old` with one stretch changed (a collaborator's edit): before
    /// the change it stays, after it it moves by the change in length, inside it goes to the change's end. Right at the
    /// change's start it stays before it, or goes past it `after`.
    static func offset(_ offset: Int, movedFrom old: [Character], to new: [Character], after: Bool = false) -> Int {
        let shorter = min(old.count, new.count)
        var prefix = 0
        while prefix < shorter, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        if offset < prefix || offset == prefix && !after { return offset }
        if offset >= old.count - suffix { return offset + new.count - old.count }
        return new.count - suffix
    }

    /// A block's current state, including unsaved input.
    private func latestNode(at path: [Int]) -> PMNode? {
        if let active, active.ref.path == path, let node = session.currentNode() { return node }
        return node(at: path, in: withOverrides(document))
    }

    /// The block a structural edit replaces (an atom, a card, a template), as the engine has it now: pending input is
    /// written first, as typing writes it, and the block is read from the engine's document, not from this copy, which
    /// lags behind while someone types. Built from this copy, a replacement used to overwrite what a collaborator typed
    /// since, without notice. `source` goes with the replacement as its expected state, so the engine refuses it if the
    /// block changes before it arrives; `latest` has input still pending over it. Nil, and said, when the block is gone
    /// or there is no engine.
    private func currentBlock(_ ref: NodeRef) async -> (ref: NodeRef, source: PMNode, latest: PMNode)? {
        guard let engine else { return nil }
        await flush()
        guard let current = await engine.currentDocument() else {
            report(.unavailable)
            return nil
        }
        let found = ref.id == nil ? ref.path : current.locate(ref)?.path
        guard let found, let source = node(at: found, in: current), ref.type == nil || source.type == ref.type else {
            report(.refused)
            return nil
        }
        return (NodeRef(path: found, node: source), source, node(at: found, in: withOverrides(current)) ?? source)
    }

    // MARK: - Helpers

    /// The node at `path` in `root`, the page's document by default (DocumentTree.swift).
    func node(at path: [Int], in root: PMNode? = nil) -> PMNode? {
        (root ?? document).node(at: path)
    }

    private func enclosingItemPath(_ path: [Int]) -> [Int]? {
        document.ancestorPath(of: path, types: ["listItem", "taskItem"])
    }

    /// A document with the local, unconfirmed changes applied.
    private func withOverrides(_ root: PMNode) -> PMNode {
        session.withOverrides(root)
    }

    /// Inline nodes from the editor text (with the formatting that arrives only as SwiftUI attributes while typing).
    static func inlines(from text: AttributedString, base: Font) -> [PMNode] {
        InlineAttributedText.inlines(from: EditorText.normalized(text, base: base))
    }

    /// Editor text from inline nodes (with the SwiftUI attributes that make the formatting visible while editing).
    static func editorText(from inlines: [PMNode]) -> AttributedString {
        EditorText.display(InlineAttributedText.attributedString(from: inlines))
    }

    /// The engine's `offset` into a text block's content (a character of text per UTF-16 unit, an inline node 1) in the
    /// editor's characters, which `CursorRequest.offset` counts in: a mention or a line break isn't its plain text.
    static func editorOffset(in node: PMNode, at offset: Int) -> Int {
        var before: [PMNode] = [], left = offset
        for child in node.children where left > 0 {
            guard let text = child.text else {
                before.append(child)
                left -= 1
                continue
            }
            let units = text.utf16.count
            before.append(units <= left ? child : PMNode(type: child.type, attrs: child.attrs, marks: child.marks,
                                                         text: String(decoding: Array(text.utf16.prefix(left)), as: UTF16.self)))
            left -= min(units, left)
        }
        return editorText(from: before).characters.count
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
            // Down to the first text node (e.g. table → row → cell → paragraph).
            path = document.textPath(from: path)
            if let node = node(at: path) {
                activate(NodeRef(path: path, node: node), node: node)
                if let typed = DebugLaunch.typeText {
                    try? await dependencies.clock.sleep(for: .milliseconds(300))
                    activeText.append(AttributedString(typed))
                    activeTextChanged()
                }
            }
        }
    }
    #endif
}

extension DocumentModel: EngineConnectionOwner {
    func connectionSent(_ document: PMNode) {
        adopt(document)
    }

    func connectionWritesInput() async {
        await flush()
    }

    func connectionEndsEditing() {
        deactivate()
    }

    func connectionKeepsInput() {
        session.keepInput()
    }

    func connectionSays(_ message: String?) {
        errorMessage = message
    }
}

extension DocumentModel: ActiveTextSessionOwner {
    func sessionReports(_ result: EngineResult) -> Bool {
        report(result)
    }

    func sessionShowsInput() {
        document = withOverrides(document)
    }

    func sessionShowsEngineDocument() {
        if let engineDocument { adopt(engineDocument) }
    }
}
