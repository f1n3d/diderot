import Foundation
import Observation
import DocmostKit

/// What the page's engine connection needs from the page it serves (`DocumentModel`).
@MainActor
protocol EngineConnectionOwner: AnyObject {
    /// What the page needs from outside it, read when used: tests change it after the page is made.
    var dependencies: DocumentModel.Dependencies { get }
    /// A document the engine sent while opening or live: the page shows it.
    func connectionSent(_ document: PMNode)
    /// The input still waiting for its save goes in: before the engine closes or keeps the unsent changes.
    func connectionWritesInput() async
    /// Editing ends, its input saved: the page leaves or may no longer be edited.
    func connectionEndsEditing()
    /// The engine ended or stopped: the active block's input it hadn't saved goes in once it is back.
    func connectionKeepsInput()
    /// The page's message about the connection; nil takes it away.
    func connectionSays(_ message: String?)
}

/// The page's engine from opening to closing (code review S2): where it is, why the page is read-only, opening and closing
/// one after the other, keeping the changes the server hasn't confirmed on the device, the uploads that keep it open, and
/// what follows when it fails or its web process ends. The page (`DocumentModel`) shows the engine's documents and edits
/// through it; this decides when it can.
@MainActor
@Observable
final class EngineConnection {
    /// Where the page's engine is: opening until its first document (from the start: it opens when the page appears),
    /// live from then on, closing from `suspend` until it is closed. Documents count while it opens or is live: one still
    /// on its way after `suspend`, or the closing engine's last, used to make the page live again, editable while its
    /// engine closed.
    enum Lifecycle {
        case closed, opening, live, closing
    }

    let engine: (any DocumentEngine)?
    @ObservationIgnored weak var owner: (any EngineConnectionOwner)?
    private(set) var lifecycle = Lifecycle.closed
    var isLive: Bool { lifecycle == .live }
    private(set) var readOnlyReason: DocumentModel.ReadOnlyReason?
    /// Uploads running for this page (`DocumentModel.upload`); the page shows "Uploading…", and `leave` keeps its engine
    /// open for them.
    private(set) var uploads = 0
    /// Why the engine couldn't keep the unsent changes on the device (a full disk), until a later save keeps them.
    private(set) var unsentNotKept: String?
    /// The page's banner for it, while the server hasn't confirmed every change: once it has, nothing is at risk.
    var unsentWarning: String? { hasUnconfirmedChanges ? unsentNotKept : nil }
    /// The server hasn't confirmed every change (`DocumentEngine.unconfirmedChanges`).
    var hasUnconfirmedChanges: Bool { (engine?.unconfirmedChanges ?? 0) > 0 }

    private let page: Page
    /// Serializes engine open/close: leaving while it opens (or returning while it closes) never leaves it half-open.
    @ObservationIgnored private var engineStep: Task<Void, Never>?
    @ObservationIgnored private var unsentSave: Task<Void, Never>?
    /// `suspend` calls whose close is still to come: the page stays closing until the last one is done, and an open
    /// queued between them doesn't make it live.
    @ObservationIgnored private var pendingCloses = 0
    @ObservationIgnored private var suspendsAfterUploads = false
    /// The engine was opened again after an error (`EngineFailure.engineError`); another one leaves the page read-only.
    @ObservationIgnored private var restartedAfterError = false

    init(page: Page, engine: (any DocumentEngine)?, readOnlyReason: DocumentModel.ReadOnlyReason?) {
        self.page = page
        self.engine = engine
        self.readOnlyReason = readOnlyReason
        if engine != nil { lifecycle = .opening }
        // A page that is gone does nothing (`serves`): a close still on its way keeps the connection.
        engine?.onDocument = { [weak self] document in if let self, serves { engineSent(document) } }
        engine?.onUnsentChangesKept = { [weak self] error in if let self, serves { unsentChangesKept(error) } }
        engine?.onFailure = { [weak self] failure in if let self, serves { failed(failure) } }
        engine?.onTerminated = { [weak self] in if let self, serves { terminated() } }
    }

    /// The page this serves is still there.
    private var serves: Bool { owner != nil }

    /// The page's title in the app's notices, which outlive it.
    var noticeTitle: String {
        page.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled")
    }

    /// Opens the engine unless it is open: when the page appears, after `suspend`, and to retry a failed start.
    func resume() {
        // Each step keeps its page until it is done (`stop` writes its input and stores its document).
        let owner = self.owner
        suspendsAfterUploads = false
        let previous = engineStep
        engineStep = Task {
            await previous?.value
            guard let engine, engine.status == .idle || readOnlyReason == .notConnected else { return }
            // A refused live connection leaves the engine open with changes the server never confirmed (e.g. made
            // offline): closed as leaving does, it keeps them for the reopened engine to send.
            if engine.status != .idle { await stop(owner) }
            // Read-only until the reopened engine sends its document, even if one arrived while it was closing. Still
            // closing if the page left meanwhile: that `suspend` closes it after this open.
            if pendingCloses == 0 { lifecycle = .opening }
            if readOnlyReason == .notConnected {
                readOnlyReason = nil
                owner?.connectionSays(nil)
            }
            do {
                try await engine.open(pageId: page.id)
            } catch {
                if lifecycle == .opening { lifecycle = .closed }
                readOnlyReason = .notConnected
                owner?.connectionSays(error.userMessage)
            }
        }
    }

    /// The page left the screen (closed, under a pushed page, tab switch). An upload still running goes into this page, so
    /// the engine stays open until the last one is in; otherwise as `suspend`.
    func leave() {
        guard uploads > 0 else {
            suspend()
            return
        }
        owner?.connectionEndsEditing()
        suspendsAfterUploads = true
    }

    /// Read-only until `resume` reopens the engine.
    @discardableResult
    func suspend() -> Task<Void, Never> {
        let owner = self.owner
        // Commits pending input in a task queued ahead of the stop below, so the stored document includes it.
        owner?.connectionEndsEditing()
        unsentSave?.cancel()
        // What the closing engine can't keep goes to the whole app (`unsentChangesKept`); the reopened one starts afresh.
        unsentNotKept = nil
        lifecycle = .closing
        pendingCloses += 1
        let previous = engineStep
        let step = Task {
            await previous?.value
            await stop(owner)
            pendingCloses -= 1
            if pendingCloses == 0 { lifecycle = .closed }
        }
        engineStep = step
        return step
    }

    /// The app went to the background: keeps unsent changes as leaving the page would, with pending input.
    func saveUnsentChanges() async {
        guard let engine, isLive else { return }
        await owner?.connectionWritesInput()
        await engine.saveUnsentChanges()
    }

    /// The page showed a document of the engine. Every local change brings one, also those that bypass the page's saves
    /// (inserts, moves, undo), and the engine counts it as unconfirmed before.
    func documentShown() {
        if let engine, engine.unconfirmedChanges > 0 { scheduleUnsentSave() }
    }

    /// An upload for this page started (`DocumentModel.upload`).
    func uploadStarted() {
        uploads += 1
    }

    /// An upload ended: after the last one, a page that left while they ran closes its engine.
    func uploadEnded() {
        uploads -= 1
        if uploads == 0, suspendsAfterUploads {
            suspendsAfterUploads = false
            suspend()
        }
    }

    /// Keeps changes the server hasn't confirmed as leaving the page does, 2 s after the last change while one is
    /// unconfirmed: until then they lived only in the engine's web process, gone if the app crashed or was swiped away.
    /// Keyed to the engine's status before, it missed a connection that died without notice: until the engine noticed
    /// (after 30 s), the page said "Saved" and kept nothing.
    private func scheduleUnsentSave() {
        unsentSave?.cancel()
        guard let clock = owner?.dependencies.clock else { return }
        unsentSave = Task { [weak self] in
            try? await clock.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, serves else { return }
            // Queued like opening and closing: beside a close, an older state could be kept after it.
            let previous = engineStep
            engineStep = Task {
                await previous?.value
                guard self.isLive, let engine = self.engine, engine.unconfirmedChanges > 0 else { return }
                await engine.saveUnsentChanges()
            }
        }
    }

    /// A save of the unsent changes ended (`DocumentEngine.onUnsentChangesKept`). The page on screen says so in its
    /// banner until a save keeps them; one that left (its engine closing) tells the whole app, as it shows nothing more.
    private func unsentChangesKept(_ error: (any Error)?) {
        guard let error else {
            unsentNotKept = nil
            return
        }
        if lifecycle == .closing || lifecycle == .closed {
            owner?.dependencies.postAppNotice?(UnsentChanges.mayBeLostNotice(title: noticeTitle, error))
        } else {
            unsentNotKept = UnsentChanges.notKeptWarning(error)
        }
    }

    /// A document the engine sent (`onDocument`); the first one after opening makes the page live.
    private func engineSent(_ incoming: PMNode) {
        guard lifecycle == .opening || lifecycle == .live else { return }
        lifecycle = .live
        owner?.connectionSent(incoming)
    }

    /// The engine failed (`onFailure`).
    private func failed(_ failure: EngineFailure) {
        switch failure {
        // Like a failed start: read-only, and `resume` tries again.
        case .unsupportedContent:
            readOnlyReason = .notConnected
            owner?.connectionSays(String(localized: "This page has content that this version of the app can't edit yet. You can edit it in the web editor."))
        case .connectionRefused:
            readOnlyReason = .notConnected
            owner?.connectionSays(String(localized: "The server refused the live connection. The page is read-only."))
        // The engine stays connected, so others' edits keep showing. What the server didn't take stays in the unsent
        // changes, which the page's next open sends: they count once the user may edit again.
        case .readOnly:
            owner?.connectionEndsEditing()
            readOnlyReason = .noPermission
            owner?.connectionSays(String(localized: "You can no longer edit this page. Changes the server didn't take stay on this device until you can edit it again."))
        // As after a web process that ended, once per page: a reopened engine binds the shared document afresh, and
        // input it hadn't saved goes in once it is back. Again, or before the page was live: read-only until `resume`.
        case .engineError:
            owner?.connectionKeepsInput()
            if isLive, !restartedAfterError {
                restartedAfterError = true
                suspend()
                resume()
            } else {
                owner?.connectionEndsEditing()
                // It closed itself.
                if lifecycle != .closing { lifecycle = .closed }
                readOnlyReason = .notConnected
                owner?.connectionSays(String(localized: "The editor stopped after an error. The page is read-only; pull down to try again."))
            }
        }
    }

    /// The engine's web process ended (`onTerminated`). It restarts only if live: a page that left reopens on return; one
    /// still opening tries again when the app becomes active (or on refresh). Input the engine hadn't saved yet goes in
    /// once it is back.
    private func terminated() {
        owner?.connectionKeepsInput()
        guard isLive else {
            if lifecycle == .opening { lifecycle = .closed }
            return
        }
        suspend()
        resume()
    }

    private func stop(_ owner: (any EngineConnectionOwner)?) async {
        await owner?.connectionWritesInput()
        if let engine {
            // None before the engine's first document (after the sync): its empty editor would hide the page.
            if let liveOwner = owner?.dependencies.liveOwner, let latest = await engine.currentDocument() {
                LiveDocuments.store(latest, for: page.id, owner: liveOwner)
            }
            await engine.close()
        }
    }
}
