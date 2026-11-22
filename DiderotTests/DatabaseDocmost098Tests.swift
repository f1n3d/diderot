import Foundation
import Testing
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// Databases on Docmost 0.98: a stale cursor starts the list again, form views stay hidden, the server's version
    /// decides how dates go out, and calendar views load a month.
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

        /// A first page that fails too says so and tries no further; the rows shown stay, and the end of the table or
        /// board column offers "Try Again", which sends the stale cursor once more and so starts the view again. Its
        /// spinner ran on with nothing asked.
        @Test(arguments: [false, true]) func failedRestartSaysSo(board: Bool) async throws {
            let (model, session) = try await board ? boardWithMore() : tableWithMore()
            defer { withExtendedLifetime(session) {} }
            defer { UserDefaults.standard.removeObject(forKey: "base.view.\(model.pageId)") }
            let column = board ? BaseKanbanColumn.noValueId : nil
            func loadMore() async {
                if let column { await model.loadMore(columnId: column) } else { await model.loadMoreTable() }
            }
            func shownRows() -> [String] { (board ? model.columns.first?.list : model.table)?.rows.map(\.id) ?? [] }
            StubURLProtocol.status.withLock { $0 = 400 }
            StubURLProtocol.body.withLock { $0 = Self.staleCursor }
            defer { resetStub() }
            StubURLProtocol.requests.withLock { $0 = [] }
            await loadMore()
            #expect(rowRequests() == 2)
            #expect(shownRows() == ["r1"])
            #expect(model.toast == "The row cursor is stale. Reload rows and try again.")
            #expect(model.loadMoreFailed(columnId: column), "Try Again at the end")
            Self.answerRows([(400, Self.staleCursor), (200, Self.rows("r2"))])
            await loadMore()
            #expect(shownRows() == ["r2"])
            #expect(!model.loadMoreFailed(columnId: column))
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

        // MARK: Calendars

        /// A calendar view loads its month's window from `bases/rows/calendar`, not pages of rows, and shows its
        /// entries by date. A day of the same month asks for nothing, another month for its window; the next visit
        /// opens on that month, offline from its saved copy.
        @Test func calendarLoadsItsMonth() async throws {
            let (model, session) = try await calendarOnA(Self.calendarAnswer(
                [("r2", #"{"start": "2026-11-24", "end": "2026-11-26"}"#), ("r1", #"{"start": "2026-11-21"}"#)], total: 1500
            ))
            let viewId = try #require(model.selectedView?.id)
            defer { UserDefaults.standard.removeObject(forKey: "base.calendar.\(viewId)") }
            #expect(calendarRequests() == 1 && rowRequests() == 0)
            #expect(model.calendar.rows.map(\.id) == ["r2", "r1"] && model.showsCalendarMonth)
            #expect(model.calendar.truncated && model.calendar.total == 1500)
            #expect(model.calendarEntries.map(\.rowId) == ["r1", "r2"], "by date")
            #expect(model.orderedRowIds == ["r1", "r2"], "the detail's previous and next")

            await model.chooseCalendarDay(try day("2026-11-28"))
            #expect(calendarRequests() == 1, "the same month")
            StubURLProtocol.body.withLock { $0 = Self.calendarAnswer([("r3", #"{"start": "2026-12-10"}"#)]) }
            await model.chooseCalendarDay(try day("2026-12-01"))
            #expect(calendarRequests() == 2)
            #expect(try model.calendar.rows.map(\.id) == ["r3"] && !model.calendar.truncated && model.calendarDay == day("2026-12-01"))

            StubURLProtocol.offline.withLock { $0 = true }
            let reopened = BaseModel(pageId: model.pageId, session: session)
            await reopened.load()
            StubURLProtocol.offline.withLock { $0 = false }
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(try reopened.calendarDay == day("2026-12-01"))
            #expect(reopened.calendarEntries.map(\.rowId) == ["r3"] && reopened.rowsError == nil && reopened.toast == nil)
            await removeCaches()
        }

        /// "New Entry" on a calendar gives the chosen day to its date property, as the web's click on a day does, and
        /// the entry shows on that day.
        @Test func newEntryGoesOnTheChosenDay() async throws {
            let (model, session) = try await calendarOnA(Self.calendarAnswer([]))
            let viewId = try #require(model.selectedView?.id)
            defer { UserDefaults.standard.removeObject(forKey: "base.calendar.\(viewId)") }
            #expect(model.canCreateRow)
            await model.chooseCalendarDay(try day("2026-11-25"))
            StubURLProtocol.body.withLock { $0 = #"{"data": {"id": "new", "cells": {"d": {"start": "2026-11-25"}}}}"# }
            let created = await model.createRow(atTop: true)
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(created?.id == "new")
            let sent = try #require(StubURLProtocol.bodies.withLock { $0["a.example.com/api/bases/rows/create"] })
            #expect(try JSONDecoder().decode([String: JSONValue].self, from: sent)["cells"] == ["d": ["start": "2026-11-25"]])
            let byDay = BaseCalendarLayout.entriesByDay(model.calendarEntries, in: model.calendarMonth)
            #expect(try byDay[day("2026-11-25")]?.map(\.rowId) == ["new"])
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// "New Entry" shows on a calendar whose date the app can give: not one by "Created", nor while the server
        /// converts the date property; a calendar by a property without dates asks for no rows either.
        @Test(arguments: zip([
            #"{"id": "d", "name": "Datum", "type": "date"}"#,
            #"{"id": "d", "name": "Erstellt", "type": "createdAt"}"#,
            #"{"id": "d", "name": "Datum", "type": "date", "pendingType": "date", "pendingTypeOptions": {"includeTime": true}}"#,
            #"{"id": "d", "name": "Text", "type": "text"}"#,
        ], [true, false, false, false]))
        func newEntryNeedsADateToGive(property: String, creates: Bool) async throws {
            let (model, session) = try await calendarOnA(Self.calendarAnswer([]), property: property)
            let viewId = try #require(model.selectedView?.id)
            defer { UserDefaults.standard.removeObject(forKey: "base.calendar.\(viewId)") }
            #expect(model.canCreateRow == creates)
            #expect(calendarRequests() == (model.calendarProperty == nil ? 0 : 1))
            withExtendedLifetime(session) {}
            await removeCaches()
        }

        /// The user moves to the next month while the month's answer is out, and the new month's comes first: the older
        /// answer replaces it neither on the screen nor in the offline copy.
        @Test func lateMonthAnswerKeepsTheNewMonth() async throws {
            let (model, session) = try await calendarOnA(Self.calendarAnswer([]))
            let viewId = try #require(model.selectedView?.id)
            defer { UserDefaults.standard.removeObject(forKey: "base.calendar.\(viewId)") }
            let november = Self.calendarAnswer([("nov", #"{"start": "2026-11-21"}"#)])
            let december = Self.calendarAnswer([("dec", #"{"start": "2026-12-10"}"#)])
            let first = try day("2026-12-01")
            StubURLProtocol.body.withLock { $0 = november }
            StubURLProtocol.beforeNextAnswer.withLock { $0 = { @MainActor in
                StubURLProtocol.body.withLock { $0 = december }
                await model.chooseCalendarDay(first)
                StubURLProtocol.body.withLock { $0 = november }
            } }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            #expect(model.calendar.rows.map(\.id) == ["dec"] && model.showsCalendarMonth && !model.isLoadingRows)
            let snapshot = await session.ready?.cache.read(BaseViewSnapshot.self, key: CacheKey.baseView(model.pageId, viewId: viewId))
            #expect(snapshot?.calendar?.rows.map(\.id) == ["dec"], "the offline copy")
            await removeCaches()
        }

        // MARK: Helpers

        /// Signed in to a with a Business license: an editable database whose calendar goes by `property` (`d`, a date
        /// unless given), showing November 2026 (the day kept as the web keeps it), with `answer` loaded.
        private func calendarOnA(
            _ answer: String, property: String = #"{"id": "d", "name": "Datum", "type": "date"}"#
        ) async throws -> (BaseModel, AppSession) {
            let business = try JSONDecoder().decode(Entitlements.self, from: Data(#"{"tier": "business", "features": ["bases"]}"#.utf8))
            await DiskCache(scope: a.absoluteString).write(business, key: CacheKey.entitlements)
            let session = try await sessionOnA()
            let viewId = "calendar-\(UUID().uuidString)"
            UserDefaults.standard.set("2026-11-21", forKey: "base.calendar.\(viewId)")
            let model = BaseModel(pageId: "base-\(UUID().uuidString)", session: session)
            // The calendar request gets the base as its answer too, so the rows load again below.
            StubURLProtocol.body.withLock {
                $0 = #"{"data": {"id": "b", "permissions": {"canEdit": true}, "properties": [{"id": "t", "name": "Titel", "type": "text", "isPrimary": true}, \#(property)], "views": [{"id": "\#(viewId)", "name": "Kalender", "type": "calendar", "position": "a", "config": {"calendar": {"layout": "month", "datePropertyId": "d"}}}]}}"#
            }
            await model.load()
            StubURLProtocol.body.withLock { $0 = answer }
            StubURLProtocol.requests.withLock { $0 = [] }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            return (model, session)
        }

        /// Docmost 0.98's calendar answer with these rows, titled by their id, by their date `d` (JSON).
        private static func calendarAnswer(_ rows: [(id: String, date: String)], total: Int? = nil) -> String {
            let items = rows.map { #"{"id": "\#($0.id)", "cells": {"t": "\#($0.id)", "d": \#($0.date)}}"# }.joined(separator: ", ")
            let truncated = total.map { $0 > rows.count } ?? false
            return #"{"data": {"items": [\#(items)], "meta": {"total": \#(total ?? rows.count), "truncated": \#(truncated), "timeZone": "Europe/Berlin"}}}"#
        }

        private func calendarRequests() -> Int {
            StubURLProtocol.requests.withLock { $0 }.filter { $0 == "a.example.com/api/bases/rows/calendar" }.count
        }

        private func day(_ text: String) throws -> CalendarDay {
            try #require(CalendarDay(text))
        }

        /// `editableBase`'s table with a next page behind the cursor "c".
        private func tableWithMore() async throws -> (BaseModel, AppSession) {
            let (model, session) = try await editableBase()
            StubURLProtocol.body.withLock { $0 = Self.rowsWithMore("r1") }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            try #require(model.table.hasMore && model.table.cursor == "c")
            return (model, session)
        }

        /// `boardsOnA`'s first board, its column with a next page behind the cursor "c".
        private func boardWithMore() async throws -> (BaseModel, AppSession) {
            let (session, model) = try await boardsOnA()
            StubURLProtocol.body.withLock { $0 = Self.rowsWithMore("r1") }
            await model.loadRows()
            StubURLProtocol.body.withLock { $0 = nil }
            try #require(model.columns.first?.list.hasMore == true && model.columns.first?.list.cursor == "c")
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
