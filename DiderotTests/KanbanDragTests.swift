import CoreGraphics
import Testing
@testable import Diderot

/// A card held at a board edge pages the board one column per pause, and stops once the finger leaves the board. On a
/// board 402 pt wide: the paging zone starts at 358, a snapped middle column (340 × 600) spans 31 to 371, a gap follows
/// to 383, and a card (324 × 80) sits 8 pt inside the column. The finger is at x 360: 329 in the column, 321 in the card.
@MainActor
struct KanbanDragTests {
    private let column = CGSize(width: 340, height: 600)
    private let card = CGSize(width: 324, height: 80)
    private let header = KanbanDropTarget(columnId: "doing", rowId: nil)

    /// Up from a card onto the column's header, then off the board onto the view's header, all at the right edge: the
    /// board paged on to the last column. The card's exit and the header's entry may come in either order, and the
    /// exit may be reported just outside the column or still just inside it.
    @Test func pagingStopsWhenTheFingerLeavesTheBoard() async {
        for (headerFirst, exitY) in [(false, -1.0), (true, 0.5)] {
            let clock = TestClock()
            let drag = await pagingRight(clock)
            if headerFirst { enterHeader(drag) }
            drag.leave(rowId: "card", columnId: "doing", at: CGPoint(x: 321, y: -1), size: card, boardMinX: 39)
            if !headerFirst { enterHeader(drag) }
            #expect(await pagesOn(drag, clock), "Header first: \(headerFirst)")
            drag.leave(rowId: nil, columnId: "doing", at: CGPoint(x: 329, y: exitY), size: column, boardMinX: 31)
            #expect(!(await pagesOn(drag, clock)), "Header first: \(headerFirst)")
        }
    }

    /// A page moves the columns under a finger held at the edge, and it can stop in the gap after one: paging goes on.
    @Test func pagingGoesOnThroughAGapAtTheEdge() async {
        let clock = TestClock()
        let drag = await pagingRight(clock)
        enterHeader(drag)
        drag.leave(rowId: nil, columnId: "doing", at: CGPoint(x: 341, y: 300), size: column, boardMinX: 31)
        #expect(await pagesOn(drag, clock))
    }

    /// An exit reported after the drop or the drag's end doesn't start paging again.
    @Test func exitAfterTheDragEndsDoesNotPage() async {
        let clock = TestClock()
        let drag = await pagingRight(clock)
        drag.end()
        drag.leave(rowId: nil, columnId: "doing", at: CGPoint(x: 341, y: 300), size: column, boardMinX: 31)
        #expect(!(await pagesOn(drag, clock)))
    }

    // MARK: Helpers

    /// A card held over a card at the right edge, after the first page.
    private func pagingRight(_ clock: TestClock) async -> KanbanDragState {
        let drag = KanbanDragState(clock: clock)
        drag.boardWidth = 402
        drag.draggedRowId = "dragged"
        drag.target = KanbanDropTarget(columnId: "doing", rowId: "card")
        drag.hover(atBoardX: 360)
        await clock.advance(by: .milliseconds(550))
        #expect(drag.scrollRequest?.direction == 1)
        return drag
    }

    /// The column's own drop area takes the drag, as its `dropEntered` does.
    private func enterHeader(_ drag: KanbanDragState) {
        drag.target = header
        drag.hover(atBoardX: 360)
    }

    /// Whether the board pages again in the next pause.
    private func pagesOn(_ drag: KanbanDragState, _ clock: TestClock) async -> Bool {
        let before = drag.scrollRequest
        await clock.advance(by: .milliseconds(550))
        return drag.scrollRequest != before
    }
}
