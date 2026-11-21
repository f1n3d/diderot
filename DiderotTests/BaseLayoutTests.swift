import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// Database view rules as on the web (column, card and choice order, number formats) and kanban snap points. Dates:
/// `BaseDateTests`.
@MainActor
struct BaseLayoutTests {
    /// Listed as title, status, notes, price; their positions order them title, price, status, notes.
    private let base: Base
    /// Choices a, b, c with the custom order c, a.
    private let status: BaseProperty
    /// Choices a, b without a custom order.
    private let tags: BaseProperty

    init() throws {
        base = try Self.decode([
            "id": "base", "views": [],
            "properties": [
                ["id": "title", "name": "Title", "type": "text", "position": "a0", "isPrimary": true],
                ["id": "status", "name": "Status", "type": "status", "position": "a2", "typeOptions": [
                    "choices": [["id": "a", "name": "A", "color": "red"], ["id": "b", "name": "B"], ["id": "c", "name": "C"]],
                    "choiceOrder": ["c", "a"],
                ]],
                ["id": "notes", "name": "Notes", "type": "longText", "position": "a3"],
                ["id": "price", "name": "Price", "type": "number", "position": "a1"],
            ],
        ])
        status = base.properties[1]
        tags = try Self.decode([
            "id": "tags", "name": "Tags", "type": "select",
            "typeOptions": ["choices": [["id": "a", "name": "A"], ["id": "b", "name": "B"]]],
        ])
    }

    // MARK: Order

    @Test func tableColumnsFollowTheViewWithTheTitleFirst() throws {
        #expect(try columns(nil) == ["title", "price", "status", "notes"])
        #expect(try columns(["propertyOrder": ["notes", "title"]]) == ["title", "notes", "price", "status"])
    }

    @Test func hiddenPropertiesWinOverVisibleOnes() throws {
        #expect(try columns(["visiblePropertyIds": ["notes"]]) == ["title", "notes"])
        #expect(try columns(["visiblePropertyIds": []]) == ["title", "price", "status", "notes"])
        #expect(try columns(["hiddenPropertyIds": ["price", "title"], "visiblePropertyIds": ["notes"]]) == ["title", "status", "notes"])
    }

    @Test func cardsShowVisiblePropertiesWithoutTheTitle() throws {
        let board = try view(["visiblePropertyIds": ["title", "notes", "price"], "propertyOrder": ["notes"]])
        #expect(BaseLayout.cardProperties(base: base, view: board).map(\.id) == ["notes", "price"])
        // Without a property order, positions decide.
        #expect(BaseLayout.cardProperties(base: base, view: try view(["visiblePropertyIds": ["notes", "price"]])).map(\.id) == ["price", "notes"])
    }

    @Test func boardColumnsFollowTheViewThenTheProperty() throws {
        let columns = BaseLayout.kanbanColumns(view: try view([:]), groupBy: status)
        #expect(columns.map(\.id) == ["c", "a", "b", BaseKanbanColumn.noValueId])
        #expect(columns.map(\.name) == ["C", "A", "B", nil])
        #expect(BaseLayout.kanbanColumns(view: try view([:]), groupBy: tags).map(\.id) == ["a", "b", BaseKanbanColumn.noValueId])
        // A listed "No value" keeps its place; unknown IDs are dropped.
        let custom = try view(["choiceOrder": ["b", "__no_value", "x", "a"]])
        #expect(BaseLayout.kanbanColumns(view: custom, groupBy: status).map(\.id) == ["b", BaseKanbanColumn.noValueId, "a", "c"])
        let hidden = try view(["hiddenChoiceIds": ["a", "__no_value"]])
        #expect(BaseLayout.kanbanColumns(view: hidden, groupBy: status).map(\.id) == ["c", "b"])
    }

    @Test func choicesFollowThePropertyOrder() {
        #expect(BaseLayout.orderedChoices(of: status).map(\.id) == ["c", "a", "b"])
        #expect(BaseLayout.orderedChoices(of: tags).map(\.id) == ["a", "b"])
    }

    // MARK: Format

    @Test func progressIsClampedAndRounded() {
        let progress: JSONValue = ["format": "progress"]
        #expect(BaseFormat.number(150, options: progress) == "100%")
        #expect(BaseFormat.number(-3, options: progress) == "0%")
        #expect(BaseFormat.number(42.5, options: progress) == "43%")
    }

    @Test func numbersGroupDigitsOnlyWithSeparators() {
        let value = 1_234_567.25
        let plain = value.formatted(.number.grouping(.never).precision(.fractionLength(0...4)))
        #expect(BaseFormat.number(value, options: nil) == plain)
        #expect(BaseFormat.number(value, options: ["separators": "none"]) == plain)
        #expect(BaseFormat.number(value, options: ["format": "percent"]) == plain + "%")
        #expect(BaseFormat.number(value, options: ["separators": "local"]) == value.formatted(.number.precision(.fractionLength(0...4))))
        #expect(BaseFormat.number(2, options: ["precision": 2]) == 2.0.formatted(.number.grouping(.never).precision(.fractionLength(2))))
    }

    // MARK: Board

    @Test func boardSnapsFromTheFirstToTheLastColumn() {
        let board: CGFloat = 402
        let content = 2 * KanbanBoardLayout.padding + 4 * KanbanBoardLayout.columnWidth(board: board) + 3 * KanbanBoardLayout.spacing
        let offsets = KanbanBoardLayout.offsets(count: 4, board: board)
        #expect(offsets == (0..<4).map { KanbanBoardLayout.offset(column: $0, count: 4, board: board) })
        #expect(offsets.first == 0)
        #expect(offsets.last == content - board)
    }

    @Test func wideBoardSharesOneSnapPoint() {
        #expect(KanbanBoardLayout.offsets(count: 3, board: 2000) == [0])
        #expect(KanbanBoardLayout.offsets(count: 0, board: 402).isEmpty)
    }

    // MARK: Helpers

    private func columns(_ config: JSONValue?) throws -> [String] {
        BaseLayout.tableColumns(base: base, view: try config.map(view)).map(\.id)
    }

    private func view(_ config: JSONValue) throws -> BaseView {
        try Self.decode(["id": "view", "name": "View", "type": "kanban", "config": config])
    }

    /// The models have no public initializers; build them as the server sends them.
    private static func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }
}
