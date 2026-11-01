import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// Tables: where cells sit on their grid (merged ones too), how the layout sizes columns and rows, and what the
/// keyboard toolbar's table actions ask of the engine and do with the cursor.
struct TableEditingTests {
    private typealias Area = TableGrid.Area

    /// The web's Docmost 0.97 test table: a header two columns wide and one two rows tall, then rows of two and three.
    private let merged = TableGrid(spans: [[(2, 1), (1, 2)], [(1, 1), (1, 1)], [(1, 1), (1, 1), (1, 1)]])

    @Test func cellsSkipColumnsThatCellsAboveCover() {
        #expect(merged.areas == [
            [Area(top: 0, left: 0, bottom: 1, right: 2), Area(top: 0, left: 2, bottom: 2, right: 3)],
            [Area(top: 1, left: 0, bottom: 2, right: 1), Area(top: 1, left: 1, bottom: 2, right: 2)],
            [Area(top: 2, left: 0, bottom: 3, right: 1), Area(top: 2, left: 1, bottom: 3, right: 2), Area(top: 2, left: 2, bottom: 3, right: 3)],
        ])
        #expect(merged.width == 3 && merged.height == 3 && merged.hasMergedCells)
        #expect(cell(in: merged, row: 1, column: 2) == [0, 1])
        #expect(cell(in: merged, row: 0, column: 1) == [0, 0])
        #expect(cell(in: merged, row: 2, column: 2) == [2, 2])
        #expect(!TableGrid(spans: [[(1, 1), (1, 1)], [(1, 1), (1, 1)]]).hasMergedCells)
    }

    /// A rowspan past the last row ends there (and still counts as merged, as the engine's sort sees it); a cell far
    /// right of the others widens the grid.
    @Test func spansEndAtTheTablesEdge() {
        let grid = TableGrid(spans: [[(1, 3), (1, 1)], [(3, 1)]])
        #expect(grid.areas == [[Area(top: 0, left: 0, bottom: 2, right: 1), Area(top: 0, left: 1, bottom: 1, right: 2)],
                               [Area(top: 1, left: 1, bottom: 2, right: 4)]])
        #expect(grid.width == 4 && grid.hasMergedCells)
        #expect(cell(in: grid, row: 1, column: 0) == [0, 0])
        #expect(cell(in: grid, row: 0, column: 3) == nil)
    }

    /// The cell covering a slot, as row and index in the row.
    private func cell(in grid: TableGrid, row: Int, column: Int) -> [Int]? {
        grid.cell(row: row, column: column).map { [$0.row, $0.index] }
    }

    /// As the engine merges (Engine/tools/table-check.ts): with the neighbor and what the rectangle around both takes
    /// in; not in the last column or row, nor when a cell would stick out.
    @Test func mergesWhereTheEngineMerges() {
        let plain = TableGrid(spans: [[(1, 1), (1, 1)], [(1, 1), (1, 1)]])
        #expect(plain.canMerge(row: 0, index: 0, right: true) && plain.canMerge(row: 0, index: 1, right: false))
        #expect(!plain.canMerge(row: 0, index: 1, right: true) && !plain.canMerge(row: 1, index: 0, right: false))
        #expect(TableGrid(spans: [[(1, 2), (1, 1), (1, 1)], [(1, 1), (1, 1)]]).canMerge(row: 0, index: 0, right: true))
        #expect(!TableGrid(spans: [[(1, 2), (1, 1), (1, 1)], [(2, 1)]]).canMerge(row: 0, index: 0, right: true))
        // The cell two rows tall to the right: the rectangle takes in the cell above this one.
        #expect(TableGrid(spans: [[(1, 1), (1, 2)], [(1, 1)]]).canMerge(row: 1, index: 0, right: true))
        // The header two rows tall merges down with the cell below; the cell left of it can't merge right, the rectangle
        // would cut through the header two columns wide.
        #expect(merged.canMerge(row: 0, index: 1, right: false))
        #expect(!merged.canMerge(row: 1, index: 1, right: true))
        #expect(merged.canMerge(row: 1, index: 0, right: true))
    }

    /// Columns as wide as their widest single cell, rows as tall as their tallest; a spanning cell widens or heightens
    /// its columns or rows evenly where they fall short.
    @Test func spanningCellsWidenTheirColumnsEvenly() {
        let areas = merged.areas.flatMap { $0 }
        let widths: [CGFloat] = [300, 50, 100, 120, 80, 60, 60]
        let heights: [CGFloat] = [40, 200, 40, 30, 40, 40, 40]
        let tracks = TableGridLayout.tracks(areas: areas, width: { widths[$0] }, height: { cell, _ in heights[cell] })
        // Columns 0 and 1 have 100 and 120 from row 1; the header two columns wide needs 300: 40 more each.
        #expect(tracks.widths == [140, 160, 60])
        // Rows 0 and 1 have 40 and 40; the cell two rows tall needs 200: 60 more each.
        #expect(tracks.heights == [100, 100, 40])
        #expect(TableGridLayout.tracks(areas: areas, width: { _ in 10 }, height: { _, width in width }).heights == [20, 10, 10])
    }

    // MARK: - Editing

    private func cell(_ id: String, _ text: String, type: String = "tableCell", attrs: [String: JSONValue] = [:]) -> PMNode {
        PMNode(type: type, attrs: attrs.isEmpty ? nil : attrs, content: [
            PMNode(type: "paragraph", attrs: ["id": .string(id)], content: text.isEmpty ? nil : [PMNode(type: "text", text: text)]),
        ])
    }

    private func document(_ rows: [[PMNode]]) -> PMNode {
        PMNode(type: "doc", content: [PMNode(type: "table", content: rows.map { PMNode(type: "tableRow", content: $0) })])
    }

    /// A model editing the paragraph of the cell at `row` and `column` (index in the row).
    private func editing(_ document: PMNode, row: Int, column: Int) throws -> (DocumentModel, FakeDocumentEngine) {
        let engine = FakeDocumentEngine(document: document)
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id":"p"}"#.utf8))
        let model = DocumentModel(page: page, initialDocument: nil, engine: engine, readOnlyReason: nil)
        engine.sendDocument()
        let path = [0, row, column, 0]
        let line = try #require(model.node(at: path))
        model.activate(NodeRef(path: path, node: line), node: line)
        return (model, engine)
    }

    /// Color, alignment and the rest leave the cursor where it is, in its block, with what changed for it.
    @Test func formatKeepsTheCursorInItsBlock() async throws {
        let (model, engine) = try editing(document([[cell("a", "Eins"), cell("b", "Zwei")]]), row: 0, column: 1)
        model.cursorRequest = nil
        let aligned = PMNode(type: "tableCell", content: [
            PMNode(type: "paragraph", attrs: ["id": "b", "textAlign": "center"], content: [PMNode(type: "text", text: "Zwei")]),
        ])
        engine.whileInserting = { engine.document = self.document([[self.cell("a", "Eins"), aligned]]) }

        await model.editTable(.align(.center, .column))

        #expect(engine.tableCommands.map(\.command) == [["name": "align", "scope": "column", "align": "center"]])
        #expect(engine.tableCommands.map(\.cell) == [[0, 1]])
        #expect(model.active?.ref == NodeRef(path: [0, 0, 1, 0], id: "b"))
        #expect(model.active?.attrs?["textAlign"] == "center")
        #expect(model.activeTableState?.align == .center)
        // The cursor keeps its offset: no jump to the end.
        #expect(model.cursorRequest == .offset(4))
    }

    /// While the engine runs a table action, a document event without the edited block (its row deleted) doesn't end
    /// editing: the keyboard, with the table row in its toolbar, would go and come back.
    @Test func editingGoesOnThroughATableAction() async throws {
        let (model, engine) = try editing(document([[cell("a", "Eins")], [cell("b", "Zwei")]]), row: 0, column: 0)
        engine.tableFocus = [0, 0]
        var activeMeanwhile: Bool?
        engine.whileInserting = {
            engine.document = self.document([[self.cell("b", "Zwei")]])
            engine.sendDocument()
            activeMeanwhile = model.active != nil
        }

        await model.editTable(.deleteRow)

        #expect(activeMeanwhile == true)
        #expect(model.active?.ref == NodeRef(path: [0, 0, 0, 0], id: "b"))
    }

    /// Clearing the cell takes its block: the cursor goes to the cell's new paragraph.
    @Test func clearingMovesTheCursorToTheEmptyCell() async throws {
        let (model, engine) = try editing(document([[cell("a", "Eins"), cell("b", "Zwei")]]), row: 0, column: 1)
        engine.tableFocus = [0, 1]
        engine.whileInserting = { engine.document = self.document([[self.cell("a", "Eins"), self.cell("c", "")]]) }

        await model.editTable(.clear(.row))

        #expect(engine.tableCommands.map(\.command) == [["name": "clear", "scope": "row"]])
        #expect(model.active?.ref == NodeRef(path: [0, 0, 1, 0], id: "c"))
    }

    /// The table's only row deleted, the table is gone and editing ends; a refused action shows why nothing happened.
    @Test func goneTableEndsEditingAndRefusalShows() async throws {
        let (model, engine) = try editing(document([[cell("a", "Eins")]]), row: 0, column: 0)
        engine.tableFocus = nil
        await model.editTable(.mergeRight)
        #expect(model.errorMessage != nil && model.active != nil)

        engine.tableFocus = []
        engine.whileInserting = { engine.document = PMNode(type: "doc", content: [PMNode(type: "paragraph")]) }
        await model.editTable(.deleteRow)
        #expect(model.active == nil)
    }

    /// Colors go to the engine as the web stores them: the color and its name ("Blue"); the default as none.
    @Test func colorsAsTheWebStoresThem() {
        #expect(DocumentModel.TableEdit.background(.blue, .row).engineCommand
            == ["name": "background", "scope": "row", "color": "#b4d5ff", "colorName": "Blue"])
        #expect(DocumentModel.TableEdit.background(.none, .cell).engineCommand
            == ["name": "background", "scope": "cell", "color": .null, "colorName": .null])
        #expect(DocumentModel.TableColor(name: "Purple") == .purple && DocumentModel.TableColor(name: "teal") == .none)
        #expect(DocumentModel.TableColor.allCases.map(\.hex).compactMap { $0 }.count == 7)
    }

    /// What the toolbar offers for a cell: merging and moving where the grid allows, splitting a merged cell, sorting
    /// only without merged cells and with text to sort by, the cell's color and headers.
    @Test func toolbarOffersWhatTheCellAllows() throws {
        let blue: [String: JSONValue] = ["backgroundColor": "#b4d5ff", "backgroundColorName": "Blue"]
        let plain = document([[cell("h1", "Name", type: "tableHeader"), cell("h2", "Nr", type: "tableHeader")],
                              [cell("a", "b"), cell("b", "2", attrs: blue)]])
        var state = try #require(try editing(plain, row: 1, column: 1).0.activeTableState)
        #expect(state.headerRow && !state.headerColumn && !state.headerCell && state.color == .blue)
        #expect(state.canMoveRowUp && !state.canMoveRowDown && state.canMoveColumnLeft && !state.canMoveColumnRight)
        #expect(!state.canMergeRight && !state.canMergeDown && !state.canSplit && state.canSort)

        let wide = document([[cell("a", "A", attrs: ["colspan": 2])], [cell("b", "B"), cell("c", "C")]])
        state = try #require(try editing(wide, row: 0, column: 0).0.activeTableState)
        #expect(state.canSplit && state.canMergeDown && !state.canMergeRight && !state.canSort)
        #expect(!state.canMoveColumnLeft && !state.canMoveColumnRight)

        let empty = document([[cell("h", "Name", type: "tableHeader")], [cell("a", "")]])
        #expect(try editing(empty, row: 1, column: 0).0.activeTableState?.canSort == false)
    }
}
