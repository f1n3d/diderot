import Testing
@testable import Diderot

/// A database entry's single-line inputs take only the line breaks the user just put in (`SingleLineInput`).
struct SingleLineInputTests {
    @Test func returnEndsTheInput() {
        #expect(SingleLineInput.taking("abc\n", after: "abc")! == ("abc", true))
        #expect(SingleLineInput.taking("ab\nc", after: "abc")! == ("abc", true))
        // Over a selection ("b"), Return keeps it: it only ends the input.
        #expect(SingleLineInput.taking("a\nc", after: "abc")! == ("abc", true))
        // Keys typed so fast that they come as one change, Return last.
        #expect(SingleLineInput.taking("Titel\n", after: "Tit")! == ("Titel", true))
    }

    @Test func pastedLinesBecomeOneLine() {
        #expect(SingleLineInput.taking("aX\nY", after: "a")! == ("aX Y", false))
        // Over a selection ("b"), with Windows line breaks.
        #expect(SingleLineInput.taking("a1\r\n2c", after: "abc")! == ("a1 2c", false))
    }

    /// The stored value's line breaks stay while the user types around them. (Showing the stored value doesn't come
    /// here at all: the inputs take changes only while they have focus.)
    @Test func storedLineBreaksStay() {
        #expect(SingleLineInput.taking("Line one\nLine twoX", after: "Line one\nLine two") == nil)
        #expect(SingleLineInput.taking("a\nb\n", after: "a\nb")! == ("a\nb", true))
        #expect(SingleLineInput.taking("a\n\nb", after: "a\nb")! == ("a\nb", true))
    }
}
