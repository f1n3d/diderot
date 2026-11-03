import SwiftUI
import Testing
@testable import Diderot

/// The formula and diagram islands (`WebIslandView`).
struct WebIslandTests {
    /// An island built anew (scrolled back into view) starts at the height it last had, for its content, width and text
    /// size (code review R48): at its minimum height it grew while it rendered, and what was below it jumped.
    @Test func anIslandBuiltAgainKeepsItsHeight() {
        let html = IslandHTML.math("x^{4711}", displayMode: true)
        WebIslandView.remember(120, of: html, width: 390, typeSize: .large)
        #expect(WebIslandView.lastHeight(of: html, width: 390, typeSize: .large) == 120)
        #expect(WebIslandView.lastHeight(of: html, width: 600, typeSize: .large) == nil)
        #expect(WebIslandView.lastHeight(of: html, width: 390, typeSize: .xxxLarge) == nil)
    }
}
