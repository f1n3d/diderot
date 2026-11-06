import Foundation
import Observation
import WebKit
import DocmostKit

/// The editor's document engine: TipTap + Yjs in a WebView in the app, a fake in DocumentModelTests. A native Yjs core
/// could replace the web engine later.
@MainActor
protocol DocumentEngine: AnyObject, Observable {
    var status: EngineStatus { get }
    /// Changes the server hasn't confirmed yet: each one counts until it does, and so does the sync after each connect.
    /// The status stays `synced` on a connection that died without notice, until the engine notices it (after 30 s).
    var unconfirmedChanges: Int { get }
    var participants: [EngineParticipant] { get }
    /// Each document the engine sends: after its first sync, then after changes, its own and others' (`DocumentSchedule`
    /// in Engine/src/schedule.ts). The page took them from its view, which saw none once it was gone (an upload after
    /// leaving), and `currentDocument()` sent one too, which made a closing page editable again.
    var onDocument: (@MainActor (PMNode) -> Void)? { get set }
    /// The engine gave up on the page (see `EngineFailure`); the page stays read-only.
    var onFailure: (@MainActor (EngineFailure) -> Void)? { get set }
    /// The engine ended on its own (iOS ended its web process, e.g. for memory) and is closed; `open` restarts it.
    var onTerminated: (@MainActor () -> Void)? { get set }
    /// After each save of changes the server hasn't confirmed (`saveUnsentChanges`, `close`, a failed engine): nil once
    /// the device keeps them, else why it can't (a full disk). They then live only in the engine, lost if the app ends.
    var onUnsentChangesKept: (@MainActor ((any Error)?) -> Void)? { get set }

    func open(pageId: String) async throws
    /// Keeps changes the server hasn't confirmed (e.g. made offline); the page's next `open` sends them.
    func close() async
    /// Keeps them like `close` while the page stays open: iOS may end the app in the background.
    func saveUnsentChanges() async
    /// The document straight from the engine (not debounced), e.g. for the reader on close; nil before its first sync,
    /// and without an engine. Reading changes nothing: documents reach the page through `onDocument`.
    func currentDocument() async -> PMNode?
    /// With `base`, the text block the edit started from: a collaborator's edit of the block since then stays, unless
    /// it changed the same range (the engine's `rebase`). With `expected`, the block a structural edit was built from:
    /// refused if the block changed since (`unchanged` in Engine/src/guards.ts).
    func replaceBlock(_ target: BlockTarget, with node: PMNode, base: PMNode?, expected: PMNode?) async -> EngineResult
    /// Replaces one block with several (unsync a synced block, merge columns, …); `expected` as above.
    func replaceBlock(_ target: BlockTarget, withNodes nodes: [PMNode], expected: PMNode?) async -> EngineResult
    /// Without a target: at the end of the document, before the footnotes.
    func insertBlock(_ node: PMNode, relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> EngineResult
    func insertBlocks(_ nodes: [PMNode], relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> EngineResult
    /// Inserts blocks before or after `target` (without one, at the end of the page), or puts them in its place
    /// (`expected` as above), and says where the first of them is (`placeBlocks` in Engine/src/engine.ts): the cursor goes
    /// from there. Counted in the page's copy, which lags behind a collaborator's blocks above, it went into another block.
    func placeBlocks(_ nodes: [PMNode], at target: BlockTarget?, position: BlockPlace.Position, expected: PMNode?) async
        -> (result: EngineResult, path: [Int]?)
    func deleteBlock(_ target: BlockTarget) async -> EngineResult
    func moveBlock(_ target: BlockTarget, to destination: BlockTarget, position: BlockInsertPosition) async -> EngineResult
    /// Splits a list, quote or callout after `child`: the children below go into a new one of the same kind right after.
    func splitContainer(after child: BlockTarget) async -> EngineResult
    func setAttributes(_ target: BlockTarget, attributes: [String: JSONValue]) async -> EngineResult
    /// Runs a table command (`TableCommand` in Engine/src/tables.ts) on a cell of the table at `target`, given by its
    /// row and its index in the row. Returns the cell for the cursor afterwards the same way, empty when the table is
    /// gone, nil when the command didn't apply.
    func tableCommand(_ target: BlockTarget, cell: [Int], command: [String: JSONValue]) async -> [Int]?
    /// Refused with nothing to undo or redo.
    func undo() async -> EngineResult
    func redo() async -> EngineResult
    /// Applies the steps together, all or none (`batch` in Engine/src/engine.ts). A compound edit (leaving a list,
    /// joining a block with the one before) used to be separate calls, and a refused last one left the text twice or
    /// the list split, without a word.
    func batch(_ steps: [EngineStep]) async -> EngineResult
    /// For each candidate, whether its blocks can go at `place` as the engine's schema allows (Engine/src/fits.ts); nil
    /// without an engine. The app kept its own copy of these rules, and it drifted: a synced block was offered page
    /// breaks and databases it can't hold.
    func fits(_ place: BlockPlace, candidates: [[PMNode]]) async -> [Bool]?
    /// For each table command, whether `tableCommand` would apply it to the cell, run without changing anything; nil
    /// without an engine or the table.
    func tableCommandsThatApply(_ target: BlockTarget, cell: [Int], commands: [[String: JSONValue]]) async -> [Bool]?
    /// Return in a text block (`enter` in Engine/src/keys.ts): it keeps `node`, its text before the cursor (saved on
    /// `base`), and `after` continues in a new line, where the engine's document has room for it then, in one
    /// transaction. The save and the new line used to be two.
    func enter(_ target: BlockTarget, keeping node: PMNode, after: [PMNode], base: PMNode?) async -> KeyResult
    /// Return after each of several lines at once, text pasted or dictated with line breaks (`enterLinesEdit` in
    /// Engine/src/keys.ts): the block keeps `node`, and each of `lines` goes where Return puts it, in one transaction.
    /// Returns the last line, with the cursor at its start.
    func enterLines(_ target: BlockTarget, keeping node: PMNode, lines: [[PMNode]], base: PMNode?) async -> KeyResult
    /// Backspace at the start of a text block that holds `node` by now, its input made from `base` (`backspace` in
    /// Engine/src/keys.ts): the engine decides and joins with the line as it holds it, a collaborator's words included.
    func backspace(_ target: BlockTarget, holding node: PMNode, base: PMNode?) async -> BackspaceResult
    /// What Backspace at the start of the block does, empty and with text; nil without an engine or the block.
    func backspacePlans(_ target: BlockTarget) async -> BackspacePlans?
    /// Turns the line at `target` into `kind` (a `BlockTemplate`'s raw value, or "syncedBlock") where it is, from the
    /// engine's document then, in one transaction (`convert` in Engine/src/conversions.ts): a list kind in a list item
    /// switches the item's whole list, a heading takes an item's only line out of the list. Returns where the cursor goes.
    func convert(_ target: BlockTarget, to kind: String) async -> KeyResult
    /// What the line at `target` can turn into where it is (the kinds `convert` takes); nil without an engine or the
    /// block.
    func conversions(_ target: BlockTarget) async -> Set<String>?
    /// Sets the count of the columns block at `target` as the web does: new columns are empty, the ones removed go into
    /// the last one kept.
    func setColumnCount(_ target: BlockTarget, count: Int) async -> EngineResult
    /// Unsyncs the synced block's source at `target`: its content stays as normal blocks.
    func unsync(_ target: BlockTarget) async -> EngineResult
    /// Replaces the embed of a synced block (its source page and id) with its content as the server returned it: the
    /// embed at `path`, else the first on the page, as it has no id.
    func replaceReference(at path: [Int], sourcePageId: String, transclusionId: String, with nodes: [PMNode]) async -> EngineResult
    /// Removes the marks of the deleted comment `commentId` from the whole page (`unsetComment` in Engine/src/steps.ts).
    func unsetComment(_ commentId: String) async -> EngineResult
}

extension DocumentEngine {
    func replaceBlock(_ target: BlockTarget, with node: PMNode, base: PMNode? = nil) async -> EngineResult {
        await replaceBlock(target, with: node, base: base, expected: nil)
    }

    func replaceBlock(_ target: BlockTarget, withNodes nodes: [PMNode]) async -> EngineResult {
        await replaceBlock(target, withNodes: nodes, expected: nil)
    }
}

/// What an engine operation came to: applied; refused (the block is gone, the change doesn't fit, or it changed since
/// the app read it); or unavailable, with no engine to take it (its web process ended, it stopped after an error, it is
/// closed). Unavailable is no verdict on the change: the app keeps input for it and sends it again once the engine is
/// back. Both used to be `false`, and input for a block no longer edited was dropped as refused.
enum EngineResult: Equatable {
    case applied, refused, unavailable

    var isApplied: Bool { self == .applied }
}

enum EngineStatus: Equatable {
    case idle, loading, connecting, connected, synced, disconnected
    case failed(String)
}

enum EngineFailure {
    /// The engine closed the page after syncing: binding the editor would delete content the bundled schema can't hold
    /// (e.g. from a newer Docmost) for everyone.
    case unsupportedContent
    /// The server refused the live connection (no access, page gone); the page used to stay at "Connecting…".
    case connectionRefused
    /// The server takes no more edits from this user (write access lost, page moved or trashed): it ignores them, and the
    /// page used to stay editable and show "Saved".
    case readOnly
    /// The engine hit an error once loaded and takes no more edits (`fail` in Engine/src/engine.ts): its editor and the
    /// page's shared document may no longer match. It is closed by then, with what the server hadn't confirmed kept.
    case engineError
}

struct EngineParticipant: Identifiable, Hashable, Decodable {
    let id: String
    let name: String?
    let avatarUrl: String?

    /// Each user once (devices, windows, web tabs), the signed-in user not at all. Web entries carry only a name: they
    /// count as that user unless an app entry already shows them.
    static func merge(_ entries: [EngineEvent.Participants.Entry], myId: String?, myName: String?) -> [EngineParticipant] {
        var ids = Set([myId].compactMap { $0 })
        var names = Set([myName].compactMap { $0 })
        var result: [EngineParticipant] = []
        for entry in entries {
            guard let id = entry.id, ids.insert(id).inserted else { continue }
            result.append(EngineParticipant(id: id, name: entry.name, avatarUrl: entry.avatarUrl))
            if let name = entry.name { names.insert(name) }
        }
        for entry in entries where entry.id == nil {
            guard let name = entry.name, names.insert(name).inserted else { continue }
            result.append(EngineParticipant(id: "web:" + name, name: name, avatarUrl: nil))
        }
        return result
    }
}

/// A block by UniqueID or by path (child indices from the root).
enum BlockTarget: Hashable, Sendable {
    /// `path`: where the app saw the block. Blocks that share an id (a synced block unsynced on the web keeps its
    /// source's) are told apart by it; the engine refuses one it can't tell (`locate` in Engine/src/steps.ts). Not part
    /// of the target's identity.
    case id(String, path: [Int]? = nil)
    /// `type`: the expected block type; another kind there by now (moved in by a collaborator) fails the operation.
    case path([Int], type: String? = nil)

    var jsObject: [String: Any] {
        switch self {
        case .id(let id, nil): ["id": id]
        case .id(let id, let path?): ["id": id, "path": path]
        case .path(let path, nil): ["path": path]
        case .path(let path, let type?): ["path": path, "type": type]
        }
    }

    static func == (lhs: BlockTarget, rhs: BlockTarget) -> Bool {
        switch (lhs, rhs) {
        case (.id(let left, _), .id(let right, _)): left == right
        case (.path(let left, let leftType), .path(let right, let rightType)): left == right && leftType == rightType
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .id(let id, _):
            hasher.combine(0)
            hasher.combine(id)
        case .path(let path, let type):
            hasher.combine(1)
            hasher.combine(path)
            hasher.combine(type)
        }
    }
}

enum BlockInsertPosition: String {
    case before, after
}

/// Where blocks would go (`Place` in Engine/src/fits.ts): in place of the block at `target`, or before or after it;
/// without a target, at the end of the page, before the footnotes.
struct BlockPlace: Hashable, Sendable {
    enum Position: String, Sendable {
        case replace, before, after
    }

    var target: BlockTarget?
    var position: Position

    var jsObject: [String: Any] {
        ["target": target?.jsObject ?? NSNull(), "position": position.rawValue]
    }
}

/// Where Return or Backspace leaves the cursor (`Cursor` in Engine/src/keys.ts): in the text block at `path`, `offset`
/// into its content as the engine counts (a character of text per UTF-16 unit, an inline node 1).
struct EngineCursor: Equatable, Sendable, Decodable {
    var path: [Int]
    var offset: Int
}

/// What Return or a conversion came to: where the cursor goes; refused or unavailable as `EngineResult`.
enum KeyResult: Equatable {
    case moved(EngineCursor)
    case refused, unavailable
}

/// What Backspace at a block's start does (`BackspacePlan` in Engine/src/keys.ts): joins it with the text block at a
/// path, removes it (an empty line after an image, a table …), leaves the list (an empty first item), or nothing.
enum BackspacePlan: Equatable, Sendable, Decodable {
    case join([Int])
    case remove, leave, nothing

    private enum CodingKeys: String, CodingKey {
        case kind, path
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "join": self = .join(try container.decode([Int].self, forKey: .path))
        case "remove": self = .remove
        case "leave": self = .leave
        default: self = .nothing
        }
    }
}

/// What Backspace at a block's start does when it's empty, and when it holds text.
struct BackspacePlans: Equatable, Sendable, Decodable {
    var empty: BackspacePlan
    var text: BackspacePlan
}

/// What Backspace came to: what it did, with the cursor (none after a removal, or when it did nothing); refused or
/// unavailable as `EngineResult`.
enum BackspaceResult: Equatable {
    case done(BackspacePlan, cursor: EngineCursor?)
    case refused, unavailable
}

/// A step of `batch` (`Step` in Engine/src/steps.ts). Each finds its block where the steps before it left it, so later
/// steps give paths in that document. `base` and `expected` as for `replaceBlock`.
enum EngineStep: Equatable {
    case replace(BlockTarget, with: PMNode, base: PMNode?)
    case insert([PMNode], relativeTo: BlockTarget?, position: BlockInsertPosition)
    case delete(BlockTarget, expected: PMNode?)
    /// Splits a list, quote or callout after `child`, as `splitContainer(after:)`.
    case split(after: BlockTarget)
}

/// Bundled TipTap/Yjs editor (`Engine/`) in a hidden `WebPage`, connected to the collab server; mirrors the document.
@MainActor
@Observable
final class WebDocumentEngine: DocumentEngine {
    private(set) var status: EngineStatus = .idle
    private(set) var unconfirmedChanges = 0
    private(set) var participants: [EngineParticipant] = []
    @ObservationIgnored var onDocument: (@MainActor (PMNode) -> Void)?
    @ObservationIgnored var onFailure: (@MainActor (EngineFailure) -> Void)?
    @ObservationIgnored var onTerminated: (@MainActor () -> Void)?
    @ObservationIgnored var onUnsentChangesKept: (@MainActor ((any Error)?) -> Void)?

    private let session: AppSession
    private var page: WebPage?
    /// Watches for the open page's web process ending; stops with the page.
    private var processWatch: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    /// Bumped by open and close so an earlier open's ready timeout and late events leave a reopened page alone.
    private var opens = 0
    /// Where `close` keeps the open page's unsent changes (`UnsentChanges`).
    private var unsentStore: (store: UnsentStore, pageId: String)?

    init(session: AppSession) {
        self.session = session
    }

    /// A fresh collab token for a page opened with `owner`; none once a switch or sign-out replaced that session: another
    /// server's token would go to this page's socket.
    static func collabToken(session: AppSession, owner: ReadySession) async -> String? {
        try? await session.send(Endpoints.Auth.collabToken, on: owner).token
    }

    /// Dropped without `close` (its page view went away first): the page would stay connected, and show the user as
    /// present, until the app quits.
    isolated deinit {
        processWatch?.cancel()
        if let page { Task { _ = try? await page.callJavaScript("window.DocmostEngine.close();") } }
    }

    func open(pageId: String) async throws {
        guard let ready = session.ready else { throw APIError.unauthorized(message: nil) }
        unload()
        opens += 1
        let attempt = opens
        status = .loading

        let token = try await session.send(Endpoints.Auth.collabToken).token
        let unsentStore = (store: ready.unsentChanges, pageId: pageId)
        var unsent: Data?
        do {
            unsent = try await unsentStore.store.readData(key: CacheKey.unsentChanges(pageId))
        } catch {
            AppLog.ui.error("Unsent changes unreadable: \(error.localizedDescription, privacy: .public)")
        }
        if unsent == nil, let legacy = await ready.cache.readData(key: CacheKey.unsentChanges(pageId)) {
            // Kept in the offline cache by earlier builds; they leave it once the store has them.
            do {
                try await unsentStore.store.writeData(legacy, key: CacheKey.unsentChanges(pageId))
                await ready.cache.remove(key: CacheKey.unsentChanges(pageId))
            } catch {
                AppLog.ui.error("Unsent changes left in the cache: \(error.localizedDescription, privacy: .public)")
            }
            unsent = legacy
        }
        guard opens == attempt else { return }
        // In-flight events of a closed page would overwrite the idle state after `close`, or the next open's.
        let handler = EngineMessageHandler { [weak self] message in
            guard let self, self.page != nil, self.opens == attempt else { return }
            self.handle(message)
        }
        let page = WebViews.engine(server: ready.server.url) { configuration in
            configuration.userContentController.add(handler, name: "engine")
            configuration.userContentController.addScriptMessageHandler(CollabTokenHandler { [session] in
                await Self.collabToken(session: session, owner: ready)
            }, contentWorld: .page, name: "collabToken")
        }
        self.page = page
        self.unsentStore = unsentStore
        processWatch = Task { [weak self] in
            do {
                for try await _ in page.navigations {}
            } catch WebPage.NavigationError.webContentProcessTerminated {
                // Unconfirmed changes went with the engine; `close` can't keep them now.
                guard let self, self.page === page else { return }
                AppLog.ui.error("Engine web process ended")
                self.unload()
                self.onTerminated?()
            } catch {}
        }

        // With the server as base URL, the collab WebSocket is same-origin.
        page.load(html: Self.html(), baseURL: ready.server.url)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyContinuation = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    if let self, self.opens == attempt, let pending = self.readyContinuation {
                        self.readyContinuation = nil
                        pending.resume(throwing: APIError.server(status: 0, message: String(localized: "The editor engine did not start.")))
                    }
                }
            }
        } catch {
            status = .failed(error.userMessage)
            throw error
        }
        guard opens == attempt else { return }

        status = .connecting
        let user = ready.currentUser.user
        let options: [String: Any] = [
            "wsUrl": Self.collabURL(for: ready.server.url).absoluteString,
            "pageId": pageId,
            "token": token,
            "user": ["id": user.id, "name": user.displayName, "avatarUrl": user.avatarUrl ?? "", "color": "#0a84ff"],
            "unsent": unsent?.base64EncodedString() ?? "",
        ]
        do {
            _ = try await page.callJavaScript("window.DocmostEngine.open(options);", arguments: ["options": options])
        } catch {
            status = .failed(error.localizedDescription)
            AppLog.ui.error("Engine open failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.server(status: 0, message: error.localizedDescription)
        }
    }

    func close() async {
        // A pending `open` returns at its next check; connecting anyway would show the user on a page nobody sees.
        opens += 1
        readyContinuation?.resume()
        readyContinuation = nil
        await saveUnsentChanges()
        unload()
    }

    /// Kept until the server confirms them; no answer (engine closed itself or failed) keeps what's stored. The
    /// document only after the first sync (`currentDocument`): until then the stored one still fits. Whether the changes
    /// were kept goes to `onUnsentChangesKept`: a failed write left them only in the engine, and said so only in the log.
    func saveUnsentChanges() async {
        guard let page, let unsentStore,
              let unsent = try? await page.callJavaScript("return window.DocmostEngine.unsentChanges();") as? String
        else { return }
        let (store, pageId) = unsentStore
        // All confirmed: what is stored is in the server's document already, and sent again it changes nothing (Yjs).
        guard !unsent.isEmpty else {
            do {
                try await store.remove(key: CacheKey.unsentChanges(pageId))
                try await store.remove(key: CacheKey.unsentDocument(pageId))
            } catch {
                AppLog.ui.error("Confirmed changes not dropped: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard let data = Data(base64Encoded: unsent) else { return }
        do {
            try await store.writeData(data, key: CacheKey.unsentChanges(pageId))
        } catch {
            AppLog.ui.error("Unsent changes not kept: \(error.localizedDescription, privacy: .public)")
            onUnsentChangesKept?(error)
            return
        }
        onUnsentChangesKept?(nil)
        // Only what the page shows offline until it connects again; the changes themselves are kept above.
        if let current = await currentDocument() {
            do {
                try await store.write(current, key: CacheKey.unsentDocument(pageId))
            } catch {
                AppLog.ui.error("Document of unsent changes not kept: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func unload() {
        if let page {
            Task { _ = try? await page.callJavaScript("window.DocmostEngine.close();") }
        }
        processWatch?.cancel()
        page = nil
        status = .idle
        unconfirmedChanges = 0
        participants = []
    }

    func replaceBlock(_ target: BlockTarget, with node: PMNode, base: PMNode?, expected: PMNode?) async -> EngineResult {
        await call("return window.DocmostEngine.replaceBlockWith(target, json, base, expected);",
                   ["target": target.jsObject, "json": [Self.jsObject(node)], "base": base.map { Self.jsObject($0) } ?? NSNull(),
                    "expected": expected.map { Self.jsObject($0) } ?? NSNull()])
    }

    func replaceBlock(_ target: BlockTarget, withNodes nodes: [PMNode], expected: PMNode?) async -> EngineResult {
        await call("return window.DocmostEngine.replaceBlockWith(target, json, null, expected);",
                   ["target": target.jsObject, "json": nodes.map(Self.jsObject), "expected": expected.map { Self.jsObject($0) } ?? NSNull()])
    }

    func insertBlock(_ node: PMNode, relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> EngineResult {
        await insertBlocks([node], relativeTo: target, position: position)
    }

    func insertBlocks(_ nodes: [PMNode], relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> EngineResult {
        await call("return window.DocmostEngine.insertBlocks(target, json, position);",
                   ["target": target?.jsObject ?? NSNull(), "json": nodes.map(Self.jsObject), "position": position.rawValue])
    }

    func placeBlocks(_ nodes: [PMNode], at target: BlockTarget?, position: BlockPlace.Position, expected: PMNode?) async
        -> (result: EngineResult, path: [Int]?) {
        guard let page else { return (.unavailable, nil) }
        do {
            let answer = try await page.callJavaScript("return window.DocmostEngine.placeBlocks(target, json, position, expected);", arguments: [
                "target": target?.jsObject ?? NSNull(), "json": nodes.map(Self.jsObject), "position": position.rawValue,
                "expected": expected.map { Self.jsObject($0) } ?? NSNull(),
            ])
            if let path = answer as? [Int] { return (.applied, path) }
            return (answer as? Bool == false ? .refused : .unavailable, nil)
        } catch {
            AppLog.ui.error("Engine call failed: \(error.localizedDescription, privacy: .public)")
            return (.unavailable, nil)
        }
    }

    func deleteBlock(_ target: BlockTarget) async -> EngineResult {
        await call("return window.DocmostEngine.deleteBlock(target);", ["target": target.jsObject])
    }

    func splitContainer(after child: BlockTarget) async -> EngineResult {
        await call("return window.DocmostEngine.splitContainer(target);", ["target": child.jsObject])
    }

    func moveBlock(_ target: BlockTarget, to destination: BlockTarget, position: BlockInsertPosition) async -> EngineResult {
        await call("return window.DocmostEngine.moveBlock(target, destination, position);",
                   ["target": target.jsObject, "destination": destination.jsObject, "position": position.rawValue])
    }

    func setAttributes(_ target: BlockTarget, attributes: [String: JSONValue]) async -> EngineResult {
        await call("return window.DocmostEngine.setAttributes(target, attrs);",
                   ["target": target.jsObject, "attrs": Self.jsObject(attributes)])
    }

    func tableCommand(_ target: BlockTarget, cell: [Int], command: [String: JSONValue]) async -> [Int]? {
        guard let page else { return nil }
        do {
            let result = try await page.callJavaScript("return window.DocmostEngine.tableCommand(target, cell, command) ?? null;",
                                                       arguments: ["target": target.jsObject, "cell": cell, "command": Self.jsObject(command)])
            return (result as? [NSNumber])?.map(\.intValue)
        } catch {
            AppLog.ui.error("Engine call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func fits(_ place: BlockPlace, candidates: [[PMNode]]) async -> [Bool]? {
        await answers("return window.DocmostEngine.fits(place, candidates);",
                      ["place": place.jsObject, "candidates": candidates.map { $0.map(Self.jsObject) }])
    }

    func tableCommandsThatApply(_ target: BlockTarget, cell: [Int], commands: [[String: JSONValue]]) async -> [Bool]? {
        await answers("return window.DocmostEngine.tableCommandsThatApply(target, cell, commands);",
                      ["target": target.jsObject, "cell": cell, "commands": commands.map(Self.jsObject)])
    }

    func enter(_ target: BlockTarget, keeping node: PMNode, after: [PMNode], base: PMNode?) async -> KeyResult {
        let result: KeyAnswer<EngineCursor> = await key("return JSON.stringify(window.DocmostEngine.enter(target, json, after, base));",
                                                        ["target": target.jsObject, "json": Self.jsObject(node), "after": after.map(Self.jsObject),
                                                         "base": base.map { Self.jsObject($0) } ?? NSNull()])
        return Self.moved(result)
    }

    func enterLines(_ target: BlockTarget, keeping node: PMNode, lines: [[PMNode]], base: PMNode?) async -> KeyResult {
        let result: KeyAnswer<EngineCursor> = await key("return JSON.stringify(window.DocmostEngine.enterLines(target, json, lines, base));",
                                                        ["target": target.jsObject, "json": Self.jsObject(node),
                                                         "lines": lines.map { $0.map(Self.jsObject) },
                                                         "base": base.map { Self.jsObject($0) } ?? NSNull()])
        return Self.moved(result)
    }

    func backspace(_ target: BlockTarget, holding node: PMNode, base: PMNode?) async -> BackspaceResult {
        struct Outcome: Decodable {
            var kind: String
            var cursor: EngineCursor?
        }
        let result: KeyAnswer<Outcome> = await key("return JSON.stringify(window.DocmostEngine.backspace(target, json, base));",
                                                   ["target": target.jsObject, "json": Self.jsObject(node),
                                                    "base": base.map { Self.jsObject($0) } ?? NSNull()])
        switch result {
        case .value(let outcome):
            let plan: BackspacePlan = switch outcome.kind {
            case "join": .join(outcome.cursor?.path ?? [])
            case "remove": .remove
            case "leave": .leave
            default: .nothing
            }
            return .done(plan, cursor: outcome.cursor)
        case .refused: return .refused
        case .unavailable: return .unavailable
        }
    }

    func backspacePlans(_ target: BlockTarget) async -> BackspacePlans? {
        let result: KeyAnswer<BackspacePlans> = await key("return JSON.stringify(window.DocmostEngine.backspacePlans(target));",
                                                          ["target": target.jsObject])
        if case .value(let plans) = result { return plans }
        return nil
    }

    func convert(_ target: BlockTarget, to kind: String) async -> KeyResult {
        let result: KeyAnswer<EngineCursor> = await key("return JSON.stringify(window.DocmostEngine.convert(target, kind));",
                                                        ["target": target.jsObject, "kind": kind])
        return Self.moved(result)
    }

    func conversions(_ target: BlockTarget) async -> Set<String>? {
        let result: KeyAnswer<[String]> = await key("return JSON.stringify(window.DocmostEngine.conversions(target));",
                                                    ["target": target.jsObject])
        if case .value(let kinds) = result { return Set(kinds) }
        return nil
    }

    func setColumnCount(_ target: BlockTarget, count: Int) async -> EngineResult {
        await call("return window.DocmostEngine.setColumnCount(target, count);", ["target": target.jsObject, "count": count])
    }

    func unsync(_ target: BlockTarget) async -> EngineResult {
        await call("return window.DocmostEngine.unsync(target);", ["target": target.jsObject])
    }

    func unsetComment(_ commentId: String) async -> EngineResult {
        await call("return window.DocmostEngine.unsetComment(commentId);", ["commentId": commentId])
    }

    func replaceReference(at path: [Int], sourcePageId: String, transclusionId: String, with nodes: [PMNode]) async -> EngineResult {
        await call("return window.DocmostEngine.replaceReference(path, source, json);",
                   ["path": path, "source": ["sourcePageId": sourcePageId, "transclusionId": transclusionId], "json": nodes.map(Self.jsObject)])
    }

    func undo() async -> EngineResult { await call("return window.DocmostEngine.undo();", [:]) }
    func redo() async -> EngineResult { await call("return window.DocmostEngine.redo();", [:]) }

    func batch(_ steps: [EngineStep]) async -> EngineResult {
        await call("return window.DocmostEngine.batch(steps);", ["steps": steps.map(Self.stepObject)])
    }

    func currentDocument() async -> PMNode? {
        guard let page,
              let result = try? await page.callJavaScript("return JSON.stringify(window.DocmostEngine.currentDocument());") as? String
        else { return nil }
        return try? JSONDecoder().decode(PMNode.self, from: Data(result.utf8))
    }

    // MARK: - Internal

    /// A question's answers, one per item asked about; nil when the engine takes no edits, has no page, or the call
    /// throws.
    private func answers(_ script: String, _ arguments: [String: Any]) async -> [Bool]? {
        guard let page else { return nil }
        do {
            return try await page.callJavaScript(script, arguments: arguments) as? [Bool]
        } catch {
            AppLog.ui.error("Engine call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A key's answer: a value, refused or unavailable.
    private enum KeyAnswer<Value> {
        case value(Value)
        case refused, unavailable
    }

    private static func moved(_ answer: KeyAnswer<EngineCursor>) -> KeyResult {
        switch answer {
        case .value(let cursor): .moved(cursor)
        case .refused: .refused
        case .unavailable: .unavailable
        }
    }

    /// The engine answers a key with JSON: its value, false (refused) or null (it takes no edits); no page, or a call
    /// that throws (its web process ended), is unavailable too.
    private func key<Value: Decodable>(_ script: String, _ arguments: [String: Any]) async -> KeyAnswer<Value> {
        guard let page else { return .unavailable }
        do {
            guard let json = try await page.callJavaScript(script, arguments: arguments) as? String else { return .unavailable }
            if json == "false" { return .refused }
            guard let value = try? JSONDecoder().decode(Value.self, from: Data(json.utf8)) else { return .unavailable }
            return .value(value)
        } catch {
            AppLog.ui.error("Engine call failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    /// The engine answers true (applied), false (refused) or null (it takes no edits); no page, or a call that throws
    /// (its web process ended), is unavailable too.
    private func call(_ script: String, _ arguments: [String: Any]) async -> EngineResult {
        guard let page else { return .unavailable }
        do {
            let result = try await page.callJavaScript(script, arguments: arguments)
            guard let applied = result as? Bool else { return .unavailable }
            return applied ? .applied : .refused
        } catch {
            AppLog.ui.error("Engine call failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    private func handle(_ message: String) {
        guard let event = try? JSONDecoder().decode(EngineEvent.self, from: Data(message.utf8)) else { return }
        #if DEBUG
        // Not the document (large) nor the presence list (collaborators' names and avatars).
        if event.type != "document", event.type != "awareness" {
            AppLog.ui.notice("Engine event \(message, privacy: .public)")
        }
        #endif
        switch event.type {
        case "ready":
            readyContinuation?.resume()
            readyContinuation = nil
        case "status":
            switch event.status {
            case "connected": if status != .synced { status = .connected }
            case "connecting": status = .connecting
            case "disconnected": status = .disconnected
            default: break
            }
        case "synced":
            if event.synced == true { status = .synced }
        case "document":
            if let document = event.document { onDocument?(document) }
        case "unconfirmed":
            unconfirmedChanges = event.count ?? 0
        case "awareness":
            // The engine omits its own client.
            let me = session.ready?.currentUser.user
            participants = EngineParticipant.merge(event.participants?.list ?? [], myId: me?.id, myName: me?.displayName)
        case "error":
            // Private: the error can quote page text (ProseMirror's "Invalid content for node …"), and logs can be exported.
            AppLog.ui.error("Engine error: \(event.error ?? "?", privacy: .private)")
            if case .loading = status, let pending = readyContinuation {
                readyContinuation = nil
                pending.resume(throwing: APIError.server(status: 0, message: event.error))
            }
        // Closed as leaving the page closes it, so what the server hasn't confirmed is kept; until the page opens it again,
        // calls fail at once, as after a web process that ended.
        case "failed":
            AppLog.ui.error("Engine failed: \(event.error ?? "?", privacy: .public)")
            let attempt = opens
            Task {
                await saveUnsentChanges()
                guard opens == attempt else { return }
                unload()
                onFailure?(.engineError)
            }
        case "unsupported":
            AppLog.ui.error("Engine closed the page: \(event.error ?? "?", privacy: .public)")
            status = .failed(event.error ?? "")
            participants = []
            onFailure?(.unsupportedContent)
        case "authenticationFailed":
            AppLog.ui.error("Live connection refused: \(event.error ?? "?", privacy: .public)")
            status = .failed(event.error ?? "")
            participants = []
            onFailure?(.connectionRefused)
        // The connection stays and shows others' edits; the server ignores this user's from now on.
        case "authenticated":
            if event.scope == "readonly" { onFailure?(.readOnly) }
        case "permissions":
            if event.access != "write" { onFailure?(.readOnly) }
        case "closed":
            if status != .idle { status = .disconnected }
        default:
            break
        }
    }

    private static func collabURL(for server: URL) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.scheme = server.scheme == "https" ? "wss" : "ws"
        components.path = "/collab"
        return components.url!
    }

    private static func html() -> String {
        let script = (Bundle.main.url(forResource: "engine", withExtension: "js")).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"></head><body><script>\(script)</script></body></html>
        """
    }

    private static func jsObject(_ value: some Encodable) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
    }

    private static func stepObject(_ step: EngineStep) -> [String: Any] {
        switch step {
        case .replace(let target, let node, let base):
            ["op": "replace", "target": target.jsObject, "json": [jsObject(node)], "base": base.map { jsObject($0) } ?? NSNull()]
        case .insert(let nodes, let target, let position):
            ["op": "insert", "target": target?.jsObject ?? NSNull(), "json": nodes.map(jsObject), "position": position.rawValue]
        case .delete(let target, let expected):
            ["op": "delete", "target": target.jsObject, "expected": expected.map { jsObject($0) } ?? NSNull()]
        case .split(let child):
            ["op": "split", "target": child.jsObject]
        }
    }
}

/// An event the engine posts (`emit` in Engine/src/engine.ts); each type fills only its own fields.
struct EngineEvent: Decodable {
    let type: String
    let status: String?
    let synced: Bool?
    /// "unconfirmed": changes the server hasn't confirmed.
    let count: Int?
    let error: String?
    let document: PMNode?
    let participants: Participants?
    /// "authenticated": "read-write" or "readonly".
    let scope: String?
    /// "permissions" (Docmost 0.97's `page.permissions`): "write", "read" or "none".
    let access: String?

    /// Read one by one: the web client's entries have only `name` and `color`, no user id, and an entry that doesn't
    /// read (a number for a name) is left out; it emptied the whole list.
    struct Participants: Decodable {
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let avatarUrl: String?
        }
        let list: [Entry]
        init(from decoder: any Decoder) throws {
            var list: [Entry] = []
            if var entries = try? decoder.unkeyedContainer() {
                while !entries.isAtEnd {
                    if let entry = try? entries.decode(Entry.self) {
                        list.append(entry)
                    } else if (try? entries.decode(JSONValue.self)) == nil {
                        break  // A failed entry isn't passed; this one couldn't be passed either.
                    }
                }
            }
            self.list = list
        }
    }
}

/// Receives `webkit.messageHandlers.engine.postMessage(JSON)` and forwards the JSON text.
final class EngineMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (String) -> Void

    init(onMessage: @escaping @MainActor (String) -> Void) {
        self.onMessage = onMessage
    }

    /// Already on the main actor (`WK_SWIFT_UI_ACTOR`); still forwards via a new main-actor task to keep event order.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the engine page posts (`WebNavigationLimit` keeps frames out; this check stays as a second line).
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        let callback = onMessage
        Task { @MainActor in callback(text) }
    }
}

/// Answers the engine's `collabToken` requests (its `postMessage` returns a promise): a fresh token, or nil on failure.
final class CollabTokenHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let fetch: @MainActor () async -> String?

    init(fetch: @escaping @MainActor () async -> String?) {
        self.fetch = fetch
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        // Frames must not get a token (`WebNavigationLimit` keeps them out; this check stays as a second line).
        guard message.frameInfo.isMainFrame else { return (nil, nil) }
        return (await fetch(), nil)
    }
}
