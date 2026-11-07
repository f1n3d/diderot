import Foundation
import Testing
import DocmostKit
@testable import Diderot

/// The note being written in "Append Note" stays on the device until it is appended or cancelled (code review V49: it
/// lived only in its sheet, so a crash or a server switch lost it).
@MainActor
struct NoteDraftTests {
    private let directory: URL
    /// One store, as `UnsentChanges.store` gives every caller of a server and user.
    private let store: UnsentStore

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "note-draft-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = UnsentStore(directory: directory)
    }

    /// What is typed is kept once typing pauses, and the next sheet for the page finds it: it opens on another
    /// `NoteDraft`, as after a crash. Another page's sheet doesn't.
    @Test func aNoteIsKeptForTheNextSheet() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let draft = NoteDraft(pageId: "p1", store: store, clock: clock)
        draft.keep("Erste")
        draft.keep("Erste Zeile")
        await clock.advance(by: .milliseconds(499))
        #expect(await NoteDraft(pageId: "p1", store: store).kept() == nil, "kept before typing paused")
        await clock.advance(by: .milliseconds(1))
        await draft.settled()
        #expect(await NoteDraft(pageId: "p1", store: store).kept() == "Erste Zeile")
        #expect(await NoteDraft(pageId: "p2", store: store).kept() == nil)
    }

    /// Going to the background, the note is kept at once: iOS may end the app before the wait for more typing ends.
    @Test func theBackgroundKeepsTheNoteAtOnce() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let draft = NoteDraft(pageId: "p1", store: store, clock: clock)
        draft.keep("Halb geschrieben")
        await draft.keepNow("Halb geschrieben")
        #expect(await NoteDraft(pageId: "p1", store: store).kept() == "Halb geschrieben")
    }

    /// Appended or cancelled, the note goes, also when a keep still waits to write it; emptied, it goes as well.
    @Test func anAppendedOrEmptiedNoteGoes() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let draft = NoteDraft(pageId: "p1", store: store, clock: clock)
        draft.keep("Notiz")
        await clock.advance(by: .milliseconds(500))
        await draft.settled()
        draft.keep("Notiz, länger")
        await draft.forget()
        await clock.advance(by: .milliseconds(500))
        #expect(await draft.kept() == nil)

        draft.keep("Wieder")
        await clock.advance(by: .milliseconds(500))
        await draft.settled()
        draft.keep("  \n")
        await clock.advance(by: .milliseconds(500))
        await draft.settled()
        #expect(await draft.kept() == nil)
    }
}
