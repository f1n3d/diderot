import Foundation
import Synchronization
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Databases: a late or failed answer keeps the view, the card and its sheet; kept fields go out once the server answers.
    @Suite struct Databases: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        /// A database is read-only offline, as pages are. A save that fails keeps the field's text for the next try: the old
        /// value used to come back, the input gone.
        @Test func failedSaveKeepsTheTypedText() async throws {
            let (model, session) = try await editableBase()
            defer { UnsentChanges.removeAll(server: a) }
            #expect(model.canEdit)
            model.isOffline = true
            #expect(model.readOnlyReason == .offline)
            model.isOffline = false

            StubURLProtocol.status.withLock { $0 = 500 }
            await model.setCell(rowId: "r1", propertyId: "p1", to: .string("neu"), typed: "neu")
            StubURLProtocol.status.withLock { $0 = 200 }
            #expect(model.unsavedDraft(rowId: "r1", propertyId: "p1") == "neu")
            #expect(model.row(id: "r1")?.cells["p1"] == nil, "the row shows what the server has")
            #expect(model.toast == String(localized: "The change goes to the server once it can be reached."))
            #expect(try await keptCells(session).map(\.typed) == ["neu"])

            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"p1": "neu"}}}"# }
            await model.setCell(rowId: "r1", propertyId: "p1", to: .string("neu"), typed: "neu")
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.unsavedDraft(rowId: "r1", propertyId: "p1") == nil)
            #expect(model.row(id: "r1")?.cells["p1"] == .string("neu"))
            #expect(try await keptCells(session).isEmpty, "saved, it no longer waits")
            await removeCaches()
        }

        /// A failed people search throws instead of finding nobody (the picker said "No people found"), and a link to an entry
        /// that can't be loaded says why: it opened nothing without a word.
        @Test func failedDatabaseReadsSaySo() async throws {
            let (model, session) = try await editableBase()
            StubURLProtocol.offline.withLock { $0 = true }
            await #expect(throws: APIError.self) { try await model.suggestPeople("") }
            #expect(await !model.fetchRowIfNeeded("r9"))
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(model.toast != nil)
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// A typed input whose save failed waits on the device, like a page's title: the database opened again (also after
        /// the app ended) shows it, and it goes out with the next try that reaches the server. It used to live only in memory.
        @Test func keptInputGoesOutOnceTheServerAnswers() async throws {
            let (model, session) = try await editableBase()
            defer { UnsentChanges.removeAll(server: a) }
            StubURLProtocol.status.withLock { $0 = 500 }
            await model.setCell(rowId: "r1", propertyId: "p1", to: .string("neu"), typed: "neu")
            StubURLProtocol.status.withLock { $0 = 200 }

            let reopened = BaseModel(pageId: model.pageId, session: session)
            await reopened.load()
            #expect(reopened.unsavedDraft(rowId: "r1", propertyId: "p1") == "neu")

            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"p1": "neu"}}}"# }
            #expect(await session.sendUnsentCells().isEmpty)
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/bases/rows/update"))
            #expect(try await keptCells(session).isEmpty)
            await removeCaches()
        }

        /// A kept input that went to the server while its database stayed open no longer shows once that loads again, and a
        /// field closed with it unchanged doesn't send it again: it overwrote what a colleague had changed since.
        @Test func deliveredKeptInputDoesNotGoAgain() async throws {
            let (model, session) = try await editableBase()
            defer { UnsentChanges.removeAll(server: a) }
            StubURLProtocol.status.withLock { $0 = 500 }
            await model.setCell(rowId: "r1", propertyId: "p1", to: .string("foo"), typed: "foo")
            StubURLProtocol.status.withLock { $0 = 200 }
            let open = BaseModel(pageId: model.pageId, session: session)
            await open.load()
            #expect(open.unsavedDraft(rowId: "r1", propertyId: "p1") == "foo")

            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"p1": "foo"}}}"# }
            #expect(await session.sendUnsentCells().isEmpty)
            StubURLProtocol.requests.withLock { $0 = [] }
            await model.setCell(rowId: "r1", propertyId: "p1", to: .string("foo"), typed: "foo")
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/bases/rows/update"))
            #expect(model.unsavedDraft(rowId: "r1", propertyId: "p1") == nil)

            StubURLProtocol.body.withLock { $0 = nil }
            await open.load()
            #expect(open.unsavedDraft(rowId: "r1", propertyId: "p1") == nil)
            await removeCaches()
        }

        /// A kept input for an entry deleted meanwhile can never go: it is dropped, and named for the notice.
        @Test func keptInputOfAGoneEntryIsDropped() async throws {
            let (model, session) = try await editableBase()
            defer { UnsentChanges.removeAll(server: a) }
            StubURLProtocol.status.withLock { $0 = 500 }
            await model.setCell(rowId: "r1", propertyId: "p1", to: .string("neu"), typed: "neu")

            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Row not found"}"# }
            defer {
                StubURLProtocol.status.withLock { $0 = 200 }
                StubURLProtocol.body.withLock { $0 = nil }
            }
            let dropped = await session.sendUnsentCells()
            #expect(dropped.map(\.name) == ["neu"] && dropped.map(\.reason) == ["Row not found"])
            #expect(try await keptCells(session).isEmpty)
            await removeCaches()
        }

        /// A write queued while a's server didn't answer goes nowhere after a switch to b, with a notice: it used to reach b,
        /// taking a's content there.
        @Test(.timeLimit(.minutes(1))) func queuedWriteAfterASwitchIsDropped() async throws {
            let (model, session) = try await editableBase()
            let other = StoredSession(serverURL: b, token: "b")
            let queued = Mutex<Bool?>(nil)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                // While a's server takes its time, the second change waits in the queue (shown, not yet sent); then the
                // user switches to b.
                queued.withLock { $0 = model.row(id: "r1")?.cells["p2"] == .string("zwei") }
                StubURLProtocol.body.withLock { $0 = nil }  // b's own answers for the switch
                await session.switchTo(other)
                StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"p1": "eins"}}}"# }
            } }
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"p1": "eins"}}}"# }
            // Tasks on the main actor start in order, so the second change queues behind the first before the first's
            // request goes out.
            let first = Task { await model.setCell(rowId: "r1", propertyId: "p1", to: .string("eins")) }
            let second = Task { await model.setCell(rowId: "r1", propertyId: "p2", to: .string("zwei")) }
            await first.value
            await second.value
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(queued.withLock { $0 } == true, "the second change waited in the queue")
            #expect(session.ready?.server.url == b)
            #expect(model.toast == String(localized: "Not saved: the app has switched to another server."))
            await removeCaches()
        }

        /// The user switches to b while a's server reads the options for a new choice: nothing goes to b, where a's option
        /// list used to go, and b's cache gets none of a's database.
        @Test(.timeLimit(.minutes(1))) func choiceAddedDuringASwitchStaysOnItsServer() async throws {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            let base = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}]}}"#
            StubURLProtocol.body.withLock { $0 = base }
            await model.load()
            let other = StoredSession(serverURL: b, token: "b")
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/bases/info" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = nil }  // b's own answers for the switch
                await session.switchTo(other)
                StubURLProtocol.body.withLock { $0 = base }
            } }
            StubURLProtocol.requests.withLock { $0 = [] }
            let choice = await model.addChoice(named: "Neu", to: "s")
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(choice == nil)
            #expect(session.ready?.server.url == b)
            #expect(StubURLProtocol.requests.withLock { $0 }.contains("a.example.com/api/bases/info"), "the options were read")
            #expect(!StubURLProtocol.requests.withLock { $0 }.contains { $0.hasPrefix("b.example.com/api/bases") })
            #expect(model.toast == String(localized: "Not saved: the app has switched to another server."))
            #expect(await DiskCache(scope: b.absoluteString).read(Base.self, key: CacheKey.base(model.pageId)) == nil)
            await removeCaches()
        }

        /// A change a's server confirms after the switch to b leaves b's cache alone: the late answer stored a's rows there.
        @Test(.timeLimit(.minutes(1))) func writeAnsweredAfterASwitchLeavesTheNewCacheAlone() async throws {
            let (model, session) = try await editableBase()
            let other = StoredSession(serverURL: b, token: "b")
            StubURLProtocol.beforeNextAnswerFor.withLock { $0 = "a.example.com/api/bases/rows/update" }
            defer { StubURLProtocol.beforeNextAnswerFor.withLock { $0 = nil } }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = nil }  // b's own answers for the switch
                await session.switchTo(other)
                StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"p1": "eins"}}}"# }
            } }
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"p1": "eins"}}}"# }
            await model.setCell(rowId: "r1", propertyId: "p1", to: .string("eins"))
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(session.ready?.server.url == b)
            let key = CacheKey.baseView(model.pageId, viewId: "v1")
            #expect(await DiskCache(scope: b.absoluteString).read(BaseViewSnapshot.self, key: key) == nil)
            await removeCaches()
        }

        /// An entry opened from a link that the table's loaded rows leave out shows its saved changes, and a second change
        /// builds on the first: the sheet kept the old row, and a second tag replaced the first.
        @Test func linkedEntryOutsideTheTableShowsItsChanges() async throws {
            let (model, session) = try await editableBase()
            defer { withExtendedLifetime(session) {} }  // the model holds it unowned
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r9", "cells": {}}}"# }
            #expect(await model.fetchRowIfNeeded("r9"))
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r9", "cells": {"p1": "neu"}}}"# }
            await model.setCell(rowId: "r9", propertyId: "p1", to: .string("neu"))
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.row(id: "r9")?.cells["p1"] == .string("neu"))
            await removeCaches()
        }

        /// The user switches database views while the first view's rows load, and the second view's rows arrive first.
        @Test func lateRowsAnswerKeepsTheNewView() async throws {
            let session = try await sessionOnA()
            let pageId = "base-\(UUID().uuidString)"
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(pageId)") }
            let model = BaseModel(pageId: pageId, session: session)
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}, {"id": "v2", "name": "B", "type": "table", "position": "b"}]}}"#
            }
            await model.load()
            let second = try #require(model.views.last)
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
                await model.select(second)
                StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            } }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.table.rows.map(\.id) == ["r2"] && !model.isLoadingRows)
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(pageId, viewId: "v2"))
            #expect(snapshot?.table?.rows.map(\.id) == ["r2"], "the second view's offline copy")
            await removeCaches()
        }

        /// Rows that fail to load show the error with "Try Again" instead of "No entries"; saved rows stay with a short
        /// notice (on opening, the page gives it), and a load cancelled by leaving the screen shows none.
        @Test func failedRowsLoadShowsTheError() async throws {
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            // The rows request gets the base as its answer too, which isn't a page of rows.
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "b", "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}]}}"# }
            await model.load()
            #expect(model.rowsError != nil && model.toast == nil)
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            await model.loadRows()
            StubURLProtocol.offline.withLock { $0 = true }
            await model.load()
            let reopened = BaseModel(pageId: model.pageId, session: session)
            await reopened.load()
            StubURLProtocol.offline.withLock { $0 = false }
            #expect(model.table.rows.map(\.id) == ["r1"] && model.rowsError == nil && model.toast != nil)
            #expect(reopened.table.rows.map(\.id) == ["r1"] && reopened.toast == nil, "the page reports it itself")
            model.toast = nil
            let leaving = Task { await model.load() }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { leaving.cancel() } }
            await leaving.value
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.toast == nil)
            await removeCaches()
        }

        /// Reopened during a server error, the saved database shows with a notice (only offline, the page gives it); once
        /// deleted for good or no longer shared (404, 403), it shows the error and drops its saved copy and rows.
        @Test func goneDatabaseDropsItsSavedCopy() async throws {
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "b", "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}]}}"# }
            await model.load()
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            await model.loadRows()
            StubURLProtocol.status.withLock { $0 = 500 }
            let failing = BaseModel(pageId: model.pageId, session: session)
            await failing.load()
            StubURLProtocol.status.withLock { $0 = 404 }
            StubURLProtocol.body.withLock { $0 = #"{"statusCode": 404, "message": "Page not found"}"# }
            let gone = BaseModel(pageId: model.pageId, session: session)
            await gone.load()
            StubURLProtocol.status.withLock { $0 = 200 }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(failing.table.rows.map(\.id) == ["r1"] && failing.toast != nil)
            let shown: APIError? = if case .failed(let error) = gone.state { error as? APIError } else { nil }
            #expect(shown == .notFound(message: "Page not found"))
            let cache = try #require(session.ready?.cache)
            #expect(await cache.read(Base.self, key: CacheKey.base(model.pageId)) == nil)
            #expect(await cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1")) == nil)
            await removeCaches()
        }

        /// The user switches views while "Load More" waits, and the request fails: the view now shown gets no error toast.
        @Test func failedLoadMoreShowsNoToastInTheNewView() async throws {
            let session = try await sessionOnA()
            let pageId = "base-\(UUID().uuidString)"
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(pageId)") }
            let model = BaseModel(pageId: pageId, session: session)
            // A table and a board by "s" (only the "No value" column); the rows request gets the base as its answer too.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}, {"id": "v2", "name": "B", "type": "kanban", "position": "b", "config": {"groupByPropertyId": "s"}}]}}"#
            }
            await model.load()
            let table = try #require(model.views.first), board = try #require(model.views.last)
            let more = #"{"data": {"items": [{"id": "r1", "cells": {}}], "meta": {"hasNextPage": true, "nextCursor": "c"}}}"#
            StubURLProtocol.body.withLock { $0 = more }
            await model.loadRows()
            /// While the next request waits, switches to `view`, whose rows have more; that request then gets the stub's
            /// user, not a page of rows.
            func switchWhileLoadingMore(to view: BaseView) {
                StubURLProtocol.body.withLock { $0 = more }
                StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                    await model.select(view)
                    StubURLProtocol.body.withLock { $0 = nil }
                } }
            }
            switchWhileLoadingMore(to: board)
            await model.loadMoreTable()
            #expect(model.selectedView == board && model.toast == nil, "the table's request")
            switchWhileLoadingMore(to: table)
            await model.loadMore(columnId: BaseKanbanColumn.noValueId)
            #expect(model.selectedView == table && model.toast == nil, "the board's request")
            await removeCaches()
        }

        /// A card set to a status the board hides leaves the board, but its detail sheet keeps showing it and saving edits.
        @Test func cardInHiddenColumnStaysInItsSheet() async throws {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            // Board by "s" that hides "done"; the rows request gets the base as its answer too, so rows load again below.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select", "typeOptions": {"choices": [{"id": "done", "name": "Done"}]}}], "views": [{"id": "v1", "name": "Board", "type": "kanban", "config": {"groupByPropertyId": "s", "hiddenChoiceIds": ["done"]}}]}}"#
            }
            await model.load()
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"s": "done"}}}"# }
            await model.setCell(rowId: "r1", propertyId: "s", to: .string("done"))
            #expect(model.columns.map(\.list.rows.count) == [0], "the card left the board")
            #expect(model.row(id: "r1")?.cells["s"] == .string("done"), "the detail sheet still shows it")
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {}}}"# }
            await model.setCell(rowId: "r1", propertyId: "s", to: nil)
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]], "a further edit saves and brings it back")
            await removeCaches()
        }

        /// The board reloads while the user sets a card to a hidden status, and the reload answers without the card.
        @Test func lateRowsAnswerKeepsTheCardInItsSheet() async throws {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            // Board by "s" that hides "done"; the rows request gets the base as its answer too, so rows load again below.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select", "typeOptions": {"choices": [{"id": "done", "name": "Done"}]}}], "views": [{"id": "v1", "name": "Board", "type": "kanban", "config": {"groupByPropertyId": "s", "hiddenChoiceIds": ["done"]}}]}}"#
            }
            await model.load()
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            await model.loadRows()
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"s": "done"}}}"# }
                await model.setCell(rowId: "r1", propertyId: "s", to: .string("done"))
                StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
            } }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]], "the reload's answer shows")
            #expect(model.row(id: "r1")?.cells["s"] == .string("done"), "the detail sheet still shows the card")
            await removeCaches()
        }

        /// The user edits a card and switches to a board without it before the answer arrives.
        @Test func lateWriteAnswerKeepsTheNewView() async throws {
            let (session, model) = try await boardsOnA()
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
            let second = try #require(model.views.last)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
                await model.select(second)
                StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
            } }
            await model.setCell(rowId: "r1", propertyId: "t", to: .string("x"))
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]])
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
            #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r2"]], "the second view's offline copy")
            await removeCaches()
        }

        /// The user edits a card and switches to a board that shows it too before the answer arrives.
        @Test func lateWriteAnswerUpdatesTheNewView() async throws {
            let (session, model) = try await boardsOnA()
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
            let second = try #require(model.views.last)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
                await model.select(second)
                StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
            } }
            await model.setCell(rowId: "r1", propertyId: "t", to: .string("x"))
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.row(id: "r1")?.cells["t"] == .string("x"))
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
            #expect(snapshot?.columns?.first?.list.rows.first?.cells["t"] == .string("x"), "the second view's offline copy")
            await removeCaches()
        }

        /// The user creates an entry and switches to another board before the answer arrives.
        @Test func lateCreateAnswerKeepsTheNewView() async throws {
            let (session, model) = try await boardsOnA()
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
            let second = try #require(model.views.last)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
                await model.select(second)
                StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r3", "cells": {}}}"# }
            } }
            let created = await model.createRow()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]])
            #expect(created == nil && model.lastCreatedRowId == nil, "no detail sheet opens there")
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
            #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r2"]], "the second view's offline copy")
            await removeCaches()
        }

        /// The user deletes a card and switches to a board without it before the delete fails.
        @Test func failedDeleteKeepsTheNewView() async throws {
            let (session, model) = try await boardsOnA()
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
            let second = try #require(model.views.last)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
                await model.select(second)
                // An empty answer isn't JSON, so the delete fails.
                StubURLProtocol.body.withLock { $0 = "" }
            } }
            await model.deleteRow("r1")
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r2"]] && model.toast != nil)
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v2"))
            #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r2"]], "the second view's offline copy")
            await removeCaches()
        }

        /// A reload the server answered before a delete arrives after it: the deleted card stays gone; it used to come back
        /// until the next reload.
        @Test func reloadAnsweredBeforeTheDeleteKeepsTheCardGone() async throws {
            let (session, model) = try await boardsOnA()
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = #"{"data": {}}"# }
                await model.deleteRow("r1")
                StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            } }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.row(id: "r1") == nil)
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
            #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [[]], "the offline copy")
            await removeCaches()
        }

        /// Table A, then B, then A again (offline, so its saved copy shows) while a delete runs that then fails: the entry
        /// shows once; the saved copy used to bring it back besides the restored one.
        @Test func failedDeleteAfterSwitchingBackShowsTheEntryOnce() async throws {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [], "views": [{"id": "v1", "name": "A", "type": "table", "position": "a"}, {"id": "v2", "name": "B", "type": "table", "position": "b"}]}}"#
            }
            await model.load()
            StubURLProtocol.body.withLock { $0 = Self.rows("r1") }
            await model.loadRows()
            let first = try #require(model.views.first), second = try #require(model.views.last)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = Self.rows("r2") }
                await model.select(second)
                StubURLProtocol.offline.withLock { $0 = true }
                await model.select(first)
                StubURLProtocol.offline.withLock { $0 = false }
                // An empty answer isn't JSON, so the delete fails.
                StubURLProtocol.body.withLock { $0 = "" }
            } }
            await model.deleteRow("r1")
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.table.rows.map(\.id) == ["r1"])
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
            #expect(snapshot?.table?.rows.map(\.id) == ["r1"], "the offline copy")
            await removeCaches()
        }

        /// The user edits a card and deletes it before the edit's answer arrives. A delete that fails brings the card back.
        @Test func lateWriteAnswerKeepsTheCardDeleted() async throws {
            let (session, model) = try await boardsOnA()
            StubURLProtocol.offline.withLock { $0 = true }
            await model.deleteRow("r1")
            StubURLProtocol.offline.withLock { $0 = false }
            try #require(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]], "the failed delete")
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
            // Tasks on the main actor start in order, so the delete queues behind the edit before its request goes out.
            let editing = Task { await model.setCell(rowId: "r1", propertyId: "t", to: .string("x")) }
            await Task { await model.deleteRow("r1") }.value
            await editing.value
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [[]] && model.row(id: "r1") == nil)
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
            #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [[]], "the offline copy")
            await removeCaches()
        }

        /// The user edits a card and deletes it before the edit's answer arrives; the edit saves, but the delete fails.
        @Test func failedDeleteKeepsTheCardInTheOfflineCopy() async throws {
            let (session, model) = try await boardsOnA()
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "r1", "cells": {"t": "x"}}}"# }
            // The edit's answer still arrives; the delete queued behind it then finds no connection.
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { StubURLProtocol.offline.withLock { $0 = true } } }
            let editing = Task { await model.setCell(rowId: "r1", propertyId: "t", to: .string("x")) }
            await Task { await model.deleteRow("r1") }.value
            await editing.value
            StubURLProtocol.offline.withLock { $0 = false }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.columns.map { $0.list.rows.map(\.id) } == [["r1"]])
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: "v1"))
            #expect(snapshot?.columns?.map { $0.list.rows.map(\.id) } == [["r1"]], "the offline copy")
            await removeCaches()
        }

        /// Leaving a database with no saved copy while it loads shows no error on return (code review R43): the cancelled
        /// load counted as failed, and "Something went wrong" showed until the next load ended.
        @Test func cancelledDatabaseLoadIsNoFailure() async throws {
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.unanswered.withLock { $0 = 1 }
            let loading = Task { await model.load() }
            while !StubURLProtocol.requests.withLock({ $0.contains { $0.hasSuffix("/api/bases/info") } }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            loading.cancel()
            await loading.value
            StubURLProtocol.unanswered.withLock { $0 = 0 }
            if case .failed = model.state { Issue.record("The cancelled load shows as failed") }
            await removeCaches()
        }

        /// Leaving a board while its columns load cancels their requests (code review R45): as tasks of their own they ran
        /// on, and the board's load waited for them.
        @Test func leavingABoardCancelsItsColumns() async throws {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            // A board by "s" (only the "No value" column); the rows request gets the base as its answer too.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "kanban", "config": {"groupByPropertyId": "s"}}]}}"#
            }
            await model.load()
            StubURLProtocol.body.withLock { $0 = nil }
            StubURLProtocol.requests.withLock { $0 = [] }
            StubURLProtocol.unanswered.withLock { $0 = 1 }
            let loading = Task { await model.loadRows() }
            while StubURLProtocol.requests.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
            loading.cancel()
            let ended = Mutex(false)
            Task { await loading.value; ended.withLock { $0 = true } }
            try await Task.sleep(for: .seconds(2))
            StubURLProtocol.unanswered.withLock { $0 = 0 }
            #expect(ended.withLock { $0 }, "The column's request ran on after leaving")
            await removeCaches()
        }

        /// The user deletes an entry, and a reload and "Load More" answer with it before the server has applied the delete.
        @Test(arguments: ["table", "kanban"]) func lateRowsAnswerKeepsTheEntryDeleted(type: String) async throws {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            // A table or a board by "s" (only the "No value" column); the rows request gets the base as its answer too.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "s", "name": "S", "type": "select"}], "views": [{"id": "v1", "name": "A", "type": "\#(type)", "config": {"groupByPropertyId": "s"}}]}}"#
            }
            await model.load()
            StubURLProtocol.body.withLock { $0 = #"{"data": {"items": [{"id": "r1", "cells": {}}], "meta": {"hasNextPage": true, "nextCursor": "c"}}}"# }
            await model.loadRows()
            try #require(model.row(id: "r1") != nil)
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                await model.loadRows()
                await model.loadMoreTable()
                await model.loadMore(columnId: BaseKanbanColumn.noValueId)
            } }
            await model.deleteRow("r1")
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.row(id: "r1") == nil)
            await removeCaches()
        }

        /// A card dropped on another one lands above it, or below it with `below`, and the board shows the new order
        /// while the move is saved.
        @Test func movedCardLandsBesideItsAnchor() async throws {
            let (session, model) = try await boardsOnA()
            let column = try #require(model.columns.first).id
            func order(afterMoving rowId: String, beside anchorId: String, below: Bool) async -> [String] {
                StubURLProtocol.body.withLock {
                    $0 = #"{"data": {"items": [{"id": "r1", "cells": {}, "position": "a0"}, {"id": "r2", "cells": {}, "position": "a1"}, {"id": "r3", "cells": {}, "position": "a2"}], "meta": {"hasNextPage": false}}}"#
                }
                await model.loadRows()
                let shown = Mutex<[String]>([])
                StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                    shown.withLock { $0 = model.columns.first?.list.rows.map(\.id) ?? [] }
                } }
                await model.moveCard(rowId, to: column, beside: anchorId, below: below)
                return shown.withLock { $0 }
            }

            #expect(await order(afterMoving: "r3", beside: "r1", below: false) == ["r3", "r1", "r2"])
            #expect(await order(afterMoving: "r1", beside: "r3", below: true) == ["r2", "r3", "r1"])
            #expect(await order(afterMoving: "r3", beside: "r2", below: false) == ["r1", "r3", "r2"])
            StubURLProtocol.body.withLock { $0 = nil }
            // The model holds its session unowned.
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// Cards whose keys can't be read leave no place to sort into: the board says so (code review R29). The card went
        /// nowhere without a word.
        @Test func cardWithoutAPlaceSaysSo() async throws {
            let (session, model) = try await boardsOnA()
            let column = try #require(model.columns.first).id
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"items": [{"id": "r1", "cells": {}, "position": "?"}, {"id": "r2", "cells": {}, "position": "!"}, {"id": "r3", "cells": {}, "position": "~"}], "meta": {"hasNextPage": false}}}"#
            }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            await model.moveCard("r3", to: column, beside: "r2", below: false)
            #expect(model.toast == String(localized: "This can't be placed there."))
            withExtendedLifetime(session) {}
            await removeCaches()
        }
    }
}
