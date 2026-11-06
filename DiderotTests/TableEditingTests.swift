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
        #expect(merged.width == 3 && merged.height == 3)
        #expect(cell(in: merged, row: 1, column: 2) == [0, 1])
        #expect(cell(in: merged, row: 0, column: 1) == [0, 0])
        #expect(cell(in: merged, row: 2, column: 2) == [2, 2])
    }

    /// A rowspan past the last row ends there; a cell far right of the others widens the grid.
    @Test func spansEndAtTheTablesEdge() {
        let grid = TableGrid(spans: [[(1, 3), (1, 1)], [(3, 1)]])
        #expect(grid.areas == [[Area(top: 0, left: 0, bottom: 2, right: 1), Area(top: 0, left: 1, bottom: 1, right: 2)],
                               [Area(top: 1, left: 1, bottom: 2, right: 4)]])
        #expect(grid.width == 4)
        #expect(cell(in: grid, row: 1, column: 0) == [0, 0])
        #expect(cell(in: grid, row: 0, column: 3) == nil)
    }

    /// The cell covering a slot, as row and index in the row.
    private func cell(in grid: TableGrid, row: Int, column: Int) -> [Int]? {
        grid.cell(row: row, column: column).map { [$0.row, $0.index] }
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

    /// A model editing the paragraph of the cell at `row` and `column` (index in the row); the engine says the
    /// commands `applying` apply to it (all by default).
    private func editing(_ document: PMNode, row: Int, column: Int, applying: Set<String>? = nil) throws -> (DocumentModel, FakeDocumentEngine) {
        let engine = FakeDocumentEngine(document: document)
        engine.tableCommandsApplying = applying
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
        engine.tableFocus = [0, 0, 0]
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
        engine.tableFocus = [0, 0, 1]
        engine.whileInserting = { engine.document = self.document([[self.cell("a", "Eins"), self.cell("c", "")]]) }

        await model.editTable(.clear(.row))

        #expect(engine.tableCommands.map(\.command) == [["name": "clear", "scope": "row"]])
        #expect(model.active?.ref == NodeRef(path: [0, 0, 1, 0], id: "c"))
    }

    /// A table action runs on the cell being edited, found by its block's id, and the cursor goes to the cell the engine
    /// names in its page: the table's path in the page's copy lags behind a collaborator's block above, and reached the
    /// table beside it. Without an engine to take it, the action isn't refused and says nothing.
    @Test func tableActionFollowsTheEnginesTable() async throws {
        let (model, engine) = try editing(document([[cell("a", "Eins")], [cell("b", "Zwei")]]), row: 0, column: 0)
        engine.tableCommandsUnavailable = true
        await model.editTable(.deleteRow)
        #expect(model.errorMessage == nil)

        engine.tableCommandsUnavailable = false
        engine.tableFocus = [1, 0, 0]
        engine.whileInserting = {
            engine.document = PMNode(type: "doc", content: [
                PMNode(type: "paragraph", attrs: ["id": "x"]),
                PMNode(type: "table", content: [PMNode(type: "tableRow", content: [self.cell("b", "Zwei")])]),
            ])
        }
        await model.editTable(.deleteRow)
        #expect(engine.tableCommands.map(\.target) == [.id("a", path: [0, 0, 0, 0])])
        #expect(model.active?.ref == NodeRef(path: [1, 0, 0, 0], id: "b"))
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

    /// What the toolbar offers for a cell: merging, splitting, moving and sorting where the engine says they apply to
    /// it, as it runs them (the app kept its own copy of the grid's rules); the cell's color and the headers as the page
    /// shows them.
    @Test(.timeLimit(.minutes(1))) func toolbarOffersWhatTheCellAllows() async throws {
        let blue: [String: JSONValue] = ["backgroundColor": "#b4d5ff", "backgroundColorName": "Blue"]
        let plain = document([[cell("h1", "Name", type: "tableHeader"), cell("h2", "Nr", type: "tableHeader")],
                              [cell("a", "b"), cell("b", "2", attrs: blue)]])
        let (model, engine) = try editing(plain, row: 1, column: 1, applying: ["moveRowUp", "moveColumnLeft", "sort"])
        while model.answers == nil { try await Task.sleep(for: .milliseconds(10)) }
        let state = try #require(model.activeTableState)
        #expect(state.headerRow && !state.headerColumn && !state.headerCell && state.color == .blue)
        #expect(state.canMoveRowUp && !state.canMoveRowDown && state.canMoveColumnLeft && !state.canMoveColumnRight)
        #expect(!state.canMergeRight && !state.canMergeDown && !state.canSplit && state.canSort)
        let question = try #require(engine.tableQuestions.last)
        // Asked through the cell's block, as the commands run (`tableAround`).
        #expect(question.target == .id("b", path: [0, 1, 1, 0]) && question.cell == [1, 1])
        #expect(question.commands.compactMap { $0["name"]?.stringValue }
            == ["mergeRight", "mergeDown", "split", "moveRowUp", "moveRowDown", "moveColumnLeft", "moveColumnRight", "sort"])
    }
}
