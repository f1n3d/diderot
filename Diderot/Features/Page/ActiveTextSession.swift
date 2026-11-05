import Foundation
import Observation
import SwiftUI
import DocmostKit

/// What the active text session needs from the page it serves (`DocumentModel`).
@MainActor
protocol ActiveTextSessionOwner: AnyObject {
    /// What the page needs from outside it, read when used: tests change it after the page is made.
    var dependencies: DocumentModel.Dependencies { get }
    /// Shows whether a save applied, as the page shows every edit's result; true if it did.
    func sessionReports(_ result: EngineResult) -> Bool
    /// Input the engine couldn't take: the page shows it over its blocks meanwhile, also for a block no longer edited.
    func sessionShowsInput()
    /// A save refused for a block no longer edited: the page shows the engine's block again.
    func sessionShowsEngineDocument()
}

/// The page's one text editor and its input on the way to the engine (code review S2): the block being edited, its text
/// and selection, the input not yet saved (shown over the engine's document), the base each save passes, and the saves
/// themselves: after a pause in typing, at once when editing moves on, or before an edit that needs them. What the keys
/// and menus do with the text stays with the page (`DocumentModel`).
@MainActor
@Observable
final class ActiveTextSession {
    /// The block being edited.
    var active: DocumentModel.Active? {
        didSet { if (active != nil) != hasActiveBlock { hasActiveBlock = active != nil } }
    }
    /// A block is being edited. Changes only when editing starts or ends, so every block can watch it (not `active`).
    private(set) var hasActiveBlock = false
    var text = AttributedString()
    var selection = AttributedTextSelection()
    /// Font the active text block draws with (set by its `TextNodeView`); saving compares system bold against it.
    @ObservationIgnored var font = Font.body
    /// Input not yet saved, by block identity: the page shows it over the engine's document.
    var overrides: [String: PMNode] = [:]
    /// The block the active editor's text was made from, or last sent as: a collaborator's change of it shows in the
    /// editor once nothing is pending (`DocumentModel.adoptCollaboratorsChange`), and saves pass it as their base, so the
    /// engine keeps a change that arrives meanwhile (`rebase`).
    @ObservationIgnored var base: PMNode?
    /// The last save was refused: only a later save's success takes its message away (`DocumentModel.report`).
    @ObservationIgnored var saveRefused = false
    @ObservationIgnored weak var owner: (any ActiveTextSessionOwner)?

    private let engine: (any DocumentEngine)?
    private var commitTask: Task<Void, Never>?
    /// Blocks whose input (still in `overrides`) the engine couldn't take: its web process ended or it stopped after an
    /// error. Written once it syncs again, with the base the input started from (`commit`).
    @ObservationIgnored private var unsaved: [String: (ref: NodeRef, base: PMNode?)] = [:]
    /// Active block state the app set itself (a block's text on activation, undo/redo, a collaborator's change): writing
    /// it back would save an untouched block, overwrite what others typed meanwhile and, after undo, lose "Redo".
    @ObservationIgnored private var adoptedText: AttributedString?
    @ObservationIgnored private var adoptedCode: String?

    init(engine: (any DocumentEngine)?) {
        self.engine = engine
    }

    /// The active code block's text. It lives in `text` (without formatting), so the page's one editor edits code like
    /// text and stays the same view from a code block to a text block and back.
    var code: String {
        get { String(text.characters) }
        set { text = AttributedString(newValue) }
    }

    /// Shows `node` in the editor as `text` (a code block's without formatting), with `node` as the base: the app's text,
    /// not input (`textChangeIsInput`, `codeChangeIsInput`).
    func show(_ node: PMNode, as text: AttributedString) {
        base = node
        self.text = text
        if node.type == "codeBlock" {
            adoptedCode = code
        } else {
            adoptedText = self.text
        }
    }

    /// Whether the text's change is input: not when it is the text the app just set itself (`show`).
    func textChangeIsInput() -> Bool {
        guard let adopted = adoptedText else { return true }
        adoptedText = nil
        return adopted != text
    }

    /// Whether the code's change is input: not when it is the code the app just set itself (`show`).
    func codeChangeIsInput() -> Bool {
        guard let adopted = adoptedCode else { return true }
        adoptedCode = nil
        return adopted != code
    }

    /// The active block with the editor's text, as a save sends it.
    func currentNode() -> PMNode? {
        guard let active else { return nil }
        if active.type == "codeBlock" {
            return PMNode(type: "codeBlock", attrs: active.attrs, content: code.isEmpty ? nil : [PMNode(type: "text", text: code)])
        }
        let inlines = DocumentModel.inlines(from: text, base: font)
        return PMNode(type: active.type, attrs: active.attrs, content: inlines.isEmpty ? nil : inlines)
    }

    /// A document with the input not yet saved over it.
    func withOverrides(_ root: PMNode) -> PMNode {
        root.applyingOverrides(overrides)
    }

    /// Saves the active block's input after `debounce` without more input; it shows over the engine's document meanwhile.
    func scheduleCommit(debounce: Duration = .milliseconds(400)) {
        guard let active, let node = currentNode(), let clock = owner?.dependencies.clock else { return }
        overrides[active.ref.identity] = node
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await clock.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.commit(active.ref, node: node, base: self.takeBase(of: active.ref, sending: node))
        }
    }

    /// A save waiting for a pause in typing doesn't go: the input goes another way (Return, Backspace) or not at all.
    func cancelCommit() {
        commitTask?.cancel()
    }

    /// Ends editing without writing the active block's pending input (the block is being replaced or removed).
    func dropActive() {
        guard let active else { return }
        commitTask?.cancel()
        overrides[active.ref.identity] = nil
        self.active = nil
        base = nil
    }

    /// Saves the active block's pending input now, without waiting for it: editing moves to another block or ends.
    func commitPendingNow() {
        guard let active, overrides[active.ref.identity] != nil, let node = currentNode() else { return }
        commitTask?.cancel()
        commitTask = nil
        let ref = active.ref
        // Taken now: the block activated next brings its own.
        let base = takeBase(of: ref, sending: node)
        Task { await commit(ref, node: node, base: base) }
    }

    /// Saves the active block's pending input and waits for it: before an edit that needs it in the engine.
    func flush() async {
        commitTask?.cancel()
        commitTask = nil
        if let active, let node = currentNode(), overrides[active.ref.identity] != nil {
            await commit(active.ref, node: node, base: takeBase(of: active.ref, sending: node))
        }
    }

    /// The base for a save of the active block (`base`); the saved node becomes the next one, as the engine applies saves
    /// in order. Nil for another block.
    func takeBase(of ref: NodeRef, sending node: PMNode) -> PMNode? {
        guard active?.ref.identity == ref.identity else { return nil }
        defer { base = node }
        return base
    }

    /// The engine ended or stopped: the active block's input it hadn't saved goes in once it is back (`unsaved`).
    func keepInput() {
        guard let active, overrides[active.ref.identity] != nil else { return }
        unsaved[active.ref.identity] = (active.ref, base)
    }

    /// The engine is back: the input it couldn't take goes in, the latest of each block. Typed further meanwhile, it is in
    /// `overrides`; dropped since (its block went), nothing goes.
    func writeUnsaved() {
        guard !unsaved.isEmpty else { return }
        let waiting = Array(unsaved.values)
        unsaved = [:]
        Task {
            for (ref, base) in waiting {
                if let node = overrides[ref.identity] { await commit(ref, node: node, base: base) }
            }
        }
    }

    private func commit(_ ref: NodeRef, node: PMNode, base: PMNode?) async {
        guard let engine else { return }
        let pending = overrides[ref.identity]
        let result = await engine.replaceBlock(ref.target, with: node, base: base)
        // Not applied: the block keeps what it had.
        if !result.isApplied, active?.ref.identity == ref.identity, self.base == node { self.base = base }
        if result == .unavailable {
            // No engine to take it (its web process ended, it stopped after an error): the input stays, also for a block
            // no longer edited, and goes in once the engine is back. It used to be dropped as refused.
            if overrides[ref.identity] == pending { overrides[ref.identity] = node }
            unsaved[ref.identity] = (ref, base)
            // A block no longer edited shows it meanwhile, not what it had.
            owner?.sessionShowsInput()
            return
        }
        saveRefused = result == .refused
        if owner?.sessionReports(result) ?? result.isApplied {
            // Input typed during the save stored a newer override; it stays pending so its commit or `flush` writes it.
            if overrides[ref.identity] == pending { overrides[ref.identity] = nil }
        } else if active?.ref != ref {
            // Refused for a block no longer edited: its text must not stay over the saved one, nor be written later
            // into another block that takes its place.
            overrides[ref.identity] = nil
            owner?.sessionShowsEngineDocument()
        }
    }
}
