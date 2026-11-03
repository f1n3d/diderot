import Foundation
import DocmostKit

/// A database's writes the server hasn't confirmed, over their rows' last confirmed state: a row shows its pending
/// changes in input order, so a response can't overwrite a later change already shown (`BaseModel.write`).
struct PendingRowChanges {
    private struct Change {
        let id = UUID()
        let rowId: String
        let cells: [String: JSONValue]
        let position: String?
    }

    private var changes: [Change] = []
    private var confirmed: [String: BaseRow] = [:]

    /// Starts a change of `row` as shown now, which stays the row's confirmed state until the server answers a change
    /// of it. Returns the change's id for `confirm` or `drop`.
    mutating func begin(_ row: BaseRow, cells: [String: JSONValue], position: String?) -> UUID {
        if confirmed[row.id] == nil { confirmed[row.id] = row }
        let change = Change(rowId: row.id, cells: cells, position: position)
        changes.append(change)
        return change.id
    }

    /// The server saved the change; `saved` is its row's confirmed state now.
    mutating func confirm(_ id: UUID, saved: BaseRow) {
        guard let index = changes.firstIndex(where: { $0.id == id }) else { return }
        confirmed[changes.remove(at: index).rowId] = saved
    }

    /// The change failed: its row shows its other changes only.
    mutating func drop(_ id: UUID) {
        changes.removeAll { $0.id == id }
    }

    /// Forgets the row's confirmed state once none of its changes is pending. Returns whether none is.
    mutating func settle(_ rowId: String) -> Bool {
        guard !changes.contains(where: { $0.rowId == rowId }) else { return false }
        confirmed[rowId] = nil
        return true
    }

    /// Rows with changes pending.
    var pendingRowIds: Set<String> { Set(changes.map(\.rowId)) }

    /// The row's confirmed state with its pending changes in input order; nil for a row without changes under way.
    func overlay(rowId: String) -> BaseRow? {
        guard var row = confirmed[rowId] else { return nil }
        for change in changes where change.rowId == rowId {
            for (key, value) in change.cells {
                if value.isNull { row.cells.removeValue(forKey: key) } else { row.cells[key] = value }
            }
            if let position = change.position { row.position = position }
        }
        return row
    }
}
