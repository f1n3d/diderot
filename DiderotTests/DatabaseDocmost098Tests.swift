import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Databases on Docmost 0.98: a stale cursor starts the list again, form views stay hidden, and the server's version
    /// decides how dates go out.
    @Suite struct DatabasesOnDocmost098: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// Docmost 0.98's answer (from the dev instance) when the row a cursor refers to changed since its page loaded.
        static let staleCursor = #"{"message": "The row cursor is stale. Reload rows and try again.", "code": "BASE_CURSOR_STALE"}"#

        /// "Load more" whose cursor went stale loads the table again from its first page, as the web does: it failed with
        /// the same cursor on every try.
        @Test func staleCursorStartsTheTableAgain() async throws {
            let (model, session) = try await tableWithMore()
            defer { withExtendedLifetime(session) {} }  // the model holds it unowned
            Self.answerRows([(400, Self.staleCursor), (200, Self.rows("r2"))])
            defer { resetStub() }
            StubURLProtocol.requests.withLock { $0 = [] }
            await model.loadMoreTable()
            #expect(rowRequests() == 2, "the cursor's, then the first page's")
            #expect(model.table.rows.map(\.id) == ["r2"] && !model.table.hasMore)
            #expect(model.toast == nil)
            await removeCaches()
        }

        /// A first page that fails too says so and tries no further; the rows shown stay.
        @Test func failedRestartSaysSo() async throws {
            let (model, session) = try await tableWithMore()
            defer { withExtendedLifetime(session) {} }
            StubURLProtocol.status.withLock { $0 = 400 }
            StubURLProtocol.body.withLock { $0 = Self.staleCursor }
            defer { resetStub() }
            StubURLProtocol.requests.withLock { $0 = [] }
            await model.loadMoreTable()
            #expect(rowRequests() == 2)
            #expect(model.table.rows.map(\.id) == ["r1"])
            #expect(model.toast == "The row cursor is stale. Reload rows and try again.")
            await removeCaches()
        }

        /// A board's column whose cursor went stale loads the board again.
        @Test func staleCursorStartsTheBoardAgain() async throws {
            let (session, model) = try await boardsOnA()
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
            StubURLProtocol.body.withLock { $0 = Self.rowsWithMore("r1") }
            await model.loadRows()
            try #require(model.columns.first?.list.hasMore == true)
            Self.answerRows([(400, Self.staleCursor), (200, Self.rows("r2"))])
            defer { resetStub() }
            await model.loadMore(columnId: BaseKanbanColumn.noValueId)
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]])
            #expect(model.toast == nil)
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// Form views (Docmost 0.98) stay hidden, as on the web while forms are in beta; one chosen before falls back to
        /// the first view shown. They showed as a table.
        @Test func formViewsStayHidden() async throws {
            let session = try await sessionOnA()
            let pageId = "base-\(UUID().uuidString)"
            UserDefaults.standard.set("v1", forKey: "base.view.\(pageId)")
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(pageId)") }
            let model = BaseModel(pageId: pageId, session: session)
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "properties": [], "views": [{"id": "v1", "name": "Formular", "type": "form", "position": "a0"}, {"id": "v2", "name": "Tabelle", "type": "table", "position": "a1"}]}}"#
            }
            await model.load()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.views.map(\.id) == ["v2"])
            #expect(model.selectedView?.id == "v2")
            await removeCaches()
        }

        /// The database learns the server's version from the sign-in it was opened with: from Docmost 0.98 its dates go
        /// out as `{start, end?}` (`BaseValue.date`), before as a string; an unknown version counts as older.
        @Test(arguments: zip(["0.98.0", "0.99.1", "0.97.2", nil], [true, true, false, false]))
        func datesFollowTheServersVersion(version: String?, docmost098: Bool) async throws {
            // No version kept from an earlier test: without one named, the last known counts.
            await removeCaches()
            let named = version.map { #", "currentVersion": "\#($0)""# } ?? ""
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"user": {"id": "u1", "email": "u1@example.com"}, "workspace": {"id": "w1", "name": "Docs"}\#(named)}}"#
            }
            let session = try await sessionOnA()
            StubURLProtocol.body.withLock { $0 = nil }
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            #expect(model.hasDocmost098Features == docmost098)
            await removeCaches()
        }

        // MARK: Helpers

        /// `editableBase`'s table with a next page behind the cursor "c".
        private func tableWithMore() async throws -> (BaseModel, AppSession) {
            let (model, session) = try await editableBase()
            StubURLProtocol.body.withLock { $0 = Self.rowsWithMore("r1") }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            try #require(model.table.hasMore && model.table.cursor == "c")
            return (model, session)
        }

        private static func rowsWithMore(_ id: String) -> String {
            #"{"data": {"items": [{"id": "\#(id)", "cells": {}}], "meta": {"hasNextPage": true, "nextCursor": "c"}}}"#
        }

        /// The next rows requests get these answers (status, body), one each in turn.
        nonisolated private static func answerRows(_ answers: [(Int, String)]) {
            guard let (status, body) = answers.first else { return }
            let rest = Array(answers.dropFirst())
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/bases/rows" }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = {
                StubURLProtocol.status.withLock { $0 = status }
                StubURLProtocol.body.withLock { $0 = body }
                // The request after this one.
                answerRows(rest)
            } }
        }

        private func resetStub() {
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = nil }
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
        }

        private func rowRequests() -> Int {
            StubURLProtocol.requests.withLock { $0 }.filter { $0 == "a.example.com/api/bases/rows" }.count
        }
    }
}
