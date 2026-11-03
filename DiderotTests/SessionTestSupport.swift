import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

/// What the session race tests share (`AppSessionRaceTests`): two servers, a store of sign-ins per test, and sessions
/// signed in to them that `StubURLProtocol` answers.
protocol SessionStubbing {
    /// The test's sign-ins.
    var store: SessionStore { get }
}

extension SessionStubbing {
    var a: URL { URL(string: "https://a.example.com")! }
    var b: URL { URL(string: "https://b.example.com")! }

    func keptCells(_ session: AppSession) async throws -> [UnsentCell] {
        let store = try #require(session.ready?.unsentChanges)
        return Array((try await store.read([String: UnsentCell].self, key: CacheKey.unsentCells) ?? [:]).values)
    }

    /// A database on a with a Business license, editable, its table showing row r1 (no cells).
    func editableBase() async throws -> (BaseModel, AppSession) {
        _ = try await sessionOnA()
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
        let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
        await session.restore()
        let pageId = "base-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "base.view.\(pageId)")
        let model = BaseModel(pageId: pageId, session: session)
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "p1", "name": "Text", "type": "text"}, {"id": "p2", "name": "Notiz", "type": "text"}], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}]}}"#
        }
        await model.load()
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        StubURLProtocol.body.withLock { $0 = nil }
        return (model, session)
    }

    static func rows(_ id: String) -> String {
        #"{"data": {"items": [{"id": "\#(id)", "cells": {}}], "meta": {"hasNextPage": false}}}"#
    }

    static func results(_ id: String) -> String {
        #"{"data": {"items": [{"id": "\#(id)"}]}}"#
    }

    /// Signed in to a, with b saved as well.
    func sessionOnA() async throws -> AppSession {
        try store.save(StoredSession(serverURL: b, token: "b"))
        try store.save(StoredSession(serverURL: a, token: "a"))
        let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
        await session.restore()
        try #require(session.ready?.server.url == a)
        return session
    }

    /// Signed in to a with a Business license; an editable database with two boards by "s" (no choices, so only the
    /// "No value" column), the first one showing r1.
    func boardsOnA() async throws -> (AppSession, BaseModel) {
        let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
        await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
        let session = try await sessionOnA()
        let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
        // The rows request gets the base as its answer too, so the rows load again below.
        StubURLProtocol.body.withLock {
            $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "kanban", "position": "a", "config": {"groupByPropertyId": "s"}}, {"id": "v2", "name": "B", "type": "kanban", "position": "b", "config": {"groupByPropertyId": "s"}}]}}"#
        }
        await model.load()
        StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
        await model.loadRows()
        try #require(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]])
        return (session, model)
    }

    /// A start with a's sign-in saved, a out of reach and nothing of a saved to show: the sign-in screen, unchecked.
    /// `change`: to the session's environment.
    func uncheckedStartOnA(_ change: (inout SessionEnvironment) -> Void = { _ in }) async throws -> AppSession {
        try store.save(StoredSession(serverURL: a, token: "a"))
        await removeCaches()
        StubURLProtocol.offline.withLock { $0 = true }
        var environment = SessionEnvironment(protocolClasses: [StubURLProtocol.self])
        change(&environment)
        let session = AppSession(sessionStore: store, environment: environment)
        await session.restore()
        StubURLProtocol.offline.withLock { $0 = false }
        let signedOut = if case .signedOut(let server) = session.state { server.url == a } else { false }
        try #require(signedOut && session.uncheckedSignIn?.token == "a")
        return session
    }

    /// Signed in to a from the offline cache (a start without network), with b saved as well.
    func offlineSessionOnA() async throws -> AppSession {
        _ = try await sessionOnA()
        StubURLProtocol.offline.withLock { $0 = true }
        let session = AppSession(sessionStore: store, environment: SessionEnvironment(protocolClasses: [StubURLProtocol.self]))
        await session.restore()
        StubURLProtocol.offline.withLock { $0 = false }
        try #require(session.ready?.restoredOffline == true)
        return session
    }

    func removeCaches() async {
        for url in [a, b] { await DiskCache(scope: url.absoluteString).removeAll() }
    }
}


/// `SecretStore` in memory instead of the keychain.
nonisolated final class MemorySecretStore: SecretStore {
    private let storage = Mutex<[String: Data]>([:])
    /// When each item was last saved; tests may set it.
    let modified = Mutex<[String: Date]>([:])

    func save(_ data: Data, account: String) throws {
        storage.withLock { $0[account] = data }
        modified.withLock { $0[account] = .now }
    }

    func load(account: String) throws -> Data? {
        storage.withLock { $0[account] }
    }

    func delete(account: String) throws {
        storage.withLock { _ = $0.removeValue(forKey: account) }
        modified.withLock { _ = $0.removeValue(forKey: account) }
    }

    func modificationDate(account: String) throws -> Date? {
        modified.withLock { $0[account] }
    }
}

/// Answers every request with the same user (or `body`, with `status`) or fails while `offline`; endpoints expecting
/// something else fall back as on errors. `beforeNextAnswer` runs once while the next request waits (slow network).
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let beforeNextAnswer = Mutex<(@Sendable () async -> Void)?>(nil)
    /// Host and path (`a.example.com/api/users/me`) of the request that takes `beforeNextAnswer`; `nil`: the next one.
    /// Taken by any other request (another session's, a background check), the hook delays nothing the test awaits.
    static let beforeNextAnswerFor = Mutex<String?>(nil)
    static let offline = Mutex(false)
    /// How many of the next requests get no answer, as from a server behind a VPN that is off (they wait until cancelled).
    static let unanswered = Mutex(0)
    static let body = Mutex<String?>(nil)
    static let status = Mutex(200)
    /// Host and path of every request, for tests that check where requests went (they empty it first).
    static let requests = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append((request.url?.host ?? "") + (request.url?.path ?? "")) }
        if Self.offline.withLock({ $0 }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if Self.unanswered.withLock({ count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }) { return }
        let target = (request.url?.host ?? "") + (request.url?.path ?? "")
        let isFor = Self.beforeNextAnswerFor.withLock { $0 }.map { $0 == target } ?? true
        let action = isFor ? Self.beforeNextAnswer.withLock { $0.take() } : nil
        Task {
            await action?()
            let body = Self.body.withLock { $0 } ?? #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}}}"#
            let status = Self.status.withLock { $0 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
