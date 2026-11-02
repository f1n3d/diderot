import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// A database row shows its writes the server hasn't confirmed over its last confirmed state, in input order, so a
/// response can't overwrite a later change already shown.
struct PendingRowChangesTests {
    private func row(_ cells: String, position: String? = nil) throws -> BaseRow {
        let position = position.map { #","position":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(BaseRow.self, from: Data(#"{"id":"r","cells":\#(cells)\#(position)}"#.utf8))
    }

    @Test func aResponseDoesNotOverwriteALaterChange() throws {
        var pending = PendingRowChanges()
        let first = pending.begin(try row(#"{"p":"alt"}"#), cells: ["p": "eins"], position: nil)
        let second = pending.begin(try row(#"{"p":"eins"}"#), cells: ["p": "zwei"], position: "b")
        #expect(pending.overlay(rowId: "r")?.cells["p"] == "zwei")
        #expect(pending.overlay(rowId: "r")?.position == "b")

        pending.confirm(first, saved: try row(#"{"p":"eins","q":"vom Server"}"#))
        #expect(pending.overlay(rowId: "r")?.cells == ["p": "zwei", "q": "vom Server"])
        pending.drop(second)
        #expect(pending.overlay(rowId: "r")?.cells == ["p": "eins", "q": "vom Server"])
        #expect(pending.overlay(rowId: "r")?.position == nil)
    }

    @Test func aChangeToNullRemovesTheCell() throws {
        var pending = PendingRowChanges()
        _ = pending.begin(try row(#"{"p":"eins","q":"zwei"}"#), cells: ["p": .null], position: nil)
        #expect(pending.overlay(rowId: "r")?.cells == ["q": "zwei"])
    }

    /// The row's confirmed state is the one when its first pending change began, and stays until none is pending.
    @Test func theConfirmedStateStaysWhileChangesArePending() throws {
        var pending = PendingRowChanges()
        let first = pending.begin(try row(#"{"p":"alt"}"#), cells: ["p": "eins"], position: nil)
        let second = pending.begin(try row(#"{"p":"eins"}"#), cells: ["q": "zwei"], position: nil)
        pending.drop(first)
        #expect(pending.overlay(rowId: "r")?.cells == ["p": "alt", "q": "zwei"])
        #expect(pending.pendingRowIds == ["r"])
        let settledEarly = pending.settle("r")
        #expect(!settledEarly)
        #expect(pending.overlay(rowId: "r") != nil)

        pending.drop(second)
        #expect(pending.pendingRowIds.isEmpty)
        let settled = pending.settle("r")
        #expect(settled)
        #expect(pending.overlay(rowId: "r") == nil)
    }
}
