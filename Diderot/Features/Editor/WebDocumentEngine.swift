import Foundation
import Observation
import WebKit
import DocmostKit

/// The editor's document engine: TipTap + Yjs in a WebView in the app, a fake in DocumentModelTests. A native Yjs core
/// could replace the web engine later.
@MainActor
protocol DocumentEngine: AnyObject, Observable {
    var status: EngineStatus { get }
    var document: PMNode? { get }
    var participants: [EngineParticipant] { get }
    /// The engine gave up on the page (see `EngineFailure`); the page stays read-only.
    var onFailure: (@MainActor (EngineFailure) -> Void)? { get set }
    /// The engine ended on its own (iOS ended its web process, e.g. for memory) and is closed; `open` restarts it.
    var onTerminated: (@MainActor () -> Void)? { get set }

    func open(pageId: String) async throws
    /// Keeps changes the server hasn't confirmed (e.g. made offline); the page's next `open` sends them.
    func close() async
    /// Keeps them like `close` while the page stays open: iOS may end the app in the background.
    func saveUnsentChanges() async
    /// The document straight from the engine (not debounced), e.g. for the reader on close.
    func currentDocument() async -> PMNode?
    func replaceBlock(_ target: BlockTarget, with node: PMNode) async -> Bool
    /// Replaces one block with several (unsync a synced block, merge columns, …).
    func replaceBlock(_ target: BlockTarget, withNodes nodes: [PMNode]) async -> Bool
    /// Without a target: at the end of the document, before the footnotes.
    func insertBlock(_ node: PMNode, relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> Bool
    func insertBlocks(_ nodes: [PMNode], relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> Bool
    func deleteBlock(_ target: BlockTarget) async -> Bool
    func moveBlock(_ target: BlockTarget, to destination: BlockTarget, position: BlockInsertPosition) async -> Bool
    /// Splits a list, quote or callout after `child`: the children below go into a new one of the same kind right after.
    func splitContainer(after child: BlockTarget) async -> Bool
    func setAttributes(_ target: BlockTarget, attributes: [String: JSONValue]) async -> Bool
    func undo() async
    func redo() async
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
    case id(String)
    /// `type`: the expected block type; another kind there by now (moved in by a collaborator) fails the operation.
    case path([Int], type: String? = nil)

    var jsObject: [String: Any] {
        switch self {
        case .id(let id): ["id": id]
        case .path(let path, nil): ["path": path]
        case .path(let path, let type?): ["path": path, "type": type]
        }
    }
}

enum BlockInsertPosition: String {
    case before, after
}

/// Bundled TipTap/Yjs editor (`Engine/`) in a hidden `WebPage`, connected to the collab server; mirrors the document.
@MainActor
@Observable
final class WebDocumentEngine: DocumentEngine {
    private(set) var status: EngineStatus = .idle
    private(set) var document: PMNode?
    private(set) var participants: [EngineParticipant] = []
    @ObservationIgnored var onFailure: (@MainActor (EngineFailure) -> Void)?
    @ObservationIgnored var onTerminated: (@MainActor () -> Void)?

    private let session: AppSession
    private var page: WebPage?
    /// Watches for the open page's web process ending; stops with the page.
    private var processWatch: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    /// Bumped by open and close so an earlier open's ready timeout and late events leave a reopened page alone.
    private var opens = 0
    /// Where `close` keeps the open page's unsent changes (`UnsentChanges`).
    private var unsentStore: (store: DiskCache, pageId: String)?

    init(session: AppSession) {
        self.session = session
    }

    func open(pageId: String) async throws {
        guard let ready = session.ready else { throw APIError.unauthorized(message: nil) }
        unload()
        opens += 1
        let attempt = opens
        status = .loading

        let token = try await session.send(Endpoints.Auth.collabToken).token
        let unsentStore = (store: ready.unsentChanges, pageId: pageId)
        var unsent = await unsentStore.store.readData(key: CacheKey.unsentChanges(pageId))
        if unsent == nil, let legacy = await ready.cache.readData(key: CacheKey.unsentChanges(pageId)) {
            // Kept in the offline cache by earlier builds.
            await unsentStore.store.writeData(legacy, key: CacheKey.unsentChanges(pageId))
            await ready.cache.remove(key: CacheKey.unsentChanges(pageId))
            unsent = legacy
        }
        guard opens == attempt else { return }
        // In-flight events of a closed page would overwrite the idle state after `close`, or the next open's.
        let handler = EngineMessageHandler { [weak self] message in
            guard let self, self.page != nil, self.opens == attempt else { return }
            self.handle(message)
        }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(handler, name: "engine")
        configuration.userContentController.addScriptMessageHandler(CollabTokenHandler { [session] in
            try? await session.send(Endpoints.Auth.collabToken).token
        }, contentWorld: .page, name: "collabToken")
        // Its own page only: no frames either (TipTap renders YouTube embeds as iframes), so nothing else hears of it.
        let page = WebPage(configuration: configuration, navigationDecider: WebNavigationLimit(home: ready.server.url))
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
    /// document only after the first sync: until then the engine's is empty, and the stored one still fits.
    func saveUnsentChanges() async {
        guard let page, let unsentStore,
              let unsent = try? await page.callJavaScript("return window.DocmostEngine.unsentChanges();") as? String
        else { return }
        let (store, pageId) = unsentStore
        if unsent.isEmpty {
            await store.remove(key: CacheKey.unsentChanges(pageId))
            await store.remove(key: CacheKey.unsentDocument(pageId))
        } else if let data = Data(base64Encoded: unsent) {
            await store.writeData(data, key: CacheKey.unsentChanges(pageId))
            if document != nil, let current = await currentDocument() {
                await store.write(current, key: CacheKey.unsentDocument(pageId))
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
        document = nil
        participants = []
    }

    func replaceBlock(_ target: BlockTarget, with node: PMNode) async -> Bool {
        await replaceBlock(target, withNodes: [node])
    }

    func replaceBlock(_ target: BlockTarget, withNodes nodes: [PMNode]) async -> Bool {
        await call("return window.DocmostEngine.replaceBlockWith(target, json);", ["target": target.jsObject, "json": nodes.map(Self.jsObject)])
    }

    func insertBlock(_ node: PMNode, relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> Bool {
        await insertBlocks([node], relativeTo: target, position: position)
    }

    func insertBlocks(_ nodes: [PMNode], relativeTo target: BlockTarget?, position: BlockInsertPosition) async -> Bool {
        await call("return window.DocmostEngine.insertBlocks(target, json, position);",
                   ["target": target?.jsObject ?? NSNull(), "json": nodes.map(Self.jsObject), "position": position.rawValue])
    }

    func deleteBlock(_ target: BlockTarget) async -> Bool {
        await call("return window.DocmostEngine.deleteBlock(target);", ["target": target.jsObject])
    }

    func splitContainer(after child: BlockTarget) async -> Bool {
        await call("return window.DocmostEngine.splitContainer(target);", ["target": child.jsObject])
    }

    func moveBlock(_ target: BlockTarget, to destination: BlockTarget, position: BlockInsertPosition) async -> Bool {
        await call("return window.DocmostEngine.moveBlock(target, destination, position);",
                   ["target": target.jsObject, "destination": destination.jsObject, "position": position.rawValue])
    }

    func setAttributes(_ target: BlockTarget, attributes: [String: JSONValue]) async -> Bool {
        await call("return window.DocmostEngine.setAttributes(target, attrs);",
                   ["target": target.jsObject, "attrs": Self.jsObject(attributes)])
    }

    func undo() async { _ = await call("return window.DocmostEngine.undo();", [:]) }
    func redo() async { _ = await call("return window.DocmostEngine.redo();", [:]) }

    func currentDocument() async -> PMNode? {
        guard let page else { return nil }
        guard let result = try? await page.callJavaScript("return JSON.stringify(window.DocmostEngine.flush());") as? String,
              let node = try? JSONDecoder().decode(PMNode.self, from: Data(result.utf8))
        else { return nil }
        document = node
        return node
    }

    // MARK: - Internal

    private func call(_ script: String, _ arguments: [String: Any]) async -> Bool {
        guard let page else { return false }
        do {
            let result = try await page.callJavaScript(script, arguments: arguments)
            return (result as? Bool) == true
        } catch {
            AppLog.ui.error("Engine call failed: \(error.localizedDescription, privacy: .public)")
            return false
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
            if let document = event.document { self.document = document }
        case "awareness":
            // The engine omits its own client.
            let me = session.ready?.currentUser.user
            participants = EngineParticipant.merge(event.participants?.list ?? [], myId: me?.id, myName: me?.displayName)
        case "error":
            AppLog.ui.error("Engine error: \(event.error ?? "?", privacy: .public)")
            if case .loading = status, let pending = readyContinuation {
                readyContinuation = nil
                pending.resume(throwing: APIError.server(status: 0, message: event.error))
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
}

/// An event the engine posts (`emit` in Engine/src/engine.ts); each type fills only its own fields.
struct EngineEvent: Decodable {
    let type: String
    let status: String?
    let synced: Bool?
    let error: String?
    let document: PMNode?
    let participants: Participants?

    /// Read one by one: the web client's entries have only `name` and `color`, no user id.
    struct Participants: Decodable {
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let avatarUrl: String?
        }
        let list: [Entry]
        init(from decoder: any Decoder) throws { list = (try? [Entry](from: decoder)) ?? [] }
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
