import Foundation
import DocmostKit

// The keyboard toolbar's table actions and what its table rows show for the cell being edited. The engine runs the
// actions (`tableCommand`, Engine/src/tables.ts) and says which apply to the cell (`EngineAnswers.tableCommands`).
extension DocumentModel {
    struct TablePosition: Equatable {
        let tablePath: [Int]
        let row: Int
        let column: Int
    }

    /// The cells a format edit changes: the cell being edited, its row or its column (the web's cell menu and its row
    /// and column handles).
    enum TableScope: String, CaseIterable {
        case cell, row, column
    }

    /// The web's cell colors (Docmost's `TABLE_COLORS`); a cell keeps the name in `backgroundColorName` as the web does.
    enum TableColor: String, CaseIterable {
        case none, blue, green, yellow, red, pink, gray, purple

        init(name: String?) {
            self = name.flatMap { TableColor(rawValue: $0.lowercased()) } ?? .none
        }

        /// As the web stores it ("Blue"); none for the default.
        var name: String? { self == .none ? nil : rawValue.capitalized }

        var hex: String? {
            switch self {
            case .none: nil
            case .blue: "#b4d5ff"
            case .green: "#acf5d2"
            case .yellow: "#fef1b4"
            case .red: "#ffbead"
            case .pink: "#ffc7fe"
            case .gray: "#eaecef"
            case .purple: "#c1b7f2"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .none: "Default"
            case .blue: "Blue"
            case .green: "Green"
            case .yellow: "Yellow"
            case .red: "Red"
            case .pink: "Pink"
            case .gray: "Gray"
            case .purple: "Purple"
            }
        }
    }

    /// The keyboard toolbar's table actions, run by the engine as the web's table menus run them.
    enum TableEdit: Equatable {
        case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight, deleteRow, deleteColumn, deleteTable
        case toggleHeaderRow, toggleHeaderColumn, toggleHeaderCell
        /// With the neighbor, and every cell the rectangle around both takes in; splitting undoes a merge.
        case mergeRight, mergeDown, split
        case moveRowUp, moveRowDown, moveColumnLeft, moveColumnRight
        /// The rows by their cells in the cell's column.
        case sort(descending: Bool)
        case background(TableColor, TableScope)
        case align(TextAlign, TableScope)
        case clear(TableScope)

        /// The engine's command (`TableCommand` in Engine/src/tables.ts).
        var engineCommand: [String: JSONValue] {
            switch self {
            case .insertRowAbove: ["name": "addRowBefore"]
            case .insertRowBelow: ["name": "addRowAfter"]
            case .insertColumnLeft: ["name": "addColumnBefore"]
            case .insertColumnRight: ["name": "addColumnAfter"]
            case .deleteRow: ["name": "deleteRow"]
            case .deleteColumn: ["name": "deleteColumn"]
            case .deleteTable: ["name": "deleteTable"]
            case .toggleHeaderRow: ["name": "toggleHeaderRow"]
            case .toggleHeaderColumn: ["name": "toggleHeaderColumn"]
            case .toggleHeaderCell: ["name": "toggleHeaderCell"]
            case .mergeRight: ["name": "mergeRight"]
            case .mergeDown: ["name": "mergeDown"]
            case .split: ["name": "split"]
            case .moveRowUp: ["name": "moveRowUp"]
            case .moveRowDown: ["name": "moveRowDown"]
            case .moveColumnLeft: ["name": "moveColumnLeft"]
            case .moveColumnRight: ["name": "moveColumnRight"]
            case .sort(let descending): ["name": "sort", "descending": .bool(descending)]
            case .background(let color, let scope):
                ["name": "background", "scope": .string(scope.rawValue), "color": color.hex.map(JSONValue.string) ?? .null,
                 "colorName": color.name.map(JSONValue.string) ?? .null]
            case .align(let align, let scope): ["name": "align", "scope": .string(scope.rawValue), "align": .string(align.rawValue)]
            case .clear(let scope): ["name": "clear", "scope": .string(scope.rawValue)]
            }
        }

        /// The cursor goes to the cell the engine names: in the new row or column, next to the deleted one. Otherwise it
        /// stays in its block wherever that went (a moved row, a merged cell), or in the cell when its block is gone.
        var movesCursor: Bool {
            switch self {
            case .insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight, .deleteRow, .deleteColumn: true
            default: false
            }
        }
    }

    /// What the keyboard toolbar's table rows show for the cell being edited.
    struct TableState {
        var headerRow = false
        var headerColumn = false
        var headerCell = false
        var canMergeRight = false
        var canMergeDown = false
        var canSplit = false
        var canMoveRowUp = false
        var canMoveRowDown = false
        var canMoveColumnLeft = false
        var canMoveColumnRight = false
        var canSort = false
        var color = TableColor.none
        /// Of the block being edited.
        var align = TextAlign.left
    }

    /// Whether a table's first row / first column consists of header cells.
    static func headers(of table: PMNode) -> (row: Bool, column: Bool) {
        guard let first = table.children.first else { return (false, false) }
        let row = !first.children.isEmpty && first.children.allSatisfy { $0.type == "tableHeader" }
        let column = table.children.allSatisfy { $0.children.first?.type == "tableHeader" }
        return (row, column)
    }
}

extension DocumentModel.TablePosition {
    /// Table, row and column of the block at `path`, if it is in a cell.
    init?(of path: [Int], in document: PMNode) {
        guard let table = document.ancestorPath(of: path, types: ["table"]), path.count >= table.count + 2 else { return nil }
        self.init(tablePath: table, row: path[table.count], column: path[table.count + 1])
    }
}

extension DocumentModel.TableState {
    /// For `cell` of `table`, with the commands that apply to it (`EngineAnswers.tableCommands`) and the alignment of
    /// the block being edited.
    init(table: PMNode, cell: PMNode, applies: Set<String>, align: TextAlign) {
        let headers = DocumentModel.headers(of: table)
        self.init(
            headerRow: headers.row, headerColumn: headers.column, headerCell: cell.type == "tableHeader",
            canMergeRight: applies.contains("mergeRight"), canMergeDown: applies.contains("mergeDown"), canSplit: applies.contains("split"),
            canMoveRowUp: applies.contains("moveRowUp"), canMoveRowDown: applies.contains("moveRowDown"),
            canMoveColumnLeft: applies.contains("moveColumnLeft"), canMoveColumnRight: applies.contains("moveColumnRight"),
            canSort: applies.contains("sort"),
            color: DocumentModel.TableColor(name: cell.string("backgroundColorName")),
            align: align
        )
    }
}
