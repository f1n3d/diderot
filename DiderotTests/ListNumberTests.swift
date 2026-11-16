import Testing
@testable import Diderot

/// Numbered lists count as on the web, by how many numbered lists are around them (Docmost's ordered-list.css).
struct ListNumberTests {
    @Test func decimalThenLettersThenRomanNumerals() {
        #expect([1, 2, 10].map { ListBlockView.number($0, depth: 0) } == ["1.", "2.", "10."])
        #expect([1, 2, 26].map { ListBlockView.number($0, depth: 1) } == ["a.", "b.", "z."])
        #expect([1, 4, 9, 14, 40, 1994].map { ListBlockView.number($0, depth: 2) } == ["i.", "iv.", "ix.", "xiv.", "xl.", "mcmxciv."])
        // A fourth level counts in numbers again, a fifth in letters.
        #expect(ListBlockView.number(3, depth: 3) == "3.")
        #expect(ListBlockView.number(3, depth: 4) == "c.")
    }

    /// Letters go on as CSS's alphabetic system does, without a zero: z, aa, ab … zz, aaa.
    @Test func lettersGoOnPastZ() {
        #expect([27, 28, 52, 53, 702, 703].map { ListBlockView.number($0, depth: 1) } == ["aa.", "ab.", "az.", "ba.", "zz.", "aaa."])
    }

    /// Where letters or Roman numerals don't reach, a number, as CSS falls back to decimal: a list can start at 0.
    @Test func outOfRangeFallsBackToNumbers() {
        #expect(ListBlockView.number(0, depth: 1) == "0.")
        #expect(ListBlockView.number(-2, depth: 1) == "-2.")
        #expect(ListBlockView.number(0, depth: 2) == "0.")
        #expect(ListBlockView.number(3999, depth: 2) == "mmmcmxcix.")
        #expect(ListBlockView.number(4000, depth: 2) == "4000.")
    }

    /// A list's markers share a column as wide as the one taking the most room: "viii." before "ix.".
    @Test func widestMarkerOfAList() {
        #expect(ListBlockView.widest((1...10).map { ListBlockView.number($0, depth: 2) }) == "viii.")
        #expect(ListBlockView.widest([]) == "")
    }
}
