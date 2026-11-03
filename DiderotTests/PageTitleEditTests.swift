import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// The title field's text (`PageTitleEdit`): Return ends the title, and a title being typed stays when the page loads
/// again. Saving it is tested with the session (`AppSessionRaceTests`).
struct PageTitleEditTests {
    @Test func returnEndsTheTitle() {
        let edit = PageTitleEdit()
        edit.text = "Neue Seite"
        #expect(!edit.takeReturn() && edit.text == "Neue Seite")
        edit.text = "Neue\nSeite"
        #expect(edit.takeReturn() && edit.text == "Neue Seite")
    }

    @Test func aTitleBeingTypedStays() throws {
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"id": "p1", "title": "Vom Server"}"#.utf8))
        let edit = PageTitleEdit()
        edit.show(page, typing: false)
        #expect(edit.text == "Vom Server")
        edit.text = "Getippt"
        edit.show(page, typing: true)
        #expect(edit.text == "Getippt")
    }
}
