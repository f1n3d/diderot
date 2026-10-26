import CoreGraphics
import Testing
@testable import Diderot

/// A page dragged onto a tree row goes where the web's page tree would put it.
struct TreeDropZoneTests {
    /// Top quarter before, bottom quarter after, the half between into the page; the quarters' edges belong to them.
    @Test func rowSplitsInQuarters() {
        let zones = [0, 10, 11, 20, 29, 30, 40].map { TreeDropZone.at(CGFloat($0), height: 40, showsSubpages: false) }
        #expect(zones == [.before, .before, .nest, .nest, .nest, .after, .after])
    }

    /// A row showing its subpages has no "after" (the page would land below them, the line showed above them): below
    /// its top quarter the page goes into it.
    @Test func expandedRowNestsBelowItsTopQuarter() {
        let zones = [0, 10, 11, 30, 40].map { TreeDropZone.at(CGFloat($0), height: 40, showsSubpages: true) }
        #expect(zones == [.before, .before, .nest, .nest, .nest])
    }

    @Test func rowNotMeasuredYet() {
        #expect(TreeDropZone.at(0, height: 0, showsSubpages: false) == .before)
    }
}
